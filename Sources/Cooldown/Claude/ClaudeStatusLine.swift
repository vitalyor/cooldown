import Foundation

/// Cooldown as Claude Code's status line command. Claude Code pipes its session JSON to it on
/// every update; Cooldown keeps the plan limits and passes everything on to the command that was
/// there before (if any), printing what that command prints. It must be quick and never block.
enum ClaudeStatusLine {
    static let flag = "--statusline"

    static var command: String {
        let executable = Bundle.main.executablePath ?? "/Applications/Cooldown.app/Contents/MacOS/Cooldown"
        return "\"\(executable)\" \(flag)"
    }

    // MARK: Running as the status line

    private static let loopGuard = "COOLDOWN_STATUSLINE_ACTIVE"

    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
           let limits = object["rate_limits"] as? [String: Any] {
            var saved: [String: Any] = ["savedAt": Date().timeIntervalSince1970, "rate_limits": limits]
            if let session = object["session_id"] { saved["session_id"] = session }
            if let model = (object["model"] as? [String: Any])?["display_name"] { saved["model"] = model }
            if let data = try? JSONSerialization.data(withJSONObject: saved) {
                try? data.write(to: ClaudePaths.bridgeFile, options: .atomic)
            }
        }

        // Another status line may have saved Cooldown as *its* previous command (Coucou does this);
        // running it again would loop forever, so a nested call only records the limits.
        let nested = ProcessInfo.processInfo.environment[loopGuard] != nil
        if nested { exit(0) }
        if let previous = previousCommand(), !previous.contains(flag) || !previous.contains("Cooldown") {
            if let output = runPrevious(previous, input: input) { FileHandle.standardOutput.write(output) }
        } else if let line = ownLine(input) {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        exit(0)
    }

    private static func ownLine(_ input: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let limits = object["rate_limits"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let five = limits["five_hour"] as? [String: Any], let used = Num.double(five["used_percentage"]) {
            parts.append("5 ч: осталось \(Int((100 - used).rounded()))%")
        }
        if let week = limits["seven_day"] as? [String: Any], let used = Num.double(week["used_percentage"]) {
            parts.append("неделя: \(Int((100 - used).rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func runPrevious(_ command: String, input: Data) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment[loopGuard] = "1"
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()

        var output = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            return nil
        }
        return output.prefix(64 * 1024)
    }

    // MARK: Installing into ~/.claude/settings.json

    static var isInstalled: Bool {
        guard let line = currentStatusLine(), let command = line["command"] as? String else { return false }
        return command.contains(flag) && command.contains("Cooldown")
    }

    static func previousCommand() -> String? {
        guard let data = try? Data(contentsOf: ClaudePaths.previousStatusLine),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let line = object["statusLine"] as? [String: Any],
              let command = line["command"] as? String, !command.isEmpty else { return nil }
        return command
    }

    /// Who currently fills the status line, in plain words, for the confirmation text.
    static func currentOwner() -> String? {
        guard let command = currentStatusLine()?["command"] as? String, !command.isEmpty else { return nil }
        if command.contains("NotchBuddy") || command.contains("nb-hook") { return "Coucou" }
        if command.contains("Cooldown") { return "Cooldown" }
        return "своя команда"
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: ClaudePaths.settings.path) else { return [:] }
        let data = try Data(contentsOf: ClaudePaths.settings)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Cooldown", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json Claude Code имеет неожиданный формат, Cooldown его не трогает."])
        }
        return object
    }

    private static func currentStatusLine() -> [String: Any]? {
        (try? readSettings())?["statusLine"] as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let url = ClaudePaths.settings
        if FileManager.default.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.bak-cooldown-\(stamp)")
            try FileManager.default.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Puts Cooldown in front of the existing status line command, keeping that command working.
    static func install() throws {
        var settings = try readSettings()
        let existing = settings["statusLine"] as? [String: Any]
        if let command = existing?["command"] as? String, command.contains(flag) && command.contains("Cooldown") {
            return
        }
        let previous: [String: Any] = existing.map { ["statusLine": $0] } ?? [:]
        let data = try JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted])
        try data.write(to: ClaudePaths.previousStatusLine, options: .atomic)

        var line = existing ?? [:]
        line["type"] = "command"
        line["command"] = command
        settings["statusLine"] = line
        try writeSettings(settings)
    }

    /// Restores the status line exactly as it was before Cooldown took its place.
    static func uninstall() throws {
        var settings = try readSettings()
        guard let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String,
              command.contains(flag) && command.contains("Cooldown") else { return }
        let previous = (try? Data(contentsOf: ClaudePaths.previousStatusLine))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["statusLine"]
        if let previous { settings["statusLine"] = previous } else { settings.removeValue(forKey: "statusLine") }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: ClaudePaths.previousStatusLine)
    }
}
