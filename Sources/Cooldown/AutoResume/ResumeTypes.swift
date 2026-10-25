import Foundation

/// A Codex conversation as the Tasks tab lists it.
struct CodexConversation: Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String?
    let updatedAt: Date?
    let archived: Bool

    init(id: String, title: String, cwd: String?, updatedAt: Date?, archived: Bool) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.archived = archived
    }

    /// The title is the conversation's name, or else the start of its first message.
    init(id: String, name: String?, preview: String?, cwd: String?, updatedAt: Date?, archived: Bool) {
        let text = [name, preview].lazy.compactMap { JSON.nonEmptyString($0) }.first
        self.init(id: id, title: text.map { String($0.prefix(120)) } ?? L("Без названия"),
                  cwd: cwd, updatedAt: updatedAt, archived: archived)
    }
}

/// One conversation under auto-continue, as the UI shows it.
struct ResumeWatch: Identifiable, Equatable {
    let threadId: String
    var enabled: Bool
    var maxResumes: Int
    /// One of the identifiers `TaskStatus.title` knows.
    var status: String
    /// One plain sentence for the person.
    var reason: String
    var updated: Date
    /// Continuations sent (or tried) for this conversation.
    var attempts: Int

    var id: String { threadId }
}

/// What auto-continue thinks of a conversation right now (read-only).
struct ResumeCheck: Equatable {
    let threadId: String
    let title: String?
    /// One of the task states `ResumeStatus.taskStateTitle` knows.
    let taskState: String
    let canMonitor: Bool
    let reason: String
    let model: String?
}

enum ResumeError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason): return reason
        }
    }

    /// A sentence fit for the window, whatever went wrong.
    static func friendly(_ error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription, !text.isEmpty { return text }
        return L("Не получилось: %@", "\(error.localizedDescription)")
    }
}

enum ResumeStatus {
    static func taskStateTitle(_ state: String) -> String {
        switch state {
        case "running": return L("Задача выполняется")
        case "quota_limited": return L("Остановлена лимитом")
        case "needs_attention": return L("Ждёт вашего решения")
        case "idle": return L("Задача завершена")
        case "empty": return L("В диалоге ещё нет задач")
        case "interrupted": return L("Задача прервана")
        case "other_failure": return L("Задача остановилась с ошибкой")
        case "unsupported": return L("Этот диалог не поддерживается")
        case "archived": return L("Диалог в архиве")
        case "connecting": return L("Диалог загружается")
        default: return L("Состояние неизвестно")
        }
    }

    /// Only work that is running or stopped by the limit is worth watching.
    static func canMonitor(_ state: String) -> Bool { state == "running" || state == "quota_limited" }
}
