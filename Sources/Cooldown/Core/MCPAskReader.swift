import AppKit
import Foundation

/// The other half of MCP's `cooldown_ask`: reads the question file Claude's MCP process writes,
/// turns it into the same card as a hook request, and writes the pressed answer back. The MCP
/// process polls that small file, so no socket or port is involved.
@MainActor
final class MCPAskReader {
    static let shared = MCPAskReader()

    private var timer: Timer?
    private var held: [String: String] = [:]

    func start() {
        let folder = CooldownMCP.asksURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        scan()
        timer = Timer.every(1) { _ in
            Task { @MainActor in MCPAskReader.shared.scan() }
        }
    }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: CooldownMCP.asksURL.path)) ?? []
        let requests = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        let now = Date().timeIntervalSince1970
        // A question whose deadline passed while its card was up must not keep waiting for a
        // press: the MCP process has already returned "no answer".
        for token in Array(held.keys) where requests.contains(token) {
            let url = CooldownMCP.asksURL.appendingPathComponent(token + ".json")
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let expires = Num.double(object["expires"]), expires <= now else { continue }
            try? FileManager.default.removeItem(at: url)
            if let key = held.removeValue(forKey: token) { RequestCenter.shared.resolved(key) }
        }
        for token in requests where held[token] == nil {
            let url = CooldownMCP.asksURL.appendingPathComponent(token + ".json")
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let question = object["question"] as? String else { continue }
            let expires = Num.double(object["expires"]) ?? now
            if expires <= now {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let key = "mcp|" + token
            let options = (object["options"] as? [String] ?? []).map { String($0.prefix(160)) }
            let allowText = JSON.bool(object["allow_text"]) == true
            var choices = options.enumerated().map { index, label in
                RequestChoice(id: "option:\(index)", title: label)
            }
            if allowText {
                choices.append(RequestChoice(id: "input", title: L("Ответить"), role: .input))
            }
            let request = AgentRequest(key: key, provider: .claude, chat: L("Claude Desktop"),
                                       headline: L("Claude спрашивает"), detail: question, choices: choices,
                                       appBundleIDs: [], threadId: nil)
            held[token] = key
            RequestCenter.shared.post(request, open: { ClaudeApp.open() }, respond: { [weak self] choice in
                guard let self else { throw ResumeError.refused(L("Cooldown закрыт.")) }
                let answer: String
                if choice.id.hasPrefix("option:"), let index = Int(choice.id.dropFirst("option:".count)),
                   options.indices.contains(index) {
                    answer = options[index]
                } else if choice.id.hasPrefix("text:") {
                    answer = String(choice.id.dropFirst("text:".count))
                } else {
                    throw ResumeError.refused(L("Такой ответ здесь не поддерживается."))
                }
                try self.write(token: token, answer: answer)
            })
        }

        // Gone from disk: the MCP process timed out or the card was answered. Do not keep a card
        // for a request that can no longer receive an answer.
        for token in Array(held.keys) where !requests.contains(token) {
            if let key = held.removeValue(forKey: token) { RequestCenter.shared.resolved(key) }
        }
        // An answer file is read by the MCP process just after it appears. Keep it for a minute
        // before cleaning it up, or this scan could delete the answer before the other process
        // sees it.
        for name in names where name.hasSuffix(".res") {
            let token = String(name.dropLast(4))
            guard !requests.contains(token), held[token] == nil else { continue }
            let url = CooldownMCP.asksURL.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if modified.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func write(token: String, answer: String) throws {
        let object: [String: Any] = ["answer": answer, "by": "cooldown", "at": Date().timeIntervalSince1970]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let temporary = CooldownMCP.asksURL.appendingPathComponent(token + ".tmp")
        let response = CooldownMCP.asksURL.appendingPathComponent(token + ".res")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try? FileManager.default.removeItem(at: response)
        try FileManager.default.moveItem(at: temporary, to: response)
        try? FileManager.default.removeItem(at: CooldownMCP.asksURL.appendingPathComponent(token + ".json"))
        held.removeValue(forKey: token)
    }
}
