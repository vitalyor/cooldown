import AppKit
import CryptoKit
import Security

/// Updates Cooldown from its GitHub releases. Every few hours it looks at the latest release;
/// a newer one is downloaded (the .zip), checked against the release's SHA256SUMS.txt and against
/// Cooldown's own signature (the same certificate as the running app, or the developer's Developer ID), and
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
    /// One install at a time: the button, the card and the automatic path may all ask at once.
    @Published private(set) var installing = false

    static var repo: String? { Bundle.main.object(forInfoDictionaryKey: "CooldownUpdateRepo") as? String }
    /// The full version, "1.4.6-beta.1" for a beta (CFBundleShortVersionString keeps only "1.4.6").
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CooldownVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func version(_ release: [String: Any]) -> String {
        let tag = release["tag_name"] as? String ?? ""
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    func start() {
        // Folders of earlier runs' downloads that were never installed: once per launch, before
        // anything downloads (start runs again when the mode changes).
        if !cleaned {
            cleaned = true
            let temp = FileManager.default.temporaryDirectory
            for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasPrefix("cooldown-update-") {
                try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
            }
        }
        guard Self.repo != nil, Settings.updateMode != "off" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Task { await GitHubUpdater.shared.check() } }
        timer = Timer.every(6 * 3600) { _ in
            Task { @MainActor in if Settings.updateMode != "off" { await GitHubUpdater.shared.check() } }
        }
    }

    /// Looks for a newer release; `manual` reports the result even when there is nothing new.
    func check(manual: Bool = false, announce shouldAnnounce: Bool = true) async {
        guard let repo = Self.repo, !checking else { return }
        // Betas switched off: a beta already on offer (or downloaded) is not installed after all.
        if !Settings.updateBeta, available?.version.contains("-") == true {
            available = nil
            prepared = nil
            ToastController.shared.dismiss(key: "github-update")
        }
        checking = true
        defer { checking = false }
        do {
            // Stable: GitHub's latest release, which never is a beta. Betas: the newest of the
            // recent releases, a beta or a stable one past it.
            let beta = Settings.updateBeta
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases" + (beta ? "?per_page=20" : "/latest"))!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = beta
                    ? (parsed as? [[String: Any]])?.filter({ $0["draft"] as? Bool != true }).max(by: { Self.isNewer(Self.version($1), than: Self.version($0)) })
                    : parsed as? [String: Any],
                  object["tag_name"] is String,
                  let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else {
                if manual { state = L("Не удалось узнать о новых версиях.") }
                return
            }
            let version = Self.version(object)
            guard Self.isNewer(version, than: Self.current) else {
                available = nil
                if manual { state = L("Установлена последняя версия %@.", "\(Self.current)") }
                return
            }
            let assets = object["assets"] as? [[String: Any]] ?? []
            func asset(_ match: (String) -> Bool) -> URL? {
                assets.first { match($0["name"] as? String ?? "") }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
            }
            // The app's own archive (a release may carry other zips, symbols say).
            guard let zip = asset({ $0.hasPrefix("Cooldown") && $0.hasSuffix(".zip") }) else { return }
            let release = Release(version: version, page: page, zip: zip, sums: asset { $0 == "SHA256SUMS.txt" },
                                  notes: object["body"] as? String ?? "")
            available = release
            state = nil
            if shouldAnnounce { announce(release) }
        } catch {
            if manual { state = L("Нет связи с GitHub.") }
        }
    }

    /// Pictures only: a release on offer with these notes (nothing is downloaded).
    func showcase(version: String, notes: String) {
        let page = URL(string: "https://github.com/vitalyor/cooldown/releases")!
        available = Release(version: version, page: page, zip: page, sums: nil, notes: notes)
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
                // A card that cannot be shown now (screen locked, quiet hours) is offered at the next check.
                guard prepared?.version == release.version, offered != release.version, ToastController.shared.canShow else { return }
                offered = release.version
                ToastController.shared.show(ToastContent(key: "github-update", kind: .info, provider: nil,
                                                         title: L("Cooldown %@ загружена", "\(release.version)"),
                                                         body: L("Проверена и готова. Установка займёт пару секунд; настройки и история сохранятся."),
                                                         actions: [.installRelease, .openReleasePage], life: .sticky))
            }
            return
        }
        if mode == "auto" {
            // This version failed to swap in once: no quiet retries at every check; a card instead.
            if UserDefaults.standard.string(forKey: "updateFailed") == release.version {
                offerCard(release)
                return
            }
            // Installed when nobody is in the middle of something: the Mac idle a couple of minutes.
            // Not while the VPN guard holds something (a restart would let the apps go for a
            // moment), nor while phone commands wait for the Mac to be unlocked (a restart would
            // lose them).
            if (ToastController.idleSeconds > 120 || ToastController.screenLocked) && !RouteGuard.shared.holding
                && !PhoneLink.shared.commandsWaiting {
                Task { await install() }
            } else {
                // Waiting more than a day (the guard keeps holding, the Mac is never idle): say so
                // with a card, so the update does not wait unseen for ever.
                if autoWaitSince[release.version] == nil { autoWaitSince[release.version] = Date() }
                if let since = autoWaitSince[release.version], Date().timeIntervalSince(since) > 24 * 3600 { offerCard(release) }
                // One retry at a time, for the release still on offer.
                retry?.cancel()
                retry = Task { @MainActor in
                    guard (try? await Task.sleep(for: .seconds(300))) != nil,
                          Settings.updateMode == "auto", GitHubUpdater.shared.available == release else { return }
                    GitHubUpdater.shared.announce(release)
                }
            }
            return
        }
        guard offered != release.version, ToastController.shared.canShow else { return }
        offered = release.version
        ToastController.shared.show(ToastContent(key: "github-update", kind: .info, provider: nil,
                                                 title: L("Доступна версия Cooldown %@", "\(release.version)"),
                                                 body: L("Сейчас установлена %@. Обновление займёт несколько секунд; настройки и история сохранятся.", "\(Self.current)"),
                                                 actions: [.installRelease, .openReleasePage], life: .sticky))
    }

    private var autoWaitSince: [String: Date] = [:]

    private func offerCard(_ release: Release) {
        guard offered != release.version, ToastController.shared.canShow else { return }
        offered = release.version
        ToastController.shared.show(ToastContent(key: "github-update", kind: .info, provider: nil,
                                                 title: L("Доступна версия Cooldown %@", "\(release.version)"),
                                                 body: L("Сейчас установлена %@. Обновление займёт несколько секунд; настройки и история сохранятся.", "\(Self.current)"),
                                                 actions: [.installRelease, .openReleasePage], life: .sticky))
    }

    /// Where the app runs from, if an update cannot replace it there.
    static var locationProblem: String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return L("Cooldown запущен не из папки «Программы». Перенесите его туда — тогда он сможет обновляться.")
        }
        if !FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return L("Нет прав на запись в папку, где лежит Cooldown. Обновите его вручную с GitHub или попросите администратора.")
        }
        return nil
    }

    // MARK: Installing

    enum UpdateError: LocalizedError {
        case checksum, checksumMissing, signature, unpack
        var errorDescription: String? {
            switch self {
            case .checksum: return L("Файл повреждён при загрузке (не совпала контрольная сумма).")
            case .checksumMissing: return L("В релизе нет SHA256SUMS.txt — обновление не установлено.")
            case .signature: return L("Новая версия подписана не тем же сертификатом — не устанавливаю.")
            case .unpack: return L("Не удалось распаковать новую версию.")
            }
        }
    }

    /// `dryRun`: download and check everything, but do not replace the app (for diagnostics).
    func install(dryRun: Bool = false) async {
        guard !installing, let release = available else { return }
        guard Settings.updateBeta || !release.version.contains("-") else { available = nil; return }
        if !dryRun, let problem = Self.locationProblem {
            // Said before anything is downloaded, and once per version (not at every check).
            state = problem
            if UserDefaults.standard.string(forKey: "updateLocationSaid") != release.version {
                UserDefaults.standard.set(release.version, forKey: "updateLocationSaid")
                ToastController.shared.show(ToastCatalog.failure(L("Обновление не установлено"), problem))
            }
            return
        }
        if !dryRun, RouteGuard.shared.holding || PhoneLink.shared.commandsWaiting {
            // A restart would let the paused apps go for a moment, or lose the phone's commands.
            state = L("Обновлю, когда защита VPN отпустит приложения и команды с телефона выполнятся.")
            ToastController.shared.show(ToastCatalog.failure(L("Обновление отложено"), state ?? ""))
            return
        }
        installing = true
        defer { installing = false }
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
            UserDefaults.standard.set(release.version, forKey: "updatingTo")
            try Self.replaceApp(with: app)
        } catch {
            state = L("Обновление не установлено: %@", "\(error.localizedDescription)")
            ToastController.shared.show(ToastCatalog.failure(L("Обновление не установлено"), error.localizedDescription))
        }
    }

    /// Downloads the release and checks it (checksum, same signature); returns the new app.
    private var retry: Task<Void, Never>?
    private var cleaned = false

    private func prepare(_ release: Release) async throws -> URL {
        state = L("Загружаю %@…", "\(release.version)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: release.zip)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unpack }
            let zip = folder.appendingPathComponent(release.zip.lastPathComponent)
            try FileManager.default.moveItem(at: downloaded, to: zip)

            guard let sums = release.sums else { throw UpdateError.checksumMissing }
            let (data, _) = try await URLSession.shared.data(from: sums)
            let text = String(decoding: data, as: UTF8.self)
            // Hashing, unpacking and the signature check take seconds: not on the main thread.
            let app = try await Task.detached(priority: .utility) { () throws -> URL in
                let digest = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                guard lines.contains(where: { $0.hasPrefix(digest) && $0.hasSuffix(zip.lastPathComponent) }) else {
                    throw UpdateError.checksum
                }
                try Self.unpack(zip, into: folder)
                let app = folder.appendingPathComponent("Cooldown.app")
                guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.unpack }
                guard Self.signedLikeMe(app) else { throw UpdateError.signature }
                return app
            }.value
            prepared = (release.version, app)
            readyVersion = release.version
            state = nil
            return app
        } catch {
            try? FileManager.default.removeItem(at: folder)
            state = L("Не удалось загрузить %@: %@", "\(release.version)", "\(error.localizedDescription)")
            throw error
        }
    }

    /// The developer's Apple team: releases signed with its Developer ID certificate.
    nonisolated static let teamID = "PB68QTT4YR"

    /// The new build must be Cooldown signed either like the running app (same identifier, same
    /// certificate) or with the developer's Developer ID — the certificate releases moved to from
    /// a self-made one. A file swapped on the way fails both.
    nonisolated static func signedLikeMe(_ app: URL) -> Bool {
        var other: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me,
           SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
           SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
           SecStaticCodeCheckValidity(other, flags, requirement) == errSecSuccess {
            return true
        }
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        // Apple's own wording for "Developer ID Application certificate of this team".
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists " // l10n:skip
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamID)\"" // l10n:skip
        var developerID: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &developerID) == errSecSuccess, let developerID else { return false }
        return SecStaticCodeCheckValidity(other, flags, developerID) == errSecSuccess
    }

    /// Quits, then (in a small shell step) replaces this app with the new one and opens it.
    /// The new bundle is copied next to the old one first; the old one is kept until the move back
    /// would still be possible, so a failed copy never leaves a Mac without Cooldown.
    /// Replaces the running app with `app` and opens it. Also used by the local-build switch.
    static func replaceApp(with app: URL) throws {
        let target = Bundle.main.bundlePath
        let staged = target + ".new"
        let backup = target + ".previous"
        let parent = (target as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.unpack }

        // Copy before quitting: a slow disk must not leave the app installed halfway.
        try? FileManager.default.removeItem(atPath: staged)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [app.path, staged]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0, FileManager.default.fileExists(atPath: staged) else {
            try? FileManager.default.removeItem(atPath: staged)
            throw UpdateError.unpack
        }
        // What will be swapped in is the copy, not the checked download: check the copy itself,
        // so nothing that changed it on the way (the app's folder may be writable by others) runs.
        guard signedLikeMe(URL(fileURLWithPath: staged)) else {
            try? FileManager.default.removeItem(atPath: staged)
            throw UpdateError.signature
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        UserDefaults.standard.set(current, forKey: "updatedFrom")
        // Paths travel as arguments, never interpolated into shell code: a path with a quote or a
        // semicolon must not become a command.
        let script = """
        #!/bin/sh
        set -u
        target="$1"
        staged="$2"
        backup="$3"
        pid="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$backup"
        if ! mv "$target" "$backup"; then exit 1; fi
        if mv "$staged" "$target"; then
          rm -rf "$backup"
          open "$target"
        else
          rm -rf "$target"
          mv "$backup" "$target"
          rm -rf "$staged"
          open "$target"
          exit 1
        fi
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("cooldown-swap-\(UUID().uuidString).sh")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, target, staged, backup, String(pid)]
        try process.run()
        NSApp.terminate(nil)
    }

    /// After a restart on a new version: one short line about it.
    func greetIfUpdated() {
        guard let from = UserDefaults.standard.string(forKey: "updatedFrom") else { return }
        UserDefaults.standard.removeObject(forKey: "updatedFrom")
        let target = UserDefaults.standard.string(forKey: "updatingTo")
        UserDefaults.standard.removeObject(forKey: "updatingTo")
        guard from != Self.current else {
            // Restarted on the same version: the new one could not be put in place.
            guard let target, target != Self.current else { return }
            UserDefaults.standard.set(target, forKey: "updateFailed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                ToastController.shared.show(ToastCatalog.failure(L("Обновление не установлено"),
                    L("Версию %@ не удалось поставить на место старой. Скачайте её с GitHub и перетащите в «Программы».", target)))
            }
            return
        }
        EventLog.shared.add(CooldownEvent(kind: .info, provider: nil, title: L("Cooldown обновлён до %@", "\(Self.current)"), body: L("Была версия %@.", "\(from)")))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            ToastController.shared.show(ToastContent(key: "updated", kind: .info, provider: nil,
                                                     title: L("Cooldown обновлён до %@", "\(Self.current)"),
                                                     body: L("Что нового — на странице релиза."), actions: [.openReleasePage], life: .auto(10)))
        }
    }

    func openReleasePage() {
        let url = available?.page ?? Self.repo.flatMap { URL(string: "https://github.com/\($0)/releases/tag/v\(Self.current)") }
        if let url { NSWorkspace.shared.open(url) }
    }

    nonisolated private static func unpack(_ zip: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpack }
    }

    /// 1.2.10 > 1.2.9: numbers compared part by part; 1.4.6 > 1.4.6-beta.2 > 1.4.6-beta.1 > 1.4.5.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> (numbers: [Int], beta: Int) {
            let halves = version.split(separator: "-", maxSplits: 1)
            let numbers = (halves.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            // A stable version is past every beta of it.
            let beta = halves.count > 1 ? Int(halves[1].split(separator: ".").last ?? "") ?? 0 : Int.max
            return (numbers, beta)
        }
        let (a, betaA) = parts(candidate), (b, betaB) = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return betaA > betaB
    }
}
