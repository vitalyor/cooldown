import SwiftUI

/// What a card can offer besides closing.
enum ToastAction: Equatable {
    /// The window on the limits of the card's agent.
    case openPanel
    /// The window on a given place, for the card's agent.
    case open(PanelPlace)
    case openSettings(SettingsPane)
    case openClaude
    case openCodex
    case openCodexThread(String)
    case continueClaude(demo: Bool)
    case continueClaudeChat(ClaudeChat)
    case openClaudeChat(ClaudeChat)
    case continueAllClaude([ClaudeChat])
    case openSchedule
    case installUpdate
    case installRelease
    case openReleasePage
    case openFeed
    case remindBeforeReset(ProviderID, Date)
    /// The chat the limit stopped: continue it after the reset (Codex by itself, Claude with a card).
    case continueAfterReset(AgentActivity.Opener)
    case openFile(URL)
    /// Quit and open the agent's app again — only when nothing is going on in it (AgentRestart).
    case restartAgent(ProviderID)
    /// A new exit for a service: allow it for good, for now, or refuse it (RouteGuard).
    case guardExit(GuardExitChoice, String)
    /// The VPN guard off for an hour.
    case guardPause
    /// Check the routes again now (from a card or the phone).
    case guardCheck
    /// Turn the guard back on before the hour is over.
    case guardResume
    /// Put the time zone card off for this many seconds.
    case timeZoneSnooze(TimeInterval)

    /// The agent's own app: where a chat or task about it can actually be looked at.
    static func app(_ provider: ProviderID) -> ToastAction { provider == .codex ? .openCodex : .openClaude }

    var title: String {
        switch self {
        case .open(let place): return place.tab == .tasks ? L("Открыть задачи") : L("Посмотреть")
        case .openSettings: return L("Открыть настройки")
        case .openFeed: return L("Посмотреть")
        case .remindBeforeReset: return L("Напомнить за 10 мин")
        case .continueAfterReset: return L("Продолжить после сброса")
        case .openFile: return L("Открыть отчёт")
        case .restartAgent(let provider): return L("Перезапустить %@", provider.displayName)
        case .guardExit(.remember, _): return L("Разрешить и запомнить")
        case .guardExit(.once, _): return L("Только сейчас")
        case .guardExit(.refuse, _): return L("Запретить")
        case .guardPause: return L("Выключить защиту на час")
        case .guardCheck: return L("Проверить сейчас")
        case .guardResume: return L("Включить снова")
        case .timeZoneSnooze(let seconds): return seconds < 2 * 3600 ? L("Отложить на час") : L("Отложить на день")
        case .openSchedule: return L("Отложить задачу")
        case .installUpdate: return L("Перезапустить")
        case .installRelease: return L("Обновить")
        case .openReleasePage: return L("Что нового")
        case .continueClaudeChat: return L("Продолжить")
        case .continueAllClaude(let chats): return L("Продолжить все (%@)", "\(chats.count)")
        case .openPanel: return L("Открыть Cooldown")
        case .openClaude, .openClaudeChat: return L("Открыть Claude")
        case .openCodex, .openCodexThread: return L("Открыть Codex")
        case .continueClaude: return L("Продолжить")
        }
    }
}

/// One card: the words, the buttons and how long it stays.
struct ToastContent: Equatable {
    enum Kind { case reset, finished, attention, warning, info, waiting }

    /// How long a card stays: by itself for a while, or until the person answers it.
    enum Life: Equatable {
        case auto(Double)
        case sticky
    }

    /// Cards with the same key replace each other instead of piling up.
    var key: String
    var kind: Kind
    var provider: ProviderID?
    var title: String
    var body: String
    var actions: [ToastAction] = []
    var life: Life = .auto(8)
    var threadId: String? = nil
    /// Request cards: the exact thing asked about, the answers, and which request they answer.
    var detail: String? = nil
    var choices: [RequestChoice] = []
    var requestKey: String? = nil
    /// A question of several: which one this card shows (an answer from the phone names it, so a
    /// late press never lands on the next question).
    var step: Int? = nil

    /// The app the news is about: while it is in front, the person already sees what happened.
    var appBundleIDs: [String] {
        switch provider {
        case .codex: return ["com.openai.codex"]
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .antigravity: return ["com.google.antigravity"]
        case nil: return []
        }
    }

    var tint: Color {
        switch kind {
        case .reset: return Theme.mint
        case .finished: return provider.map { Theme.tint(for: $0) } ?? Theme.cobalt
        case .attention: return Theme.amber
        case .warning: return Theme.signal
        case .waiting: return Theme.cobalt
        case .info: return Theme.cobalt
        }
    }

    var symbol: String {
        switch kind {
        case .reset: return "arrow.counterclockwise.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .attention: return "hand.raised.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .waiting: return "hourglass.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

