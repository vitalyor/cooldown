import AppKit
import CooldownLink
import Foundation

@MainActor
extension PhoneLink {
    // MARK: Receiving

    func handle(_ frame: LinkFrame) {
        switch frame.t {
        case "ready":
            lastState = nil
            endSent = false
            refreshLive = true
            publishState(now: true)
            Task { await refreshDevices() }
        case "paired":
            paired(frame)
        case "error":
            AgentActivity.trace("phone: relay refused env=\(frame.id ?? "") — \(frame.code ?? "") \(frame.text ?? "")")
        case "delivered":
            delivered(frame, ok: true)
        case "undelivered":
            delivered(frame, ok: false)
        case "presence":
            if frame.online == true { lastState = nil; publishState(now: true) }
            Task { await refreshDevices() }
        case "unpaired":
            if frame.device == account?.device {
                // Removed at the relay (from another Mac or by the server): start over.
                Task { await disable() }
            } else if let id = frame.device {
                forget(id)
            }
        case "env":
            guard let session, let id = frame.id else { return }
            guard let box = try? session.open(frame), let from = frame.from else { return }
            client?.got([id])
            receive(box, from: from)
        default:
            break
        }
    }

    func receive(_ box: LinkBox, from phone: String) {
        switch box.m {
        case .cmd:
            guard let cmd = box.cmd else { return }
            if done[cmd.id] != nil { return }
            if box.ts.addingTimeInterval(cmd.ttl) < Date() {
                reply(LinkResult(cmd: cmd.id, code: "stale", text: L("Команда устарела и не выполнена.")), to: phone)
                return
            }
            remember(cmd.id)
            AgentActivity.trace("phone \(phone): \(cmd.op.rawValue) \(cmd.args.filter { $0.key != "text" && $0.key != "log" })")
            Task {
                let result = await run(cmd, from: phone)
                AgentActivity.trace("phone \(phone): \(cmd.op.rawValue) → \(result.code)\(result.code == "ok" ? "" : " «\(String(result.text.prefix(160)))»")")
                // A press that worked needs no notification: the card simply goes away.
                reply(result, to: phone, quiet: cmd.op == .chats || cmd.op == .refresh || cmd.op == .diag || (cmd.op == .cardAct && result.ok))
                scheduleState()
            }
        case .resolve:
            // Closed on the phone: closed here too.
            if let key = box.key {
                cards.removeValue(forKey: key)
                ToastController.shared.dismiss(key: key)
            }
        default:
            break
        }
    }

    func remember(_ id: String) {
        done[id] = Date()
        let dayAgo = Date().addingTimeInterval(-86400)
        done = done.filter { $0.value > dayAgo }
        UserDefaults.standard.set(done.mapValues(\.timeIntervalSince1970), forKey: "phoneLinkDone")
    }

    /// The answer to a press goes back as a quiet notification, so a press from the lock screen
    /// gets its outcome even with the app closed. Lists and refreshes need none.
    func reply(_ result: LinkResult, to phone: String, quiet: Bool = false) {
        let push = quiet || result.text.isEmpty ? nil
            : LinkPush(collapse: LinkCard.collapseID("result-" + result.cmd), sound: !result.ok, level: result.ok ? "passive" : "active")
        send(.result(result), to: [phone], ttl: 3600, push: push)
    }

    func phoneName(_ id: String) -> String { account?.peers.first { $0.id == id }?.name ?? "iPhone" }

    func note(_ phone: String, _ what: String, provider: ProviderID? = nil) {
        EventLog.shared.add(CooldownEvent(kind: .info, provider: provider, title: L("С %@: %@", "\(phoneName(phone))", "\(what)"), body: ""))
    }

    // MARK: Commands

    func run(_ cmd: LinkCommand, from phone: String) async -> LinkResult {
        let ok = { (text: String) in LinkResult(cmd: cmd.id, code: "ok", text: text) }
        switch cmd.op {
        case .refresh:
            lastState = nil
            publishState(now: true)
            return ok("")
        case .chats:
            return await chats(cmd)
        case .watch:
            return await watch(cmd, from: phone)
        case .cardAct:
            return await act(cmd, from: phone)
        case .diag:
            // The phone's own delivery log: what arrived when, so delivery can be checked end to end.
            let text = (cmd.args["log"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // Kept small, like activity.log: the latest megabyte, in two files.
                LogFile.append("— \(phoneName(phone)), \(Date().formatted(.iso8601))\n\(String(text.suffix(64 * 1024)))\n",
                               to: "phone-delivery", limit: 512 * 1024)
            }
            return ok("")
        }
    }

    func act(_ cmd: LinkCommand, from phone: String) async -> LinkResult {
        var key = cmd.args["key"] ?? ""
        let actionID = cmd.args["action"] ?? ""
        // From a Live Activity button: the card by its opaque id.
        if key.hasPrefix("#"), let found = cards.first(where: { $0.value.card.collapseID == String(key.dropFirst()) }) {
            key = found.key
        }
        guard let item = cards[key] else {
            return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально: карточку закрыли или ответили на Mac."))
        }
        let content = item.content
        if key.hasPrefix("linkdemo") {
            // A sample card: the press made it all the way here, and nothing is done.
            resolve(key, by: phone)
            return LinkResult(cmd: cmd.id, code: "ok", text: L("Пример · ничего не отправлено"))
        }
        if actionID.hasPrefix("choice:") {
            var choiceID = String(actionID.dropFirst("choice:".count))
            // "step2:option:1": an answer to the third question; any other question on the card now
            // (answered on the Mac meanwhile, or a second press) makes it stale.
            if choiceID.range(of: #"^step\d+:"#, options: .regularExpression) != nil, let colon = choiceID.firstIndex(of: ":") {
                let step = Int(choiceID[choiceID.index(choiceID.startIndex, offsetBy: 4)..<colon])
                guard content.step != nil, step == content.step else {
                    return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально: на этот вопрос уже ответили."))
                }
                choiceID = String(choiceID[choiceID.index(after: colon)...])
            }
            guard let requestKey = content.requestKey, RequestCenter.shared.isPending(requestKey),
                  var choice = content.choices.first(where: { $0.id == choiceID }) else {
                return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально: агент больше не ждёт ответа."))
            }
            if choice.role == .input {
                let text = (cmd.args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return LinkResult(cmd: cmd.id, code: "failed", text: L("Введите ответ.")) }
                choice = RequestChoice(id: "text:" + text, title: choice.title)
            }
            note(phone, L("ответ «%@»", "\(choice.title)"), provider: content.provider)
            RequestCenter.shared.answer(requestKey, choice)
            if choice.id.hasPrefix("option:") { return LinkResult(cmd: cmd.id, code: "ok", text: L("Принято.")) }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if !RequestCenter.shared.isPending(requestKey) {
                    return LinkResult(cmd: cmd.id, code: "ok", text: L("Ответ отправлен: «%@».", "\(choice.title)"))
                }
            }
            return LinkResult(cmd: cmd.id, code: "failed", text: L("Ответ не дошёл. Откройте чат на Mac и ответьте там."))
        }
        if actionID == "reply" {
            let text = (cmd.args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Only a card that offered "Ответить" (a finished turn) takes a reply.
            guard content.kind == .finished else {
                return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
            }
            guard !text.isEmpty, let opener = Self.chat(of: content) else {
                return LinkResult(cmd: cmd.id, code: "failed", text: L("Пустой ответ не отправлен."))
            }
            return await replyText(text, to: opener, cmd: cmd, phone: phone, key: key)
        }
        guard let action = content.actions.first(where: { Self.actionID($0) == actionID }) else {
            return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
        }
        let typesIntoClaude: Bool
        switch action {
        case .continueClaude, .continueClaudeChat, .continueAllClaude: typesIntoClaude = true
        default: typesIntoClaude = false
        }
        // Answered from the phone: the Mac does not bring the same card up again later.
        ClaudeChatList.shared.cardClosed(key)
        if typesIntoClaude && ToastController.screenLocked {
            // The Live Activity sends "#<collapse id>"; the deferred lookup needs the real key.
            var deferred = cmd
            deferred.args["key"] = key
            afterUnlock.append((deferred, phone, Date()))
            note(phone, L("«%@» — после разблокировки", "\(action.title)"), provider: content.provider)
            return LinkResult(cmd: cmd.id, code: "locked", text: L("Mac заблокирован. Отправлю, как только его разблокируют."))
        }
        return await perform(action, key: key, cmd: cmd, phone: phone)
    }

    func perform(_ action: ToastAction, key: String, cmd: LinkCommand, phone: String) async -> LinkResult {
        let provider = cards[key]?.content.provider
        ToastController.shared.dismiss(key: key) // also takes it off every phone
        note(phone, action.title, provider: provider)
        do {
            switch action {
            case .continueClaude:
                let chat = ClaudeSender.pendingChat
                try await ClaudeSender.continueChat(chat)
                return LinkResult(cmd: cmd.id, code: "ok", text: chat.map { L("Отправлено в «%@».", "\($0.title)") } ?? L("Отправлено в открытый чат Claude."))
            case .continueClaudeChat(let chat):
                try await ClaudeSender.continueChat(chat)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Отправлено в «%@».", "\(chat.title)"))
            case .continueAllClaude(let chats):
                Task { await ClaudeChatList.shared.continueAll(chats) }
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Продолжаю чаты по очереди: %@.", "\(chats.count)"))
            case .continueAfterReset(let opener):
                let text = await AgentActivity.continueAfterReset(opener)
                return LinkResult(cmd: cmd.id, code: "ok", text: text)
            case .restartAgent(let provider):
                let text = await AgentRestart.shared.restart(provider, whenFree: true, from: "iPhone")
                return LinkResult(cmd: cmd.id, code: "ok", text: text)
            case .guardExit(let choice, let key):
                // The card on the phone may be older than what waits now: then nothing is changed.
                guard RouteGuard.shared.answerExit(choice, key: key) else {
                    return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
                }
                return LinkResult(cmd: cmd.id, code: "ok", text: choice == .refuse ? L("Адрес запрещён.") : L("Адрес разрешён."))
            case .guardPause:
                RouteGuard.shared.pause(3600)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Защита выключена на час."))
            case .guardCheck:
                await RouteGuard.shared.checkNow()
                let held = !RouteGuard.shared.blocked.isEmpty || !Freezer.shared.frozen.isEmpty
                return LinkResult(cmd: cmd.id, code: "ok", text: held
                                  ? L("Маршрут всё ещё неправильный: агенты на паузе.") : L("Маршрут в порядке."))
            case .timeZoneSnooze(let seconds):
                RouteGuard.shared.snoozeTimeZone(seconds)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Напомню позже."))
            case .guardResume:
                RouteGuard.shared.pause(nil)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Защита снова включена."))
            case .installRelease:
                guard let release = GitHubUpdater.shared.available else {
                    return LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
                }
                Task { await GitHubUpdater.shared.install() }
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Обновляю Cooldown на Mac до %@…", release.version))
            default:
                return LinkResult(cmd: cmd.id, code: "unknown", text: L("Это действие доступно только на Mac."))
            }
        } catch {
            return LinkResult(cmd: cmd.id, code: "failed", text: error.localizedDescription)
        }
    }

    /// "Ответить": the text goes into the chat the card is about. Codex takes it through its own
    /// connection (works with the Mac locked); Claude needs the Mac unlocked, as it is typed in.
    func replyText(_ text: String, to opener: AgentActivity.Opener, cmd: LinkCommand, phone: String, key: String) async -> LinkResult {
        switch opener {
        case .codexThread(let id):
            do {
                try await AutoResume.shared.reply(id, text: text)
                ToastController.shared.dismiss(key: key)
                note(phone, L("ответ в Codex"), provider: .codex)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Отправлено в Codex."))
            } catch {
                return LinkResult(cmd: cmd.id, code: "failed", text: ResumeError.friendly(error))
            }
        case .claudeChat(let chat):
            if ToastController.screenLocked {
                afterUnlock.append((cmd, phone, Date()))
                return LinkResult(cmd: cmd.id, code: "locked", text: L("Mac заблокирован. Отправлю, как только его разблокируют."))
            }
            do {
                try await ClaudeSender.send(text, to: chat)
                ToastController.shared.dismiss(key: key)
                note(phone, L("ответ в «%@»", "\(chat.title)"), provider: .claude)
                return LinkResult(cmd: cmd.id, code: "ok", text: L("Отправлено в «%@».", "\(chat.title)"))
            } catch {
                return LinkResult(cmd: cmd.id, code: "failed", text: error.localizedDescription)
            }
        default:
            return LinkResult(cmd: cmd.id, code: "failed", text: L("Это действие доступно только на Mac."))
        }
    }

    func runAfterUnlock() {
        guard !afterUnlock.isEmpty, !ToastController.screenLocked else { return }
        let waiting = afterUnlock.filter { Date().timeIntervalSince($0.at) < $0.cmd.ttl }
        afterUnlock = []
        for (cmd, phone, _) in waiting {
            Task {
                let result: LinkResult
                if cmd.op == .watch {
                    result = await watch(cmd, from: phone)
                } else if cmd.args["action"] == "reply", let item = cards[cmd.args["key"] ?? ""], let opener = Self.chat(of: item.content) {
                    result = await replyText(cmd.args["text"] ?? "", to: opener, cmd: cmd, phone: phone, key: cmd.args["key"] ?? "")
                } else if let item = cards[cmd.args["key"] ?? ""],
                          let action = item.content.actions.first(where: { Self.actionID($0) == cmd.args["action"] }) {
                    result = await perform(action, key: cmd.args["key"] ?? "", cmd: cmd, phone: phone)
                } else {
                    result = LinkResult(cmd: cmd.id, code: "stale", text: L("Уже не актуально."))
                }
                reply(result, to: phone)
            }
        }
    }

    func chats(_ cmd: LinkCommand) async -> LinkResult {
        let model = AppModel.shared
        if cmd.args["provider"] == "claude" {
            let list = ClaudeChatList.shared
            list.refreshAvailable()
            for _ in 0..<30 where list.loadingAvailable { try? await Task.sleep(for: .milliseconds(500)) }
            let watched = Set(list.entries.map(\.id))
            var rows = list.entries.map { LinkChat(provider: "claude", id: $0.id, title: $0.chat.title, watched: true, updated: $0.chat.seen) }
            for known in list.available.prefix(60) {
                let id = known.chat.id.isEmpty ? known.chat.title : known.chat.id
                guard !watched.contains(id), !rows.contains(where: { $0.title == known.chat.title }) else { continue }
                rows.append(LinkChat(provider: "claude", id: id, title: known.chat.title, subtitle: known.project, updated: known.updated))
            }
            return LinkResult(cmd: cmd.id, code: "ok", text: "", chats: rows)
        }
        await model.loadThreads(force: true, maxAge: 30)
        if let error = model.threadsError, model.threads.isEmpty {
            return LinkResult(cmd: cmd.id, code: "failed", text: error)
        }
        let watches = Dictionary(model.watches.map { ($0.threadId, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = model.threads.filter { !$0.archived }.prefix(60).map { t in
            LinkChat(provider: "codex", id: t.id, title: t.title, subtitle: t.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                     state: watches[t.id]?.status, watched: watches[t.id]?.enabled ?? false, updated: t.updatedAt)
        }
        return LinkResult(cmd: cmd.id, code: "ok", text: "", chats: Array(rows))
    }

    func watch(_ cmd: LinkCommand, from phone: String) async -> LinkResult {
        let id = cmd.args["id"] ?? "", mode = cmd.args["mode"] ?? "reset", title = cmd.args["title"] ?? ""
        let ok = { (text: String) in LinkResult(cmd: cmd.id, code: "ok", text: text) }
        if cmd.args["provider"] == "claude" {
            let list = ClaudeChatList.shared
            let chat = ClaudeChat(id: id == title ? "" : id, title: title)
            switch mode {
            case "stop":
                for entry in list.entries where entry.id == id || entry.chat.title == title { list.remove(entry) }
                note(phone, L("не ждать «%@»", "\(title)"), provider: .claude)
                return ok(L("«%@» больше не ждёт сброса.", "\(title)"))
            case "now":
                if ToastController.screenLocked {
                    afterUnlock.append((cmd, phone, Date()))
                    return LinkResult(cmd: cmd.id, code: "locked", text: L("Mac заблокирован. Отправлю, как только его разблокируют."))
                }
                note(phone, L("продолжить «%@»", "\(title)"), provider: .claude)
                do {
                    try await ClaudeSender.continueChat(chat)
                    return ok(L("Отправлено в «%@».", "\(title)"))
                } catch {
                    return LinkResult(cmd: cmd.id, code: "failed", text: error.localizedDescription)
                }
            default:
                list.add(chat)
                note(phone, L("ждать сброса: «%@»", "\(title)"), provider: .claude)
                return ok(L("После сброса лимита придёт карточка «Продолжить» для «%@».", "\(title)"))
            }
        }
        let model = AppModel.shared
        do {
            switch mode {
            case "stop":
                try await model.stopTask(id)
                note(phone, L("не отслеживать «%@»", "\(title)"), provider: .codex)
                return ok(L("«%@» больше не отслеживается.", "\(title)"))
            default:
                try await model.startTask(id, maxResumes: Int(cmd.args["max"] ?? "") ?? 2)
                if mode == "now" { AutoResume.shared.poke(id, after: 0) }
                note(phone, L("отслеживать «%@»", "\(title)"), provider: .codex)
                return ok(mode == "now" ? L("Cooldown продолжит «%@», как только Codex сможет.", "\(title)")
                                        : L("«%@» продолжится сам после сброса лимита.", "\(title)"))
            }
        } catch {
            return LinkResult(cmd: cmd.id, code: "failed", text: ResumeError.friendly(error))
        }
    }
}
