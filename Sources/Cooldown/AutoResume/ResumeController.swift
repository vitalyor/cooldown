import Foundation

/// Watches one chosen Codex conversation and, once its turn failed on the usage limit and the
/// limit is really back, asks the app to start the next turn — once. A port of the controller
/// of codex-auto-resume with the same order of checks. `step()` answers whether to keep watching.
final class ResumeController {
    let threadId: String
    private let store: ResumeStore
    private let connect: () throws -> CodexIPCConnection
    private let readQuota: () throws -> [String: Any]
    private let openThread: (String) throws -> Bool
    var clock: () -> Double = { Date().timeIntervalSince1970 }

    /// When the limits are worth reading again (seconds since 1970); 0 = now.
    private(set) var nextQuotaCheck: Double = 0
    private var waitingBaseline: String?
    private var failures = 0
    private var nextOpen: Double = 0

    init(threadId: String, store: ResumeStore, connect: @escaping () throws -> CodexIPCConnection,
         readQuota: @escaping () throws -> [String: Any], openThread: @escaping (String) throws -> Bool) {
        self.threadId = threadId
        self.store = store
        self.connect = connect
        self.readQuota = readQuota
        self.openThread = openThread
    }

    private func keep(_ status: String, _ reason: String) -> Bool {
        store.update(threadId, status: status, reason: reason, onlyEnabled: true)
        return true
    }

    private func end(_ status: String, _ reason: String) -> Bool {
        store.update(threadId, status: status, reason: reason, disable: true, onlyEnabled: true)
        return false
    }

    func step() -> Bool {
        guard let watch = store.get(threadId), watch.enabled else { return false }
        if store.uncertain(threadId) {
            return end("uncertain", "Есть неподтверждённая отправка; проверьте в приложении, повторно автоматически не отправляется")
        }
        var stage = "app"
        do {
            let desktop = try connect()
            defer { desktop.close() }
            let state = try desktop.snapshot(threadId)
            let decision = ResumePolicy.decide(state)
            switch decision.action {
            case .stop:
                return end(decision.taskState == "needs_attention" ? "needs_attention" : "stopped", decision.reason)
            case .wait:
                failures = 0
                return keep(decision.taskState == "running" ? "watching" : "waiting_connection", decision.reason)
            case .resume:
                break
            }
            let baseline = try ResumePolicy.fingerprint(state)
            if let previous = store.attempt(threadId, turn: decision.turnId) {
                if previous.state == "sent" && clock() - previous.created.timeIntervalSince1970 < 120 {
                    return keep("watching", "Продолжение отправлено, ждём, когда приложение обновит статус")
                }
                return end("stopped", "В этом раунде продолжение уже отправлялось; повторно не отправляется")
            }
            if let waitingBaseline, waitingBaseline != baseline {
                return end("changed", "Пока шло ожидание, изменились задача или её настройки; решите заново, нужно ли автопродолжение")
            }
            waitingBaseline = baseline
            if store.count(threadId) >= watch.maxResumes {
                return end("budget", "Достигнут лимит автоматических продолжений для этой задачи")
            }
            if clock() < nextQuotaCheck {
                return keep("waiting_quota", "Ждём сброса лимита; пока следим, не остановлена ли задача")
            }
            stage = "quota"
            let quota = ResumePolicy.quotaStatus(try readQuota(), now: clock())
            failures = 0
            guard quota.ready else {
                guard let next = quota.nextCheck else { return end("blocked", quota.reason) }
                nextQuotaCheck = next
                return keep("waiting_quota", quota.reason)
            }
            // The intent is written down before anything is sent, with a pause and budget check.
            guard let messageId = store.claim(threadId, turn: decision.turnId, fingerprint: baseline) else {
                return end("stopped", "Наблюдение выключено, попытки закончились или для этого раунда уже есть запись об отправке")
            }
            do {
                guard store.get(threadId)?.enabled == true else {
                    return end("uncertain", "Отправка отменена; запись защиты от повторов сохранена")
                }
                let turn = decision.turnId
                let resumed = try desktop.resume(threadId, expected: baseline, messageId: messageId) { [store, threadId] in
                    store.canDispatch(threadId, turn: turn, messageId: messageId)
                }
                store.acknowledged(threadId, turn: turn, resumedTurn: resumed)
            } catch {
                return end("uncertain", "Продолжение не получило проверяемого подтверждения; проверьте в приложении, повторно отправляться не будет")
            }
            waitingBaseline = nil
            nextQuotaCheck = 0
            return keep("resumed", "Приложение подтвердило запуск следующего раунда; следим за результатом")
        } catch let error as CodexIPCError where error.isTransient {
            return disconnected(stage)
        } catch CodexError.timeout where stage == "quota" {
            return disconnected(stage)
        } catch {
            failures += 1
            if failures >= 3 {
                return end("blocked", "Три раза подряд не удалось безопасно прочитать приложение или лимиты; проверьте приложение Codex, вход и сеть")
            }
            return keep("retrying", "Пока не удаётся прочитать состояние; продолжение не отправляется, проверим ещё раз")
        }
    }

    /// The app or the limits are out of reach for now (closed app, sleep, network). The watch
    /// stays; saved history never authorizes a send. A conversation that lost its window gets
    /// re-opened in the background at most every 5 minutes, after a fresh eligibility check.
    private func disconnected(_ stage: String) -> Bool {
        if stage == "app", clock() >= nextOpen {
            nextOpen = clock() + 300
            if store.get(threadId)?.enabled == true, (try? openThread(threadId)) == false {
                return end("stopped", "Диалог завершён, в архиве или больше не подходит для автопродолжения; он не открывался, сообщения не отправлялись")
            }
        }
        if stage == "app" {
            return keep("waiting_connection", "Ждём подключения приложения Codex; пока оно не подключено и не проверено заново, сообщения не отправляются")
        }
        return keep("waiting_quota", "Ждём повторного чтения лимитов; продолжение по одному лишь времени не отправляется")
    }
}
