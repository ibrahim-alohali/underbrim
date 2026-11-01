//
//  CodexRollout.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Codex's per-thread log, ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl,
//  written for app threads too: turn starts, tool calls and outputs, turn ends. Approvals
//  aren't in it (hence the optional hook). It holds the conversation, so only record types,
//  timestamps, tool names, folder and origin are read, plus the card's fields; nothing is
//  kept beyond the card, logged or sent. Internal format: unknown records are skipped.
//  Thread names come from ~/.codex/session_index.jsonl, not the log.
//

import Foundation

extension AgentFiles {
    static func codexSessions(home: URL) -> URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }
    static func codexIndex(home: URL) -> URL { home.appendingPathComponent(".codex/session_index.jsonl") }
}

enum CodexRollout {
    struct Meta: Equatable {
        var cwd: String?
        var attended = true
        var date: Date?
    }

    enum Entry: Equatable {
        case meta(Meta)
        /// In the hooks' vocabulary.
        case event(AgentEvent.Kind, date: Date?)
        case note(Note)
    }

    enum Note: Equatable {
        /// What the tool call starting on the same line works on.
        case target(String)
        case tasks(AgentTaskChange)
        case prompt(String)
        /// The start of text Codex wrote, and of its final reply.
        case text(String)
        case reply(String)
        /// The folder a turn runs in, when Codex says it again (it can change between turns).
        case folder(String)
    }

    /// "rollout-2026-10-06T02-19-13-<thread id>.jsonl" → the thread id.
    static func threadID(fileName: String) -> String? {
        guard fileName.hasPrefix("rollout-"), fileName.hasSuffix(".jsonl") else { return nil }
        let id = String(fileName.dropLast(6).suffix(36))
        return UUID(uuidString: id) != nil ? id : nil
    }

    /// Thread names by thread id, from ~/.codex/session_index.jsonl: Codex adds
    /// a line when it names a thread (a few seconds in) and when you rename one.
    static func threadNames(in data: Data) -> [String: String] {
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = Relay.identifier(object["id"], maxLength: 64)
            else { continue }
            names[id] = Relay.label(object["thread_name"])
        }
        return names
    }

    /// The line's state change (or its session record), without the card's notes.
    static func entry(in line: Data) -> Entry? {
        entries(in: line).first { if case .note = $0 { false } else { true } }
    }

    static func entries(in line: Data) -> [Entry] { lineEntries(in: line).entries }

    /// The line's time, and what it says.
    static func lineEntries(in line: Data) -> (date: Date?, entries: [Entry]) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any]
        else { return (nil, []) }
        let date = isoDate(object["timestamp"])
        return (date, entries(object["type"] as? String, payload, date: date))
    }

    private static func entries(_ type: String?, _ payload: [String: Any], date: Date?) -> [Entry] {
        func event(_ kind: AgentEvent.Kind) -> Entry { .event(kind, date: date) }
        switch (type, payload["type"] as? String) {
        case ("session_meta"?, _):
            // `codex exec`, MCP and sub-agent threads (whose source isn't a plain string) aren't attended.
            let source = payload["source"]
            let attended = source == nil || (source as? String).map { $0 != "exec" && $0 != "mcp" } == true
            return [.meta(Meta(cwd: Relay.path(payload["cwd"]), attended: attended, date: isoDate(payload["timestamp"]) ?? date))]
        case ("turn_context"?, _):
            return Relay.path(payload["cwd"]).map { [.note(.folder($0))] } ?? []
        case ("event_msg"?, "task_started"?):
            return [event(.userPromptSubmit)]
        case ("event_msg"?, "task_complete"?):
            let reply = AgentToolInput.excerpt(payload["last_agent_message"], max: AgentToolInput.maxReply)
            return (reply.map { [.note(.reply($0))] } ?? []) + [event(.stop)]
        case ("event_msg"?, "turn_aborted"?):
            return [event(.interrupt)]
        case ("event_msg"?, "user_message"?):
            return AgentToolInput.excerpt(payload["message"], max: AgentToolInput.maxPrompt).map { [.note(.prompt($0))] } ?? []
        case ("event_msg"?, "agent_message"?):
            return AgentToolInput.excerpt(payload["message"], max: AgentToolInput.maxReply).map { [.note(.text($0))] } ?? []
        case ("event_msg"?, "item_completed"?):
            // Newer Codex writes the prompt and its own text as finished items instead.
            guard let item = payload["item"] as? [String: Any] else { return [] }
            let text = (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
            switch item["type"] as? String {
            case "UserMessage"?: return AgentToolInput.excerpt(text, max: AgentToolInput.maxPrompt).map { [.note(.prompt($0))] } ?? []
            case "AgentMessage"?: return AgentToolInput.excerpt(text, max: AgentToolInput.maxReply).map { [.note(.text($0))] } ?? []
            default: return []
            }
        case ("response_item"?, "function_call"?), ("response_item"?, "custom_tool_call"?), ("response_item"?, "local_shell_call"?):
            var tool = Relay.identifier(payload["name"], maxLength: 96) ?? "shell"
            // Code mode: a script calls Codex's tools (`tools.exec_command({cmd: "npm test"})`), named after the first.
            if tool == "exec", let script = payload["input"] as? String, let inner = AgentToolInput.codeModeTool(in: script) {
                tool = inner
            }
            if tool == "request_user_input" { return [event(.notification(.agentNeedsInput))] }
            let arguments = (payload["arguments"] as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? (payload["action"] as? [String: Any])
            // Its plan changes the card's task list; it isn't shown as work.
            if tool == "update_plan" {
                return arguments.flatMap(AgentToolInput.codexTasks).map { [.note(.tasks($0))] } ?? []
            }
            let target = AgentToolInput.codexTarget(tool: tool, arguments: arguments, input: payload["input"] as? String)
            return [event(.preToolUse(tool: tool))] + (target.map { [.note(.target($0))] } ?? [])
        case ("response_item"?, "function_call_output"?), ("response_item"?, "custom_tool_call_output"?):
            return [event(.postToolUse(tool: nil))]
        default:
            return []
        }
    }
}
