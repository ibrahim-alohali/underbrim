//
//  RelayRequest.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A request the user answers from the notch: an approval, a question, a plan.
//  The answer carries only a choice; the helper builds the agent's reply from
//  the hook input it kept, so the app can't change what runs or save a rule the
//  agent didn't suggest. Never written to disk or logged.
//

import Foundation

struct RelayRequest: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case permission
        /// AskUserQuestion: one to four questions with options.
        case question
        /// ExitPlanMode: a plan to approve.
        case plan
    }

    enum Payload: Equatable, Sendable {
        /// A tool call, with the permission changes the agent offered.
        case permission(RelayAction, suggestions: [RelaySuggestion])
        case question(RelayQuestions)
        /// Never one with nothing to show, so a plan no one saw can't be approved.
        case plan(RelayPlan)
    }

    var id: String
    var tool: String?
    var mode: String?
    var subagent: Bool?
    var payload: Payload

    var kind: Kind {
        switch payload {
        case .permission: .permission
        case .question: .question
        case .plan: .plan
        }
    }
}

/// One to four questions.
struct RelayQuestions: Hashable, Sendable {
    let all: [RelayQuestion]

    init?(_ questions: [RelayQuestion]) {
        guard (1...4).contains(questions.count) else { return nil }
        all = questions
    }
}

/// A plan's text (and the file it's in, when the agent names one), or only its file.
enum RelayPlan: Equatable, Sendable {
    case text(String, file: String?)
    case file(String)

    init?(text: String?, file: String?) {
        if let text { self = .text(text, file: file) } else if let file { self = .file(file) } else { return nil }
    }

    var text: String? {
        if case .text(let text, _) = self { text } else { nil }
    }

    var file: String? {
        switch self {
        case .text(_, let file): file
        case .file(let file): file
        }
    }
}

/// The wire keeps the flat shape an app a version behind reads.
extension RelayRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, tool, mode, subagent, action, suggestions, questions, plan, planFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        subagent = try container.decodeIfPresent(Bool.self, forKey: .subagent)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .permission:
            payload = .permission(try container.decode(RelayAction.self, forKey: .action),
                                  suggestions: try container.decodeIfPresent([RelaySuggestion].self, forKey: .suggestions) ?? [])
        case .question:
            guard let questions = RelayQuestions(try container.decode([RelayQuestion].self, forKey: .questions)) else {
                throw DecodingError.dataCorruptedError(forKey: .questions, in: container, debugDescription: "one to four questions")
            }
            payload = .question(questions)
        case .plan:
            guard let plan = RelayPlan(text: try container.decodeIfPresent(String.self, forKey: .plan),
                                       file: try container.decodeIfPresent(String.self, forKey: .planFile)) else {
                throw DecodingError.dataCorruptedError(forKey: .plan, in: container, debugDescription: "a plan or its file")
            }
            payload = .plan(plan)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(subagent, forKey: .subagent)
        switch payload {
        case .permission(let action, let suggestions):
            try container.encode(action, forKey: .action)
            if !suggestions.isEmpty { try container.encode(suggestions, forKey: .suggestions) }
        case .question(let questions):
            try container.encode(questions.all, forKey: .questions)
        case .plan(let plan):
            try container.encodeIfPresent(plan.text, forKey: .plan)
            try container.encodeIfPresent(plan.file, forKey: .planFile)
        }
    }
}

struct RelayAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case command, edit, write, fetch, search, read, agent, mcp, other
    }

    var kind: Kind
    var summary: String?
    var target: String?
    var body: String?
    var diff: [RelayDiffLine]?
}

struct RelayDiffLine: Codable, Equatable, Sendable {
    var added: Bool
    var text: String
}

/// A permission change the agent offered ("always allow `npm test` here"). The
/// answer names it by `index`; the helper sends the agent's own entry back.
struct RelaySuggestion: Codable, Equatable, Sendable {
    var index: Int
    /// "addRules", "setMode", "addDirectories", …
    var type: String
    var behavior: String?
    /// "session", "localSettings", "projectSettings", "userSettings".
    var destination: String?
    /// Rules as the agent writes them: "Bash(npm test:*)", "WebFetch".
    var rules: [String]?
    var mode: String?
    var directories: [String]?
}

/// Its text and options are cleaned for showing; an answer names them by `sourceIndex`, their place in
/// the agent's own list, and the helper sends the agent's own words back.
struct RelayQuestion: Codable, Hashable, Sendable {
    var sourceIndex: Int
    var question: String
    var header: String?
    var options: [RelayOption]
    var multiSelect: Bool
}

struct RelayOption: Codable, Hashable, Sendable {
    var sourceIndex: Int
    var label: String
    var description: String?
}

/// One question's answer: the options chosen and what was typed, by their places in the agent's list.
struct RelayChoice: Codable, Equatable, Sendable {
    var question: Int
    var options: [Int]
    var text: String?
}

struct RelayAnswer: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Sendable {
        /// Approve; with `suggestion`, also apply that offered change; for a
        /// plan, `mode` says which mode the session continues in.
        case allow
        /// Refuse, with an optional `message` the agent reads.
        case deny
        /// Answers to a question, in `choices`.
        case answer
    }

    var id: String
    var decision: Decision
    var suggestion: Int?
    var message: String?
    var choices: [RelayChoice]?
    /// An app a version behind answers by question text instead (text → answer), while a hook
    /// started by this version's helper waits across an update.
    var answers: [String: String]?
    var mode: String?
}

extension Relay {
    /// Text as written, line breaks and tabs included, without other control or bidi-override
    /// characters; cut to `maxBytes` of UTF-8 at a character boundary, with "…".
    static func text(_ value: Any?, maxBytes: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let kept = raw.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" { return true }
            return scalar.properties.generalCategory != .control && !bidiControls.contains(scalar)
        }
        var cleaned = String(String.UnicodeScalarView(kept))
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if cleaned.utf8.count > maxBytes {
            var cut = cleaned.startIndex
            var bytes = 0
            for index in cleaned.indices {
                let size = cleaned[index].utf8.count
                if bytes + size > maxBytes - 3 { break }
                bytes += size
                cut = cleaned.index(after: index)
            }
            cleaned = String(cleaned[..<cut]) + "…"
        }
        return cleaned
    }
}

// MARK: - Helper side: hook input → request, answer → hook output

enum RelayRequestBuilder {
    static let maxCommandBytes = 4096
    static let maxPlanBytes = 32 * 1024
    static let maxDiffLines = 40
    static let maxAnswerBytes = 2048
    static let maxMessageBytes = 1024

    static func claudeRequest(id: String, input object: [String: Any]) -> RelayRequest? {
        guard object["hook_event_name"] as? String == "PermissionRequest",
              let tool = Relay.identifier(object["tool_name"], maxLength: 96)
        else { return nil }
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        let payload: RelayRequest.Payload
        switch tool {
        case "AskUserQuestion":
            guard let questions = questions(in: toolInput) else { return nil }
            payload = .question(questions)
        case "ExitPlanMode":
            // Nothing to show (the field moved, say): Claude's own prompt asks instead.
            guard let plan = RelayPlan(text: Relay.text(toolInput["plan"], maxBytes: maxPlanBytes),
                                       file: Relay.path(toolInput["planFilePath"])) else { return nil }
            payload = .plan(plan)
        default:
            let suggestions = (object["permission_suggestions"] as? [[String: Any]] ?? [])
                .prefix(8).enumerated().compactMap { suggestion($0.element, index: $0.offset) }
            payload = .permission(action(tool: tool, input: toolInput), suggestions: suggestions)
        }
        return RelayRequest(id: id, tool: tool, mode: Relay.identifier(object["permission_mode"], maxLength: 32),
                            subagent: object["agent_id"] is String ? true : nil, payload: payload)
    }

    /// Codex's PermissionRequest hook input → a request. Codex asks only about
    /// tool calls (a command, a patch, an MCP tool); it takes no saved rules.
    static func codexRequest(id: String, input object: [String: Any]) -> RelayRequest? {
        guard object["hook_event_name"] as? String == "PermissionRequest",
              let tool = Relay.identifier(object["tool_name"], maxLength: 96)
        else { return nil }
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        return RelayRequest(id: id, tool: tool, mode: Relay.identifier(object["permission_mode"], maxLength: 32),
                            payload: .permission(action(tool: tool, input: toolInput), suggestions: []))
    }

    /// AskUserQuestion's input as the notch shows it. The app reads the same call from Claude Code's
    /// transcript, so both name the same questions and options.
    static func questions(in toolInput: [String: Any]) -> RelayQuestions? {
        let asked = (toolInput["questions"] as? [[String: Any]] ?? []).prefix(4).enumerated()
            .compactMap { question($0.element, index: $0.offset) }
        return RelayQuestions(asked)
    }

    private static func question(_ object: [String: Any], index: Int) -> RelayQuestion? {
        guard let text = Relay.text(object["question"], maxBytes: 1024) else { return nil }
        let options = (object["options"] as? [[String: Any]] ?? []).prefix(6).enumerated().compactMap { offset, option -> RelayOption? in
            guard let label = Relay.label(option["label"], maxLength: 120) else { return nil }
            return RelayOption(sourceIndex: offset, label: label, description: Relay.label(option["description"], maxLength: 300))
        }
        return RelayQuestion(sourceIndex: index, question: text, header: Relay.label(object["header"], maxLength: 40),
                             options: options, multiSelect: object["multiSelect"] as? Bool == true)
    }

    private static func suggestion(_ object: [String: Any], index: Int) -> RelaySuggestion? {
        guard let type = Relay.identifier(object["type"], maxLength: 32) else { return nil }
        let rules = (object["rules"] as? [[String: Any]])?.prefix(6).compactMap { rule -> String? in
            guard let name = Relay.label(rule["toolName"], maxLength: 96) else { return nil }
            guard let content = Relay.label(rule["ruleContent"], maxLength: 300) else { return name }
            return "\(name)(\(content))"
        }
        let directories = (object["directories"] as? [Any])?.prefix(6).compactMap { Relay.path($0) }
        return RelaySuggestion(
            index: index, type: type,
            behavior: Relay.identifier(object["behavior"], maxLength: 16),
            destination: Relay.identifier(object["destination"], maxLength: 32),
            rules: rules, mode: Relay.identifier(object["mode"], maxLength: 32),
            directories: directories
        )
    }

    /// The parts of a tool call worth showing before it runs, by Claude Code's, Codex's and
    /// Qwen Code's tool names (Qoder uses Claude Code's).
    static func action(tool: String, input: [String: Any]) -> RelayAction {
        let summary = Relay.label(input["description"], maxLength: 200)
        switch tool {
        case "Bash", "PowerShell", "shell", "exec_command", "local_shell", "run_shell_command":
            // Codex sends its command as an argument list.
            var command = input["command"] ?? input["cmd"]
            if let parts = command as? [String] { command = parts.joined(separator: " ") }
            return RelayAction(kind: .command, summary: summary, body: Relay.text(command, maxBytes: maxCommandBytes))
        case "apply_patch":
            // Codex's patch format: "*** Update File: path", then "-" and "+" lines.
            let patch = (input["command"] as? String) ?? (input["patch"] as? String) ?? ""
            let lines = patch.components(separatedBy: "\n")
            let header = lines.first { $0.hasPrefix("*** Update File: ") || $0.hasPrefix("*** Add File: ") || $0.hasPrefix("*** Delete File: ") }
            let file = header.flatMap { $0.split(separator: ":", maxSplits: 1).last }.map { $0.trimmingCharacters(in: .whitespaces) }
            let changed = lines.filter { ($0.hasPrefix("+") || $0.hasPrefix("-")) && !$0.hasPrefix("***") }.prefix(maxDiffLines)
            let diff = changed.map { RelayDiffLine(added: $0.hasPrefix("+"), text: Relay.text(String($0.dropFirst()), maxBytes: 400)?.replacingOccurrences(of: "\n", with: " ") ?? "") }
            let files = lines.filter { $0.hasPrefix("*** ") && $0.contains(" File: ") }.count
            return RelayAction(kind: header?.hasPrefix("*** Add") == true ? .write : .edit,
                               summary: summary ?? (files > 1 ? "\(files) files" : nil),
                               target: file.flatMap { Relay.path($0) ?? Relay.label($0, maxLength: 300) },
                               diff: diff.isEmpty ? nil : Array(diff))
        case "Edit", "MultiEdit", "edit", "replace":
            var pairs: [(String?, String?)] = [(input["old_string"] as? String, input["new_string"] as? String)]
            if let edits = input["edits"] as? [[String: Any]] {
                pairs = edits.map { ($0["old_string"] as? String, $0["new_string"] as? String) }
            }
            return RelayAction(kind: .edit, summary: summary, target: Relay.path(input["file_path"]), diff: diff(pairs))
        case "Write", "write_file":
            let lines = (input["content"] as? String).map { [(nil as String?, $0 as String?)] } ?? []
            return RelayAction(kind: .write, summary: summary, target: Relay.path(input["file_path"]), diff: diff(lines))
        case "NotebookEdit":
            return RelayAction(kind: .edit, summary: summary, target: Relay.path(input["notebook_path"]),
                               diff: diff([(nil, input["new_source"] as? String)]))
        case "WebFetch", "web_fetch":
            return RelayAction(kind: .fetch, summary: summary, target: Relay.label(input["url"], maxLength: 600))
        case "WebSearch", "web_search", "google_web_search":
            return RelayAction(kind: .search, summary: summary, target: Relay.label(input["query"], maxLength: 300))
        case "Read", "Glob", "Grep", "LS", "read_file", "read_many_files", "glob", "grep_search", "list_directory":
            let target = Relay.path(input["file_path"]) ?? Relay.path(input["absolute_path"]) ?? Relay.path(input["path"])
                ?? Relay.label(input["pattern"], maxLength: 300)
            return RelayAction(kind: .read, summary: summary, target: target)
        case "Task", "Agent":
            return RelayAction(kind: .agent, summary: summary ?? Relay.label(input["subagent_type"], maxLength: 80),
                               body: Relay.text(input["prompt"], maxBytes: 600))
        default:
            let isMCP = tool.hasPrefix("mcp__")
            let parts = tool.components(separatedBy: "__")
            let server = isMCP && parts.count > 2 ? Relay.label(parts[1], maxLength: 60) : nil
            return RelayAction(kind: isMCP ? .mcp : .other, summary: summary, target: server, body: compactJSON(input))
        }
    }

    /// Old lines as removed, new ones as added, the lines both share at the
    /// start and end left out; at most `maxDiffLines` in all.
    static func diff(_ pairs: [(String?, String?)]) -> [RelayDiffLine]? {
        var lines: [RelayDiffLine] = []
        for (before, after) in pairs where lines.count < maxDiffLines {
            var old = before.map { $0.components(separatedBy: "\n") } ?? []
            var new = after.map { $0.components(separatedBy: "\n") } ?? []
            while let a = old.first, let b = new.first, a == b { old.removeFirst(); new.removeFirst() }
            while let a = old.last, let b = new.last, a == b { old.removeLast(); new.removeLast() }
            for line in old { lines.append(RelayDiffLine(added: false, text: line)) }
            for line in new { lines.append(RelayDiffLine(added: true, text: line)) }
        }
        let shown = lines.prefix(maxDiffLines).map { line in
            RelayDiffLine(added: line.added, text: Relay.text(line.text, maxBytes: 400)?.replacingOccurrences(of: "\n", with: " ") ?? "")
        }
        return shown.isEmpty ? nil : Array(shown)
    }

    private static func compactJSON(_ input: [String: Any]) -> String? {
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Relay.text(text, maxBytes: 1500)
    }

    /// → Codex's hook output; nil means no decision (Codex asks as usual).
    static func codexOutput(for answer: RelayAnswer, request: RelayRequest) -> Data? {
        guard answer.id == request.id, case .permission = request.payload, answer.suggestion == nil else { return nil }
        var decision: [String: Any]
        switch answer.decision {
        case .allow: decision = ["behavior": "allow"]
        case .deny:
            decision = ["behavior": "deny"]
            if let message = Relay.text(answer.message, maxBytes: maxMessageBytes) { decision["message"] = message }
        case .answer: return nil
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes])
    }

    static let planModes: Set<String> = ["default", "acceptEdits"]

    /// → Claude Code's hook output, from the kept input; nil means print nothing.
    static func claudeOutput(for answer: RelayAnswer, request: RelayRequest, input object: [String: Any]) -> Data? {
        guard answer.id == request.id else { return nil }
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        var decision: [String: Any]
        switch (answer.decision, request.payload) {
        case (.deny, _):
            decision = ["behavior": "deny"]
            if let message = Relay.text(answer.message, maxBytes: maxMessageBytes) { decision["message"] = message }
        case (.allow, .permission(_, let suggestions)):
            decision = ["behavior": "allow"]
            let offered = object["permission_suggestions"] as? [Any] ?? []
            if let index = answer.suggestion {
                guard offered.indices.contains(index), suggestions.contains(where: { $0.index == index })
                else { return nil }
                decision["updatedPermissions"] = [offered[index]]
            }
        case (.allow, .plan):
            // The plan tool needs its input back to run without Claude's prompt.
            decision = ["behavior": "allow", "updatedInput": toolInput]
            let mode = answer.mode ?? "default"
            guard planModes.contains(mode) else { return nil }
            decision["updatedPermissions"] = [["type": "setMode", "mode": mode, "destination": "session"]]
        case (.answer, .question(let shown)):
            let asked = toolInput["questions"] as? [[String: Any]] ?? []
            let answers = answer.choices.map { answersByPlace($0, shown: shown, asked: asked) }
                ?? answersByText(answer.answers ?? [:], asked: asked)
            guard !answers.isEmpty else { return nil }
            var updated = toolInput
            updated["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": updated]
        default:
            return nil
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes])
    }

    /// Claude Code's answers (question text → answer) in its own words: each question and chosen
    /// option, among those the card showed, by its place in the kept input; what was typed after
    /// them. Options several are joined with ", ".
    private static func answersByPlace(_ choices: [RelayChoice], shown: RelayQuestions, asked: [[String: Any]]) -> [String: String] {
        var answers: [String: String] = [:]
        for choice in choices {
            guard let question = shown.all.first(where: { $0.sourceIndex == choice.question }),
                  asked.indices.contains(choice.question), let text = asked[choice.question]["question"] as? String
            else { continue }
            let options = asked[choice.question]["options"] as? [[String: Any]] ?? []
            var parts = Set(choice.options).sorted().compactMap { index -> String? in
                guard question.options.contains(where: { $0.sourceIndex == index }), options.indices.contains(index) else { return nil }
                return options[index]["label"] as? String
            }
            if let typed = Relay.text(choice.text, maxBytes: maxAnswerBytes) { parts.append(typed) }
            if !parts.isEmpty { answers[text] = parts.joined(separator: ", ") }
        }
        return answers
    }

    /// An app a version behind keys its answers by the question's text as the card showed it.
    private static func answersByText(_ given: [String: String], asked: [[String: Any]]) -> [String: String] {
        let texts = Set(asked.compactMap { $0["question"] as? String })
        var answers: [String: String] = [:]
        for (question, text) in given where texts.contains(question) {
            if let text = Relay.text(text, maxBytes: maxAnswerBytes) { answers[question] = text }
        }
        return answers
    }
}
