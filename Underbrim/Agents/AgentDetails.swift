//
//  AgentDetails.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What a session card says beyond its state, from the same session files: the running
//  tool's target, the task list, the start of the prompt and reply, the questions Claude
//  waits on. Bounded, in memory only, never logged or sent; Settings can turn it off.
//

import Foundation

struct AgentTask: Equatable, Sendable {
    enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    var title: String
    /// The same step while it runs ("Running the tests"), when the agent gives one.
    var active: String?
    var status: Status
    /// Claude Code's task id, for its updates.
    var id: String?
}

enum AgentTaskChange: Equatable, Sendable {
    /// The whole list (Claude's TodoWrite, Codex's update_plan, the Claude app's plan).
    case replace([AgentTask])
    /// Claude Code's TaskCreate: one more step, numbered in order.
    case add(AgentTask)
    /// Claude Code's TaskUpdate.
    case update(id: String, status: AgentTask.Status?, title: String?, active: String?)
    /// Claude Code's TaskUpdate to "deleted".
    case delete(id: String)
    /// The Claude app's plan: the running step is done, the next one starts.
    case advance
    /// The Claude app's plan: these steps (1-based) are done, that one starts.
    case mark(done: [Int], start: Int?)
    /// The Claude app's wrap-up checks the whole list.
    case finishAll
}

extension [AgentTask] {
    mutating func apply(_ change: AgentTaskChange) {
        switch change {
        case .replace(let tasks):
            self = tasks
        case .add(var task):
            // Claude Code numbers a list's tasks from 1.
            task.id = task.id ?? String((compactMap { $0.id.flatMap(Int.init) }.max() ?? 0) + 1)
            append(task)
        case .update(let id, let status, let title, let active):
            guard let index = firstIndex(where: { $0.id == id }) else { return }
            if let status { self[index].status = status }
            if let title { self[index].title = title }
            if let active { self[index].active = active }
        case .delete(let id):
            if let index = firstIndex(where: { $0.id == id }) { remove(at: index) }
        case .advance:
            if let running = firstIndex(where: { $0.status == .inProgress }) {
                self[running].status = .completed
                if let next = self[running...].firstIndex(where: { $0.status == .pending }) { self[next].status = .inProgress }
            } else if let next = firstIndex(where: { $0.status == .pending }) {
                self[next].status = .inProgress
            }
        case .mark(let done, let start):
            for step in done where indices.contains(step - 1) { self[step - 1].status = .completed }
            if let start, indices.contains(start - 1) {
                for index in indices where self[index].status == .inProgress { self[index].status = .completed }
                self[start - 1].status = .inProgress
            }
        case .finishAll:
            for index in indices { self[index].status = .completed }
        }
    }

    var doneCount: Int { filter { $0.status == .completed }.count }
    var currentStep: String? {
        first { $0.status == .inProgress }.map { $0.active ?? $0.title }
    }
}

struct AgentDetails: Equatable, Sendable {
    var target: String?
    var tasks: [AgentTask] = []
    var subagents = 0
    /// The start of the last prompt and, once the turn ends, of the reply.
    var prompt: String?
    var reply: String?
    /// The question the Claude app asks under the reply, until the next turn.
    var nextStep: AgentNextStep?
    /// The Claude app's offer to start a task in a session of its own, while its card waits.
    var offer: AgentOffer?
    /// Questions Claude asks with options, until they're answered or the turn moves on.
    var question: AgentQuestion?
}

/// Claude Code's questions with options (AskUserQuestion): a tool call that waits for the answers, given
/// in the Claude app's own box (or the terminal's), or through the hook.
struct AgentQuestion: Equatable, Sendable {
    var questions: RelayQuestions
    var at: Date
    /// The tool call's own id.
    var id: String?
}

/// The Claude app's "Start this in its own session?" card: a tool call that waits for one of
/// its two buttons, Do it here or New session.
struct AgentOffer: Equatable, Sendable {
    var title: String
    var at: Date
    /// The tool call's own id.
    var id: String?
}

/// The Claude app's end-of-turn question and its buttons, in order. The buttons'
/// messages aren't kept: the answer is the app's own button, pressed there.
struct AgentNextStep: Equatable, Sendable {
    struct Choice: Equatable, Sendable {
        var label: String?
        /// One of the app's own actions (commit, create_pr…), which the app names itself.
        var action: String?
    }

    var ask: String
    var choices: [Choice]
    var at: Date
    /// The tool call's own id: the same each time the line is read.
    var id: String?
}

/// Reading tool calls' inputs: only the fields named here, bounded.
enum AgentToolInput {
    static let maxTarget = 60
    static let maxPrompt = 160
    static let maxReply = 280
    static let maxAsk = 200
    static let maxChoice = 40

    static func claudeTarget(tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "Read", "Edit", "MultiEdit", "Write":
            return Relay.fileName(input["file_path"])
        case "NotebookEdit", "NotebookRead":
            return Relay.fileName(input["notebook_path"])
        case "Bash", "PowerShell":
            return firstLine(input["description"]) ?? firstLine(input["command"])
        case "Grep", "Glob":
            return firstLine(input["pattern"])
        case "WebFetch":
            return (input["url"] as? String).flatMap { URL(string: $0)?.host() }.flatMap { Relay.label($0, maxLength: maxTarget) }
        case "Agent", "Task":
            return firstLine(input["description"])
        case "Skill":
            return firstLine(input["skill"])
        default:
            return mcpServer(tool)
        }
    }

    static func nextStep(input: [String: Any], at date: Date, id: String?) -> AgentNextStep? {
        guard let ask = Relay.label(input["ask"], maxLength: maxAsk),
              let actions = input["actions"] as? [[String: Any]], !actions.isEmpty else { return nil }
        let choices = actions.prefix(4).map { action in
            AgentNextStep.Choice(label: Relay.label(action["label"], maxLength: maxChoice),
                                 action: Relay.identifier(action["action"], maxLength: 32))
        }
        guard choices.allSatisfy({ $0.label != nil || $0.action != nil }) else { return nil }
        return AgentNextStep(ask: ask, choices: choices, at: date, id: id)
    }

    /// The Claude app's tool for starting a session; with `initiation: "offer"` it asks first.
    static let startSessionTool = "mcp__ccd_session__start_session"

    static func offer(input: [String: Any], at date: Date, id: String?) -> AgentOffer? {
        guard input["initiation"] as? String == "offer", let title = Relay.label(input["title"], maxLength: maxAsk) else { return nil }
        return AgentOffer(title: title, at: date, id: id)
    }

    /// Claude Code's tool for asking questions with options.
    static let questionTool = "AskUserQuestion"

    static func question(input: [String: Any], at date: Date, id: String?) -> AgentQuestion? {
        RelayRequestBuilder.questions(in: input).map { AgentQuestion(questions: $0, at: date, id: id) }
    }

    /// "mcp__github__create_issue" → "github".
    static func mcpServer(_ tool: String) -> String? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let server = tool.dropFirst(5).components(separatedBy: "__").first ?? ""
        return server.isEmpty ? nil : Relay.label(server, maxLength: maxTarget)
    }

    /// A Claude Code tool call that changes its task list (or the Claude app's plan).
    static func claudeTasks(tool: String, input: [String: Any]) -> AgentTaskChange? {
        switch tool {
        case "TodoWrite":
            guard let todos = input["todos"] as? [[String: Any]] else { return nil }
            return .replace(todos.compactMap { task(title: $0["content"], active: $0["activeForm"], status: $0["status"]) })
        case "TaskCreate":
            return task(title: input["subject"], active: input["activeForm"], status: "pending").map(AgentTaskChange.add)
        case "TaskUpdate":
            guard let id = Relay.identifier((input["taskId"] as? NSNumber)?.stringValue ?? input["taskId"], maxLength: 32)
            else { return nil }
            let status = input["status"] as? String
            if status == "deleted" { return .delete(id: id) }
            // A status this build doesn't know leaves the task's as it was.
            return .update(id: id, status: status.flatMap(AgentTask.Status.init), title: label(input["subject"]),
                           active: label(input["activeForm"]))
        case "mcp__ccd_turn__update_plan":
            if let items = input["items"] as? [[String: Any]] {
                return .replace(items.compactMap { task(title: $0["content"], active: nil, status: $0["status"]) })
            }
            if input["advance"] as? Bool == true { return .advance }
            let done = (input["done"] as? [NSNumber])?.map(\.intValue) ?? []
            let start = (input["start"] as? NSNumber)?.intValue
            return done.isEmpty && start == nil ? nil : .mark(done: done, start: start)
        case wrapUpTool:
            return .finishAll
        default:
            return nil
        }
    }

    /// The Claude app's own tools for its task list: not shown as activity.
    static func isPlanTool(_ tool: String) -> Bool {
        tool == "mcp__ccd_turn__update_plan" || tool == wrapUpTool
    }

    /// The Claude app's end of a turn: the task list done, and maybe a question.
    static let wrapUpTool = "mcp__ccd_turn__wrap_up"

    static func codexTasks(arguments: [String: Any]) -> AgentTaskChange? {
        guard let plan = arguments["plan"] as? [[String: Any]] else { return nil }
        return .replace(plan.compactMap { task(title: $0["step"], active: nil, status: $0["status"]) })
    }

    /// What a Codex tool call works on: the command, or the file a patch changes.
    static func codexTarget(tool: String, arguments: [String: Any]?, input: String?) -> String? {
        if tool == "apply_patch" {
            // In a code-mode script the patch is a string literal, its lines joined by "\n".
            let patch = (input ?? (arguments?["input"] as? String) ?? "").replacingOccurrences(of: "\\n", with: "\n")
            for line in patch.split(separator: "\n", maxSplits: 200).prefix(200) {
                for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                    return Relay.fileName(String(line.dropFirst(marker.count)))
                }
            }
            return nil
        }
        // A code-mode script: `tools.exec_command({cmd:"npm test", …})`.
        if arguments == nil, tool == "exec_command", let script = input,
           let command = script.firstMatch(of: /cmd\s*:\s*"((?:[^"\\]|\\.)*)"/)?.1 {
            return firstLine(String(command).replacingOccurrences(of: #"\""#, with: "\""))
        }
        guard let arguments else { return nil }
        if let command = arguments["cmd"] ?? arguments["command"] {
            if let parts = command as? [String] {
                // ["bash", "-lc", "npm test"] → the script.
                if parts.count >= 3, ["-lc", "-c"].contains(parts[parts.count - 2]) { return firstLine(parts.last) }
                return firstLine(parts.joined(separator: " "))
            }
            return firstLine(command)
        }
        return nil
    }

    /// The first of Codex's tools a code-mode script calls: `tools.exec_command(…)` → "exec_command".
    static func codeModeTool(in script: String) -> String? {
        script.firstMatch(of: /tools\.([A-Za-z_]+)\(/).map { String($0.1) }
    }

    static func firstLine(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.flatMap { Relay.label(String($0), maxLength: maxTarget) }
    }

    /// A prompt or a reply as a card shows it: the first lines joined, bounded.
    /// Text that starts with a tag is the app's own (a command's output, a reminder).
    static func excerpt(_ value: Any?, max: Int) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<") else { return nil }
        let lines = trimmed.split(whereSeparator: \.isNewline).prefix(6)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Relay.label(lines.joined(separator: " "), maxLength: max)
    }

    private static func label(_ value: Any?) -> String? { Relay.label(value, maxLength: maxTarget) }

    private static func task(title: Any?, active: Any?, status: Any?) -> AgentTask? {
        guard let title = label(title) else { return nil }
        let state = (status as? String).flatMap(AgentTask.Status.init) ?? .pending
        return AgentTask(title: title, active: label(active), status: state)
    }
}
