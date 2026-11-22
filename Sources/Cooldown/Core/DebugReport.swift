import AppKit
import Foundation
import UniformTypeIdentifiers

/// One text file with what is needed to find out why something does not work: the checks from
/// Diagnostics, versions of the tools, settings, limits and the recent logs. Personal things are
/// taken out (chat titles, IP addresses, e-mails, the home folder); the person can read the file
/// before sending it. Nothing is sent anywhere.
@MainActor
enum DebugReport {
    /// Asks where to save, runs the checks, writes the file and shows it in Finder.
    static func save() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Cooldown-report-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = await build()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func build() async -> String {
        let diagnostics = Diagnostics.shared
        diagnostics.run()
        while diagnostics.running { try? await Task.sleep(for: .milliseconds(200)) }

        var out: [String] = []
        func section(_ title: String) { out += ["", "## \(title)"] }
        let info = ProcessInfo.processInfo
        out.append("# Cooldown debug report")
        out.append("Cooldown \(GitHubUpdater.current) · macOS \(info.operatingSystemVersionString) · \(sysctl("hw.model")) · \(sysctl("hw.machine"))")
        out.append("Made \(Date().ISO8601Format()) · time zone \(TimeZone.current.identifier) · languages \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
        out.append("App: \(redact(Bundle.main.bundlePath)) · beta channel \(Settings.updateBeta ? "on" : "off")")

        section("Checks")
        out.append(diagnostics.report)

        section("Tools")
        let tools: [(String, URL?)] = [("claude", ClaudePaths.binary(override: Settings.claudePath)),
                                       ("codex", CodexPaths.binary(override: Settings.codexPath)),
                                       ("agy", AntigravityLimits.binary)]
        for (name, url) in tools {
            guard let url else { out.append("\(name): not found"); continue }
            out.append("\(name): \(redact(url.path)) — \(redact(await version(url)))")
        }
        out.append("Claude Desktop: \(ClaudeSender.claudeApp == nil ? "not running" : "running")")

        section("Limits")
        for provider in ProviderID.allCases {
            let store = AppModel.shared.store(provider)
            var line = "\(provider.rawValue): " + (store.snapshot.map(describe) ?? "no reading")
            if let error = store.limitError { line += " · error: \(redact(error))" }
            line += " · \(store.samples.count) samples in history"
            if let pending = Settings.pendingReset(provider) { line += " · waiting for reset \(pending.ISO8601Format())" }
            out.append(line)
        }

        section("Settings")
        out += settings()

        section("VPN guard files")
        out += files(in: Settings.appSupport.appendingPathComponent("guard"), skip: { $0.hasPrefix("msg-") })

        let logs = Settings.appSupport.appendingPathComponent("logs")
        section("Last unread Claude Code /usage screen")
        out.append(tail(of: logs.appendingPathComponent("claude-usage-unread.txt"), characters: 12_000, clean: true))
        let buttons = logs.appendingPathComponent("claude-window-buttons.txt")
        if let date = modified(buttons) {
            out.append("")
            out.append("(claude-window-buttons.txt from \(date.ISO8601Format()) is left out: it holds the names of chats.)")
        }

        section("Activity log (last 2000 lines)")
        let activity = ["activity.1.log", "activity.log"].map { Settings.appSupport.appendingPathComponent($0) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        out.append(redact(activity.components(separatedBy: "\n").suffix(2000).joined(separator: "\n")))

        section("Phone delivery log (last 150 lines)")
        out.append(tail(of: Settings.appSupport.appendingPathComponent("phone-delivery.log"), lines: 150))

        section("Crash reports (last 14 days)")
        out += crashes()
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Parts

    private static func describe(_ snapshot: LimitSnapshot) -> String {
        func window(_ name: String, _ window: LimitWindow?) -> String? {
            window.map { "\(name) \(Int($0.usedPercent.rounded()))% resets \($0.resetsAt.ISO8601Format())" }
        }
        let parts = [window("session", snapshot.session), window("week", snapshot.weekly)].compactMap { $0 }
            + snapshot.extras.compactMap { window($0.label ?? "extra", $0) }
        return parts.joined(separator: ", ") + " · read \(snapshot.fetchedAt.ISO8601Format()) from \(snapshot.source ?? "?")"
            + (snapshot.plan.map { " · plan \($0)" } ?? "") + (snapshot.limitReached ? " · limit reached" : "")
    }

    /// Cooldown's own settings; anything that names a person, a chat or a device is left out.
    private static func settings() -> [String] {
        guard let id = Bundle.main.bundleIdentifier, let domain = UserDefaults.standard.persistentDomain(forName: id) else {
            return ["(no settings)"]
        }
        let hidden = #"(?i)token|secret|password|invite|peer|device|chat|title|name|email|account|prompt|text|draft"#
        return domain.keys.sorted().compactMap { key in
            if key.range(of: hidden, options: .regularExpression) != nil { return "\(key): <hidden>" }
            if key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("com.apple") { return nil }
            return "\(key): \(value(domain[key]))"
        }
    }

    private static func value(_ any: Any?) -> String {
        switch any {
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case let string as String: return redact(String(string.prefix(160)))
        case let date as Date: return date.ISO8601Format()
        case let data as Data: return "<\(data.count) bytes>"
        case let array as [Any]:
            let strings = array.compactMap { $0 as? String }
            if strings.count == array.count, array.count <= 12 { return "[" + strings.map { redact(String($0.prefix(60))) }.joined(separator: ", ") + "]" }
            return "[\(array.count) items]"
        case let dictionary as [String: Any]: return "{\(dictionary.count) keys}"
        default: return any.map { redact(String(describing: $0).prefix(160).description) } ?? "nil"
        }
    }

    private static func files(in folder: URL, skip: (String) -> Bool) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        if names.isEmpty { return ["(none)"] }
        return names.filter { !skip($0) }.map { name in
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? "<unreadable>"
            return "\(name): \(redact(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | ")))"
        }
    }

    private static func tail(of url: URL, characters: Int = .max, lines: Int = .max, clean: Bool = false) -> String {
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return "(none)" }
        if clean {
            // Claude Code's frames and empty lines say nothing.
            text = text.replacingOccurrences(of: "[─━═▀▄]{3,}", with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n[ \t]*(\n[ \t]*)+"#, with: "\n", options: .regularExpression)
        }
        text = String(text.components(separatedBy: "\n").suffix(lines).joined(separator: "\n").suffix(characters))
        let header = modified(url).map { "(file from \($0.ISO8601Format()))\n" } ?? ""
        return header + redact(text)
    }

    private static func crashes() -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let recent = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Cooldown") }
            .compactMap { url in modified(url).map { (url, $0) } }
            .filter { Date().timeIntervalSince($0.1) < 14 * 86_400 }
            .sorted { $0.1 > $1.1 }
        guard let newest = recent.first else { return ["(none)"] }
        var out = recent.map { "\($0.0.lastPathComponent) — \($0.1.ISO8601Format())" }
        out.append("")
        out.append("Newest, first 200 lines:")
        let text = (try? String(contentsOf: newest.0, encoding: .utf8)) ?? ""
        out.append(redact(text.components(separatedBy: "\n").prefix(200).joined(separator: "\n")))
        return out
    }

    // MARK: Helpers

    /// Takes out what could point to a person: the home folder, chat titles in «», e-mails, IP
    /// addresses and anything that looks like a token.
    nonisolated static func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
        let rules: [(String, String)] = [
            (#"«[^»\n]*»"#, "«…»"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            (#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#, "<ip>"),
            // IPv6: eight groups, or a shortened one with "::" (clock times like 13:05:12 stay).
            (#"(?<![\w:.])(?:(?:[0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}|(?:[0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{0,4}::(?:[0-9a-fA-F]{1,4}:)*[0-9a-fA-F]{1,4})(?![\w:])"#, "<ip>"),
            (#"(?i)\b(token|secret|password|authorization)(["']?\s*[:=]\s*["']?)[^\s"',}]+"#, "$1$2<hidden>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer <hidden>"),
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    /// `<tool> --version`, given five seconds.
    private nonisolated static func version(_ binary: URL) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--version"]
            var environment = ProcessInfo.processInfo.environment
            environment["DISABLE_AUTOUPDATER"] = "1"
            environment["CLAUDE_CODE_ENABLE_CFC"] = "false"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return "does not start: \(error.localizedDescription)" }
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate(); return "no answer in 5 s" }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
        }.value
    }
}
