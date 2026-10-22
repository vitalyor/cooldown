import AppKit
import CryptoKit
import Security

/// Updates Cooldown from its GitHub releases. Every few hours it looks at the latest release;
/// a newer one is downloaded (the .zip), checked against the release's SHA256SUMS.txt and against
/// Cooldown's own signature (it must be signed by the same certificate as the running app), and
/// then put in place of this app, which restarts on it. Settings and history stay where they are.
@MainActor
final class GitHubUpdater: ObservableObject {
    static let shared = GitHubUpdater()

    struct Release: Equatable {
        var version: String
        var page: URL
        var zip: URL
        var sums: URL?
        var notes: String
    }

    @Published private(set) var available: Release?
    @Published private(set) var state: String?
    @Published private(set) var checking = false
    private var timer: Timer?
    private var offered: String?
    /// A downloaded and verified new version, ready to be put in place.
    private var prepared: (version: String, app: URL)?
    @Published private(set) var readyVersion: String?

    static var repo: String? { Bundle.main.object(forInfoDictionaryKey: "CooldownUpdateRepo") as? String }
    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        guard Self.repo != nil, Settings.updateMode != "off" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Task { await GitHubUpdater.shared.check() } }
        timer = Timer.every(6 * 3600) { _ in
            Task { @MainActor in if Settings.updateMode != "off" { await GitHubUpdater.shared.check() } }
        }
    }

    /// Looks for a newer release; `manual` reports the result even when there is nothing new.
    func check(manual: Bool = false, announce shouldAnnounce: Bool = true) async {
        guard let repo = Self.repo, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = object["tag_name"] as? String,
                  let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else {
                if manual { state = L("Не удалось узнать о новых версиях.") }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(version, than: Self.current) else {
                available = nil
                if manual { state = L("Установлена последняя версия %@.", "\(Self.current)") }
                return
            }
            let assets = object["assets"] as? [[String: Any]] ?? []
            func asset(_ match: (String) -> Bool) -> URL? {
                assets.first { match($0["name"] as? String ?? "") }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            }
            guard let zip = asset({ $0.hasSuffix(".zip") }) else { return }
            let release = Release(version: version, page: page, zip: zip, sums: asset { $0 == "SHA256SUMS.txt" },
                                  notes: object["body"] as? String ?? "")
            available = release
            state = nil
            if shouldAnnounce { announce(release) }
        } catch {
            if manual { state = L("Нет связи с GitHub.") }
        }
    }

    /// The update mode changed in Settings.
    func modeChanged() {
        timer?.invalidate()
        timer = nil
        start()
    }

    private func announce(_ release: Release) {
        let mode = Settings.updateMode
        if mode == "download" {
            Task {
                if prepared?.version != release.version { _ = try? await prepare(release) }
                guard prepared?.version == release.version, offered != release.version else { return }
                offered = release.version
                ToastController.shared.show(ToastContent(key: "github-update", kind: .info, provider: nil,
                                                         title: L("Cooldown %@ загружена", "\(release.version)"),
                                                         body: L("Проверена и готова. Установка займёт пару секунд; настройки и история сохранятся."),
                                                         actions: [.installRelease, .openReleasePage], life: .sticky))
            }
            return
        }
        if mode == "auto" {
            // Installed when nobody is in the middle of something: the Mac idle a couple of minutes.
            if ToastController.idleSeconds > 120 || ToastController.screenLocked {
                Task { await install() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) { GitHubUpdater.shared.announce(release) }
            }
            return
        }
        guard offered != release.version else { return }
        offered = release.version
        ToastController.shared.show(ToastContent(key: "github-update", kind: .info, provider: nil,
                                                 title: L("Доступна версия Cooldown %@", "\(release.version)"),
                                                 body: L("Сейчас установлена %@. Обновление займёт несколько секунд; настройки и история сохранятся.", "\(Self.current)"),
                                                 actions: [.installRelease, .openReleasePage], life: .sticky))
    }

    // MARK: Installing

    enum UpdateError: LocalizedError {
        case checksum, signature, unpack
        var errorDescription: String? {
            switch self {
            case .checksum: return L("Файл повреждён при загрузке (не совпала контрольная сумма).")
            case .signature: return L("Новая версия подписана не тем же сертификатом — не устанавливаю.")
            case .unpack: return L("Не удалось распаковать новую версию.")
            }
        }
    }

    /// `dryRun`: download and check everything, but do not replace the app (for diagnostics).
    func install(dryRun: Bool = false) async {
        guard let release = available else { return }
        do {
            let app: URL
            if let prepared, prepared.version == release.version, FileManager.default.fileExists(atPath: prepared.app.path),
               Self.signedLikeMe(prepared.app) {
                app = prepared.app
            } else {
                app = try await prepare(release)
            }
            if dryRun { state = L("Проверено: %@ готова к установке.", "\(release.version)"); return }
            state = L("Устанавливаю %@…", "\(release.version)")
            Self.swap(to: app)
        } catch {
            state = L("Обновление не установлено: %@", "\(error.localizedDescription)")
            ToastController.shared.show(ToastCatalog.failure(L("Обновление не установлено"), error.localizedDescription))
        }
    }

    /// Downloads the release and checks it (checksum, same signature); returns the new app.
    private func prepare(_ release: Release) async throws -> URL {
        state = L("Загружаю %@…", "\(release.version)")
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (downloaded, _) = try await URLSession.shared.download(from: release.zip)
            let zip = folder.appendingPathComponent(release.zip.lastPathComponent)
            try FileManager.default.moveItem(at: downloaded, to: zip)

            if let sums = release.sums {
                let (data, _) = try await URLSession.shared.data(from: sums)
                let text = String(decoding: data, as: UTF8.self)
                let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard text.split(separator: "\n").contains(where: { $0.hasPrefix(digest) && $0.hasSuffix(zip.lastPathComponent) }) else {
                    throw UpdateError.checksum
                }
            }
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
            let app = folder.appendingPathComponent("Cooldown.app")
            guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.unpack }
            guard Self.signedLikeMe(app) else { throw UpdateError.signature }
            prepared = (release.version, app)
            readyVersion = release.version
            state = nil
            return app
        } catch {
            state = L("Не удалось загрузить %@: %@", "\(release.version)", "\(error.localizedDescription)")
            throw error
        }
    }

    /// The new build must satisfy the running app's own designated requirement: same identifier,
    /// same certificate. A file swapped on the way would fail here.
    static func signedLikeMe(_ app: URL) -> Bool {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var other: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess
    }

    /// Quits, then (in a small shell step) replaces this app with the new one and opens it.
    private static func swap(to app: URL) {
        let target = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        UserDefaults.standard.set(current, forKey: "updatedFrom")
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target)" && /usr/bin/ditto "\(app.path)" "\(target)" && open "\(target)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// After a restart on a new version: one short line about it.
    func greetIfUpdated() {
        guard let from = UserDefaults.standard.string(forKey: "updatedFrom") else { return }
        UserDefaults.standard.removeObject(forKey: "updatedFrom")
        guard from != Self.current else { return }
        EventLog.shared.add(CooldownEvent(kind: .info, provider: nil, title: L("Cooldown обновлён до %@", "\(Self.current)"), body: L("Была версия %@.", "\(from)")))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            ToastController.shared.show(ToastContent(key: "updated", kind: .info, provider: nil,
                                                     title: L("Cooldown обновлён до %@", "\(Self.current)"),
                                                     body: L("Что нового — на странице релиза."), actions: [.openReleasePage], life: .auto(10)))
        }
    }

    func openReleasePage() {
        let url = available?.page ?? Self.repo.flatMap { URL(string: "https://github.com/\($0)/releases/latest") }
        if let url { NSWorkspace.shared.open(url) }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpack }
    }

    /// 1.2.10 > 1.2.9: numbers compared part by part.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
