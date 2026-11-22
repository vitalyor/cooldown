import SwiftUI

/// The catalogue of cards Cooldown shows, in one place so the wording and behaviour stay consistent.
@MainActor
enum ToastCatalog {
    static func limitLow(_ provider: ProviderID, remaining: Double, reset: Date) -> ToastContent {
        let critical = remaining <= 5
        // Almost out while a chat is at work: offer to continue it after the reset, so it doesn't
        // just stop halfway.
        if critical, let (opener, title) = AgentActivity.shared.unwatchedWorking(provider) {
            return ToastContent(key: "low-\(provider.rawValue)", kind: .warning, provider: provider,
                                title: L("%@ скоро упрётся в лимит", "\(provider.displayName)"),
                                body: L("Осталось %@. «%@» остановится на полпути — сброс в %@.", "\(Format.percent(remaining))", "\(title)", "\(Format.time(reset))"),
                                actions: [.continueAfterReset(opener)], life: .sticky)
        }
        return ToastContent(key: "low-\(provider.rawValue)", kind: critical ? .warning : .attention, provider: provider,
                            title: L("%@: осталось %@", "\(provider.displayName)", "\(Format.percent(remaining))"),
                            body: critical ? L("Лимит на 5 часов почти кончился. Сброс в %@.", "\(Format.time(reset))")
                                           : L("Лимит на 5 часов заканчивается. Сброс в %@.", "\(Format.time(reset))"),
                            actions: [.openPanel], life: .auto(critical ? 14 : 9))
    }

    /// The limit is spent: when work can go on, with a reminder and (Codex) a task for that moment.
    static func limitOut(_ provider: ProviderID, reset: Date) -> ToastContent {
        var actions: [ToastAction] = []
        if ResetReminder.possible(before: reset) { actions.append(.remindBeforeReset(provider, reset)) }
        if provider == .codex { actions.append(.openSchedule) }
        return ToastContent(key: "out-\(provider.rawValue)", kind: .warning, provider: provider,
                            title: L("Лимит %@ исчерпан", "\(provider.displayName)"),
                            body: Calendar.current.isDateInToday(reset)
                                ? L("Снова можно работать в %@ — через %@.", "\(Format.clock(reset))", "\(Format.duration(max(60, reset.timeIntervalSinceNow)))")
                                : L("Снова можно работать: %@ (через %@).", "\(Format.time(reset))", "\(Format.duration(max(60, reset.timeIntervalSinceNow)))"),
                            actions: actions.isEmpty ? [.openPanel] : actions, life: .sticky)
    }

    static func limitReset(_ provider: ProviderID, demo: Bool = false) -> ToastContent {
        if provider == .claude {
            // Needs the person: Cooldown never writes into a Claude chat on its own.
            // The chat named on the card is the one the button continues, whenever it is pressed.
            let chat = demo ? nil : ClaudeSender.pendingChat
            let target = chat.map { L("в чат «%@»", "\($0.title)") } ?? L("в открытый чат Claude, если он остановлен лимитом")
            return ToastContent(key: "reset-claude", kind: .reset, provider: .claude, title: L("Лимит Claude восстановился"),
                                body: L("Можно продолжать. «Продолжить» отправит «%@» %@.", "\(ClaudeSender.text)", "\(target)"),
                                actions: [chat.map { .continueClaudeChat($0) } ?? .continueClaude(demo: demo), .openClaude], life: .sticky)
        }
        if provider == .antigravity {
            return ToastContent(key: "reset-antigravity", kind: .reset, provider: .antigravity, title: L("Лимит %@ восстановлен", "Antigravity"),
                                body: L("Окно на 5 часов сбросилось, можно продолжать работу."), actions: [.openPanel], life: .auto(9))
        }
        return ToastContent(key: "reset-codex", kind: .reset, provider: .codex, title: L("Лимит Codex восстановился"),
                            body: L("Окно на 5 часов сбросилось, можно работать дальше."), actions: [.openPanel], life: .auto(9))
    }

    static func taskWaiting(_ provider: ProviderID, title: String, until: Date?) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .waiting, provider: provider, title: L("«%@» ждёт сброса", "\(title)"),
                     body: until.map { L("Лимит кончился. Cooldown продолжит задачу сам в %@.", "\(Format.time($0))") }
                        ?? L("Лимит кончился. Cooldown продолжит задачу сам сразу после сброса."),
                     actions: [.open(.tasks)], life: .auto(9))
    }

    static func taskResumed(_ provider: ProviderID, title: String) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .reset, provider: provider, title: L("«%@» продолжена", "\(title)"),
                     body: L("Лимит восстановился, Cooldown отправил «продолжай». Задача снова работает."),
                     actions: [.app(provider)], life: .auto(9))
    }

    static func taskFinished(_ provider: ProviderID, title: String, detail: String, threadId: String? = nil) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .finished, provider: provider, title: L("%@ закончил «%@»", "\(provider.displayName)", "\(title)"),
                     body: detail.isEmpty ? L("Задача завершена, можно посмотреть результат.") : detail,
                     actions: [threadId.map { .openCodexThread($0) } ?? .app(provider)],
                     life: .auto(12), threadId: threadId)
    }

    static func taskAttention(_ provider: ProviderID, title: String, reason: String) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .attention, provider: provider, title: L("«%@» ждёт вашего решения", "\(title)"),
                     body: reason.isEmpty ? L("Автопродолжение остановилось, нужно ваше участие.") : reason,
                     actions: [.app(provider)], life: .sticky)
    }

    static func taskBudget(_ provider: ProviderID, title: String) -> ToastContent {
        ToastContent(key: "task-\(title)", kind: .warning, provider: provider, title: L("«%@»: попытки закончились", "\(title)"),
                     body: L("Задача несколько раз упиралась в лимит. Автопродолжение остановлено, загляните в диалог."),
                     actions: [.app(provider)], life: .sticky)
    }

    /// A chat stopped because the limit ran out. Same key as limitOut: it takes that card's place.
    static func limitStopped(_ provider: ProviderID, name: String, reset: Date?, opener: AgentActivity.Opener = .none) -> ToastContent {
        var actions: [ToastAction] = []
        if AgentActivity.canContinueAfterReset(opener) { actions.append(.continueAfterReset(opener)) }
        if let reset, ResetReminder.possible(before: reset) { actions.append(.remindBeforeReset(provider, reset)) }
        if provider == .codex { actions.append(.openSchedule) }
        let when = reset.map { reset in
            Calendar.current.isDateInToday(reset)
                ? L("Снова можно работать в %@ — через %@.", "\(Format.clock(reset))", "\(Format.duration(max(60, reset.timeIntervalSinceNow)))")
                : L("Снова можно работать: %@ (через %@).", "\(Format.time(reset))", "\(Format.duration(max(60, reset.timeIntervalSinceNow)))")
        } ?? L("Снова можно работать после сброса лимита.")
        // A reset further away than a five-hour window can be: the week is spent.
        let weekly = reset.map { $0.timeIntervalSinceNow > 5.5 * 3600 } ?? false
        let next = provider == .claude ? L("После сброса придёт карточка «Продолжить».")
                                       : (AppModel.shared.watches.contains(where: \.enabled) ? L("Отслеживаемые задачи Cooldown продолжит сам.") : "")
        return ToastContent(key: "out-\(provider.rawValue)", kind: .warning, provider: provider,
                            title: L("%@ упёрся в лимит", "\(provider.displayName)"),
                            body: (weekly ? L("«%@» остановлен: недельный лимит исчерпан. %@", "\(name)", "\(when)")
                                          : L("«%@» остановлен: лимит на 5 часов исчерпан. %@", "\(name)", "\(when)")) + (next.isEmpty ? "" : " " + next),
                            actions: actions.isEmpty ? [.openPanel] : actions, life: .sticky)
    }

    static func failure(_ title: String, _ body: String, provider: ProviderID? = nil, retry: [ToastAction] = []) -> ToastContent {
        ToastContent(key: "fail-\(title)", kind: .warning, provider: provider, title: title, body: body, actions: retry, life: .sticky)
    }
}

