import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains(ClaudeStatusLine.flag) { ClaudeStatusLine.run() }
        if let index = arguments.firstIndex(of: "--menu-icon"), index + 1 < arguments.count {
            // Diagnostic: draws the menu bar item for a few levels on dark and light bars.
            let samples: [(Double?, Double?)] = [(100, 81), (64, 50), (38, 22), (12, 4), (nil, 70)]
            let scale: CGFloat = 4
            let rowHeight: CGFloat = 22
            let canvas = NSImage(size: NSSize(width: 2 * 110 * scale, height: CGFloat(samples.count) * rowHeight * scale))
            canvas.lockFocus()
            for (column, appearance) in [NSAppearance(named: .darkAqua)!, NSAppearance(named: .aqua)!].enumerated() {
                NSAppearance.current = appearance
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
        if arguments.contains("--resume-selftest") {
            let failures = ResumeSelfTest.run()
            print(failures.isEmpty ? "auto-continue self-test: all passed" : "FAILED:\n" + failures.joined(separator: "\n"))
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
        if arguments.contains("--render") {
            RenderMode.run(arguments: arguments)
            return
        }
        // One Cooldown at a time: a second copy (opened again, or from another folder) steps aside.
        if let me = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }),
           !arguments.contains("--snapshot") {
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
        Notifier.shared.setup()
        MainActor.assumeIsolated {
            AppModel.shared.start()
            let snapshot = prepareSnapshot()
            controller = StatusController(model: AppModel.shared)
            HotKey.register()
            if let snapshot { scheduleSnapshot(snapshot) }
            if CommandLine.arguments.contains("--toasts") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ToastController.shared.showExamples() }
            }
        }
    }

    @MainActor
    private func prepareSnapshot() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        if let provider = value("--provider").flatMap(ProviderID.init(rawValue:)) { AppModel.shared.selected = provider }
        RootView.debugTab = value("--tab").flatMap(MainTab.init(rawValue:))
        let screens: [String: Screen] = ["settings": .settings, "add": .addTask, "schedule": .schedule, "feed": .feed]
        RootView.debugScreen = value("--screen").flatMap { screens[$0] }
        if let step = value("--demo").flatMap(Int.init) {
            DemoController.shared.start()
            DemoController.shared.jump(to: step)
        }
        return URL(fileURLWithPath: arguments[index + 1])
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
/// [--stats limits|tokens|projects] [--range day|week|month] [--screen settings|add] [--dark] [--scan]`
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

            let screen: Screen = value("--screen") == "settings" ? .settings : value("--screen") == "add" ? .addTask : .home
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
