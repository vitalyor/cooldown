import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--mcp") { CooldownMCP.run() }
        if arguments.contains(ClaudeStatusLine.flag) { ClaudeStatusLine.run() }
        // Started from inside a Claude Code session, the app inherits that session's variables
        // (ANTHROPIC_BASE_URL, CLAUDE_CODE_*), and every `claude` it runs then reports "Not logged in".
        for key in ProcessInfo.processInfo.environment.keys
        where (key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC")) && key != "CLAUDE_CONFIG_DIR" {
            unsetenv(key)
        }
        if let index = arguments.firstIndex(of: "--menu-icon"), index + 1 < arguments.count {
            // Diagnostic: draws the menu bar item for a few levels on dark and light bars.
            let samples: [(Double?, Double?)] = [(100, 81), (64, 50), (38, 22), (12, 4), (nil, 70)]
            let scale: CGFloat = 4
            let rowHeight: CGFloat = 22
            let canvas = NSImage(size: NSSize(width: 2 * 110 * scale, height: CGFloat(samples.count) * rowHeight * scale))
            canvas.lockFocus()
            for (column, appearance) in [NSAppearance(named: .darkAqua)!, NSAppearance(named: .aqua)!].enumerated() {
                appearance.performAsCurrentDrawingAppearance {
                    (column == 0 ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    NSRect(x: CGFloat(column) * 110 * scale, y: 0, width: 110 * scale, height: canvas.size.height).fill()
                    // Rows: idle; Claude working (two moments of the animation); Codex waiting; reduced motion.
                    let activities: [(MenuLine.Activity, MenuLine.Activity, Double, Bool)] = [
                        (.idle, .idle, 0, false), (.idle, .working, 0.1, false), (.idle, .working, 0.55, false),
                        (.waiting, .idle, 0, false), (.working, .working, 0, true)]
                    for (row, sample) in samples.enumerated() {
                        let a = activities[row]
                        let icon = GaugeIcon.image(lines: [MenuLine(remaining: sample.0, color: GaugeIcon.codex, mark: GaugeIcon.codexMark, glyph: GaugeIcon.codexGlyph, activity: a.0),
                                                           MenuLine(remaining: sample.1, color: GaugeIcon.claude, mark: GaugeIcon.claudeMark, glyph: GaugeIcon.claudeGlyph, activity: a.1)],
                                                   attention: false, showText: true, still: a.3)
                        let y = canvas.size.height - CGFloat(row + 1) * rowHeight * scale + 2 * scale
                        icon.draw(in: NSRect(x: CGFloat(column) * 110 * scale + 10 * scale, y: y,
                                            width: icon.size.width * scale, height: icon.size.height * scale))
                    }
                }
            }
            canvas.unlockFocus()
            if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arguments[index + 1]))
            }
            exit(0)
        }
        if arguments.contains("--claude-usage") {
            // Diagnostic: prints what Cooldown reads from Claude Code's /usage screen.
            // The reader reports to the main thread, so the main run loop keeps going meanwhile.
            Task { @MainActor in
                if let binary = ClaudePaths.binary(override: Settings.claudePath) {
                    do {
                        let s = try await ClaudeUsageCLI.shared.read(binary: binary, force: true)
                        for w in [s.session, s.weekly].compactMap({ $0 }) + s.extras {
                            print(w.label ?? "\(w.kind)", w.usedPercent, w.resetsAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    } catch { print("error:", error.localizedDescription) }
                } else { print("claude not found") }
                exit(0)
            }
            RunLoop.main.run()
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--resume-check"), index + 1 < arguments.count {
            // Diagnostic, read-only: what auto-continue sees for one Codex conversation.
            let started = Date()
            let list = CodexThreadIndex.conversations()
            print("conversations:", list?.count ?? -1, String(format: "(%.0f ms)", Date().timeIntervalSince(started) * 1000))
            do {
                let check = try AutoResume.inspect(arguments[index + 1])
                print(check.taskState, check.canMonitor ? "can watch" : "cannot watch", "-", check.reason, check.model ?? "")
            } catch { print("error:", error.localizedDescription) }
            print(String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000))
            exit(0)
        }
        if arguments.contains("--guard-hooks-test") {
            let failures = MainActor.assumeIsolated { GuardTest.hooks() }
            print(failures.isEmpty ? "guard-hooks-test: all passed" : "FAILED:\n" + failures.joined(separator: "\n"))
            exit(failures.isEmpty ? 0 : 1)
        }
        if let index = arguments.firstIndex(of: "--guard-test-terminal"), index + 2 < arguments.count {
            let failures = MainActor.assumeIsolated { GuardTest.terminal(home: arguments[index + 1], dummy: arguments[index + 2]) }
            print(failures.isEmpty ? "guard-terminal-test: all passed" : "FAILED:\n" + failures.joined(separator: "\n"))
            exit(failures.isEmpty ? 0 : 1)
        }
        if let index = arguments.firstIndex(of: "--settings-snapshot"), index + 2 < arguments.count {
            // Pictures: a settings pane on made-up data, drawn off screen (nothing appears or takes focus).
            let pane = SettingsPane(rawValue: arguments[index + 1]) ?? .general
            let out = arguments[index + 2]
            // Created first, as the app object: it says it is active, so controls are drawn in colour
            // as in the window in front, while it never takes focus from the person.
            let app = PictureApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                AppModel.shared.isRenderMode = true
                AppModel.shared.startForPictures()
                RouteGuard.shared.showcase()
                if let notes = arguments.firstIndex(of: "--notes").flatMap({ $0 + 2 < arguments.count ? arguments[$0 + 1] : nil }),
                   let text = try? String(contentsOfFile: notes, encoding: .utf8) {
                    GitHubUpdater.shared.showcase(version: arguments[arguments.firstIndex(of: "--notes")! + 2], notes: text)
                }
                let height = arguments.firstIndex(of: "--height").flatMap { Double(arguments[$0 + 1]) } ?? 640
                let window = SettingsWindow.shared.makeForPicture(pane, height: height)
                window.setFrameOrigin(NSPoint(x: -4000, y: 0))
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(4))
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                // With the window's shadow, as the other pictures.
                shot.arguments = ["-x", "-l", "\(window.windowNumber)", out]
                try? shot.run()
                shot.waitUntilExit()
                Settings.testDefaults?.removePersistentDomain(forName: RouteGuard.pictureSuite)
                exit(0)
            }
            app.run()
            return
        }
        if let index = arguments.firstIndex(where: { $0 == "--guard-test" || $0 == "--guard-test-hold" }), index + 2 < arguments.count {
            let home = arguments[index + 1], dummy = arguments[index + 2]
            if arguments[index] == "--guard-test-hold" { MainActor.assumeIsolated { GuardTest.hold(home: home, dummy: dummy) } }
            if arguments.contains("--tree") {
                let failures = MainActor.assumeIsolated { GuardTest.tree(home: home, dummy: dummy) }
                print(failures.isEmpty ? "guard-tree-test: all passed" : "FAILED:\n" + failures.joined(separator: "\n"))
                exit(failures.isEmpty ? 0 : 1)
            }
            Task { @MainActor in
                let failures = await GuardTest.run(home: home, dummy: dummy)
                print(failures.isEmpty ? "guard-test: all passed" : "FAILED:\n" + failures.joined(separator: "\n"))
                exit(failures.isEmpty ? 0 : 1)
            }
            dispatchMain()
        }
        if arguments.contains("--selftest") || arguments.contains("--resume-selftest") {
            let failures = MainActor.assumeIsolated { SelfTest.run() }
            print(failures.isEmpty ? "self-test: all passed" : "FAILED:\n" + failures.joined(separator: "\n"))
            exit(failures.isEmpty ? 0 : 1)
        }
        if arguments.contains("--update-check") {
            // Diagnostic: finds the latest GitHub release, downloads and verifies it, installs nothing.
            Task { @MainActor in
                let updater = GitHubUpdater.shared
                await updater.check(manual: true, announce: false)
                print("current", GitHubUpdater.current, "latest", updater.available?.version ?? "none", updater.state ?? "")
                if updater.available != nil {
                    await updater.install(dryRun: true)
                    print(updater.state ?? "")
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let index = arguments.firstIndex(of: "--hooks"), index + 1 < arguments.count {
            // `--hooks install|uninstall|status [claude|codex]`: the same as the buttons in Settings.
            let agents = arguments.count > index + 2 ? [AgentHooks.Agent(rawValue: arguments[index + 2])].compactMap { $0 } : AgentHooks.Agent.allCases
            for agent in agents {
                do {
                    switch arguments[index + 1] {
                    case "install": try AgentHooks.install(agent)
                    case "uninstall": try AgentHooks.uninstall(agent)
                    default: break
                    }
                    print(agent.rawValue, AgentHooks.status(agent))
                } catch { print(agent.rawValue, "error:", error.localizedDescription) }
            }
            exit(0)
        }
        if arguments.contains("--mcp-install") || arguments.contains("--mcp-uninstall") {
            // Diagnostic: changes only the config named by COOLDOWN_CLAUDE_CONFIG (or Claude's real
            // config when that variable is unset). The app's Settings button uses the same code.
            do {
                if arguments.contains("--mcp-install") { try CooldownMCP.install() } else { try CooldownMCP.uninstall() }
                print(CooldownMCP.isInstalled ? "mcp: on" : "mcp: off")
            } catch { print("mcp: error:", error.localizedDescription) }
            exit(0)
        }
        if arguments.contains("--diagnostics") {
            // The same checks as Settings → Diagnostics, printed as the shareable report.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                AppModel.shared.isRenderMode = true
                await AppModel.shared.prepareForRender(scan: false)
                let diagnostics = Diagnostics.shared
                diagnostics.run()
                while diagnostics.running { try? await Task.sleep(for: .milliseconds(200)) }
                print(diagnostics.report)
                exit(0)
            }
            app.run()
            return
        }
        if arguments.contains("--week-report") {
            // Diagnostic: draws this week's report picture and prints where it went.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                AppModel.shared.isRenderMode = true
                await AppModel.shared.prepareForRender(scan: false)
                print(WeeklyReport.render()?.path ?? "nothing this week")
                exit(0)
            }
            app.run()
            return
        }
        if let index = arguments.firstIndex(of: "--settings-window") {
            // Diagnostic: the settings window on one pane, for a look at the layout.
            let pane = index + 1 < arguments.count ? SettingsPane(rawValue: arguments[index + 1]) : nil
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            Task { @MainActor in
                await AppModel.shared.prepareForRender(scan: false)
                SettingsWindow.shared.show(pane ?? .general)
            }
            app.run()
            return
        }
        if let index = arguments.firstIndex(of: "--setup-snapshot"), index + 1 < arguments.count {
            // Diagnostic: the setup window as a picture, drawn off screen so nothing appears or takes focus.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                AppModel.shared.isRenderMode = true
                let window = SetupWindow.shared.make(onScreen: false)
                window.setFrameOrigin(NSPoint(x: -4000, y: 0))
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(8))
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", arguments[index + 1]]
                try? shot.run()
                shot.waitUntilExit()
                exit(0)
            }
            app.run()
            return
        }
        if arguments.contains("--render") {
            RenderMode.run(arguments: arguments)
            return
        }
        // One Cooldown at a time: a second copy (opened again, or from another folder) steps aside.
        if let me = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }),
           !arguments.contains("--snapshot"), !arguments.contains("--showcase") {
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pictures (`--snapshot`, `--showcase`): a second copy next to the real one, on demo data.
        // Nothing that watches or acts starts in it: no VPN guard (it would freeze the agents' apps),
        // no phone link (a second device on the same account), no hooks, readers or hotkey.
        let picture = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--showcase")
        if picture {
            MainActor.assumeIsolated {
                AppModel.shared.startForPictures()
                let snapshot = prepareSnapshot()
                controller = StatusController(model: AppModel.shared)
                if let snapshot { scheduleSnapshot(snapshot) }
            }
            return
        }
        Notifier.shared.setup()
        MainActor.assumeIsolated {
            AppModel.shared.start()
            Presence.shared.start()
            PhoneLink.shared.start()
            // Diagnostics: sample cards with buttons on paired phones.
            if CommandLine.arguments.contains("--link-samples") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { PhoneLink.shared.sendSamples() }
            }
            // Diagnostics: a harmless card that should reach paired phones as a notification.
            if CommandLine.arguments.contains("--link-test-card") {
                // Pushes at the Mac too, for this run only: the setting is put back as it was.
                let before = UserDefaults.standard.object(forKey: SettingsKey.phoneAlways)
                UserDefaults.standard.set(true, forKey: SettingsKey.phoneAlways)
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { UserDefaults.standard.set(before, forKey: SettingsKey.phoneAlways) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    ToastController.shared.show(ToastContent(key: "link-test", kind: .info, provider: nil, title: L("Проверка связи"),
                                                             body: L("Если это видно на iPhone, уведомления работают.") + " " + Format.time(Date()), life: .auto(10)))
                }
            }
            // Diagnostics: turn the iPhone link on and write a pairing link to the given file.
            if let i = CommandLine.arguments.firstIndex(of: "--link-invite"), i + 1 < CommandLine.arguments.count {
                let path = CommandLine.arguments[i + 1]
                Task { @MainActor in
                    let link = PhoneLink.shared
                    if link.account == nil { await link.enable() }
                    await link.makeInvite()
                    try? (link.invite?.url.absoluteString ?? (link.message ?? "failed")).write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
            let snapshot = prepareSnapshot()
            controller = StatusController(model: AppModel.shared)
            HotKey.register()
            if let snapshot { scheduleSnapshot(snapshot) } else if !CommandLine.arguments.contains("--showcase") { SetupWindow.shared.showOnFirstRun() }
            if CommandLine.arguments.contains("--toasts") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ToastController.shared.showExamples() }
            }
        }
    }

    @MainActor
    private func prepareSnapshot() -> URL? {
        let arguments = CommandLine.arguments
        // `--showcase` sets the window up the same way but leaves it open, for screenshots of the
        // real thing (glass, menu bar, cards) on made-up data: `--showcase --demo 1 --tab limits`.
        let showcase = arguments.contains("--showcase")
        let index = arguments.firstIndex(of: "--snapshot")
        guard showcase || (index.map { $0 + 1 < arguments.count } ?? false) else { return nil }
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        if let provider = value("--provider").flatMap(ProviderID.init(rawValue:)) { AppModel.shared.selected = provider }
        RootView.debugTab = value("--tab").flatMap(MainTab.init(rawValue:))
        let screens: [String: Screen] = ["add": .addTask, "schedule": .schedule, "feed": .feed]
        RootView.debugScreen = value("--screen").flatMap { screens[$0] }
        if let step = value("--demo").flatMap(Int.init) {
            DemoController.shared.start()
            DemoController.shared.jump(to: step)
            if let hold = value("--hold").flatMap(Double.init) { DemoController.shared.hold(at: hold) }
        }
        if showcase {
            RootView.hideDemoBanner = arguments.contains("--clean")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { StatusController.shared?.open() }
            return nil
        }
        return URL(fileURLWithPath: arguments[index! + 1])
    }

    @MainActor
    private func scheduleSnapshot(_ out: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.controller?.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self?.controller?.capture(to: out)
                exit(0)
            }
        }
    }

}

/// `Cooldown --render --out file.png [--provider codex|claude] [--tab limits|stats|tasks]
/// [--stats limits|tokens|projects] [--range day|week|month] [--screen add] [--dark] [--scan]`
/// draws the window with real data into a picture, for checking layout without the menu bar.
/// Glass is not drawn there; the window itself shows it.
enum RenderMode {
    @MainActor
    static func run(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let out = value("--out") ?? "/tmp/cooldown.png"
        let dark = arguments.contains("--dark")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        Task { @MainActor in
            let model = AppModel.shared
            model.isRenderMode = true
            if let provider = value("--provider").flatMap(ProviderID.init(rawValue:)) { model.selected = provider }
            await model.prepareForRender(scan: arguments.contains("--scan"))

            if arguments.contains("--menu") {
                // The menu bar picture: Codex with a task waiting 1:23 for its limit, Claude at 64 %.
                var codex = MenuLine(remaining: 0, color: GaugeIcon.codex, mark: GaugeIcon.codexMark, glyph: GaugeIcon.codexGlyph)
                codex.countdown = Date().addingTimeInterval(83 * 60)
                let claude = MenuLine(remaining: 64, color: GaugeIcon.claude, mark: GaugeIcon.claudeMark, glyph: GaugeIcon.claudeGlyph)
                let showText = arguments.contains("--percent")
                let antigravity = MenuLine(remaining: 82, color: GaugeIcon.antigravity, mark: .arch)
                let pictures = [GaugeIcon.image(lines: [codex, claude], attention: false, showText: showText),
                                GaugeIcon.image(lines: [codex], attention: false, showText: showText),
                                GaugeIcon.image(lines: [claude, antigravity], attention: false, showText: showText),
                                GaugeIcon.image(lines: [antigravity], attention: false, showText: showText)]
                let view = HStack(spacing: 20) { ForEach(0..<pictures.count, id: \.self) { Image(nsImage: pictures[$0]) } }
                    .padding(10).background(Color(nsColor: dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.92, alpha: 1)))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 4
                if let image = renderer.nsImage, let png = pngData(image) { try? png.write(to: URL(fileURLWithPath: out)) }
                print("ok \(out)")
                exit(0)
            }
            if let names = value("--cards") {
                // Several cards in a column, as they stack under the icon (pictures for the README).
                let contents = names.split(separator: ",").compactMap { CardSamples.content(String($0)) }
                let view = VStack(spacing: 16) {
                    ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                        CardSamples.view(content).frame(width: 360)
                            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
                    }
                }
                .padding(28)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                renderer.isOpaque = false
                if let image = renderer.nsImage, let png = pngData(image) { try? png.write(to: URL(fileURLWithPath: out)) }
                print("ok \(out)")
                exit(0)
            }
            if let name = value("--card") {
                guard let content = CardSamples.content(name) else { exit(2) }
                let renderer = ImageRenderer(content: CardSamples.view(content).padding(12)
                    .background(Color(nsColor: dark ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.85, alpha: 1)))
                    .environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 2
                if let image = renderer.nsImage, let png = pngData(image) { try? png.write(to: URL(fileURLWithPath: out)) }
                print("ok \(out)")
                exit(0)
            }
            let screen: Screen = value("--screen") == "add" ? .addTask : .home
            let tab = MainTab(rawValue: value("--tab") ?? "") ?? .limits
            let stats = StatsTab(rawValue: value("--stats") ?? "") ?? .limits
            let range = StatsRange(rawValue: value("--range") ?? "") ?? .day
            let view = RootView(screen: screen, tab: tab, stats: stats, range: range, render: true)
                .environmentObject(model)
                .background(Color(nsColor: dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)))
                .environment(\.colorScheme, dark ? .dark : .light)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let png = pngData(image) else {
                FileHandle.standardError.write(Data("render failed\n".utf8))
                exit(1)
            }
            try? png.write(to: URL(fileURLWithPath: out))
            print("ok \(out) \(Int(image.size.width))x\(Int(image.size.height))")
            exit(0)
        }
        app.run()
    }

    static func pngData(_ image: NSImage, scale: CGFloat = 1) -> Data? {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Pictures only (see `--settings-snapshot`).
final class PictureApplication: NSApplication {
    override var isActive: Bool { true }
}
