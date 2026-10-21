import AppKit

/// Notices a newer build of Cooldown in the project folder it was installed from and offers to
/// switch to it: one press quits, puts the new build in place of this one and opens it.
@MainActor
enum UpdateWatch {
    private static var offered: Date?
    private static var timer: Timer?

    static var source: URL? {
        guard let text = try? String(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/build-source.txt"), encoding: .utf8)
        else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != Bundle.main.bundlePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func start() {
        timer = Timer.every(300) { _ in
            Task { @MainActor in UpdateWatch.check() }
        }
    }

    private static func modified(_ app: URL) -> Date? {
        let binary = app.appendingPathComponent("Contents/MacOS/Cooldown")
        return (try? FileManager.default.attributesOfItem(atPath: binary.path))?[.modificationDate] as? Date
    }

    static var newer: Bool {
        guard let source, let theirs = modified(source), let ours = modified(Bundle.main.bundleURL) else { return false }
        return theirs.timeIntervalSince(ours) > 60
    }

    private static func check() {
        guard newer, offered.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
        offered = Date()
        ToastController.shared.show(ToastContent(key: "update", kind: .info, provider: nil, title: "Есть новая сборка Cooldown",
                                                 body: "Собрана позже, чем эта. Перезапустить на ней? Настройки и история сохранятся.",
                                                 actions: [.installUpdate], life: .sticky))
    }

    /// Quits, swaps the app for the new build (the same way build.sh --install does) and opens it.
    static func install() {
        guard let source else { return }
        let target = Bundle.main.bundlePath
        let script = "sleep 1; rm -rf \"\(target)\" && cp -R \"\(source.path)\" \"\(target)\"; open \"\(target)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }
}
