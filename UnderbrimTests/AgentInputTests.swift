//
//  AgentInputTests.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import Testing
@testable import Underbrim

struct ClaudeTranscriptTests {
    /// A turn started by another session's message is written as a meta line. The question asked before it
    /// is over all the same (the Claude app drops its box), so the island has to see the new turn.
    @Test func aMessageFromAnotherSessionStartsATurn() {
        let line = #"{"type":"user","isMeta":true,"isSidechain":false,"origin":{"kind":"peer","from":"local_1","name":"Film"},"timestamp":"2026-10-29T03:05:59.086Z","message":{"role":"user","content":"Another Claude session sent a message: <cross-session-message>Done.</cross-session-message>"}}"#
        #expect(ClaudeTranscript.facts(in: Data(line.utf8)).facts == [.prompt(nil)])
    }

    /// Claude's questions with options, as Claude Code writes the call: read as the hook reads them, so the
    /// island shows the same options and answers them by the same places when there's no hook.
    @Test func questionsWithOptionsAreRead() throws {
        let line = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-10-31T03:32:16.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"AskUserQuestion","input":{"questions":[{"question":"Pick a colour.","header":"Colour","multiSelect":false,"options":[{"label":"Red (Recommended)","description":"Warm."},{"label":"Blue","description":"Cool."}]},{"question":"Pick any pets.","header":"Pets","multiSelect":true,"options":[{"label":"Cats"},{"label":"Dogs","preview":"<b>Dogs</b>"}]}]}}]}}"#
        let facts = ClaudeTranscript.facts(in: Data(line.utf8)).facts
        guard case .question(let asked)? = facts.first else {
            Issue.record("No question in \(facts)")
            return
        }
        #expect(asked.id == "toolu_1")
        #expect(asked.questions.all.map(\.question) == ["Pick a colour.", "Pick any pets."])
        #expect(asked.questions.all.map(\.header) == ["Colour", "Pets"])
        #expect(asked.questions.all.map(\.multiSelect) == [false, true])
        #expect(asked.questions.all[0].options.map(\.label) == ["Red (Recommended)", "Blue"])
        #expect(asked.questions.all[1].options.map(\.description) == [nil, nil])
    }

    /// The first read takes the newest lines; a question further back is looked for and followed to its
    /// answer (a line that's otherwise skipped), so one answered long ago isn't asked again at launch.
    @Test func aQuestionBeforeTheNewestLinesIsFollowedToItsAnswer() throws {
        let asked = #"{"type":"assistant","timestamp":"2026-10-31T03:32:16.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"AskUserQuestion","input":{"questions":[{"question":"Pick one.","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}}]}}"#
        let answered = #"{"type":"user","timestamp":"2026-10-31T03:32:30.000Z","message":{"role":"user","content":[{"tool_use_id":"toolu_9","type":"tool_result","content":"Your questions have been answered: \"Pick one.\"=\"A\"."}]}}"#
        let work = #"{"type":"assistant","timestamp":"2026-10-31T03:32:31.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_10","name":"Read","input":{"file_path":"/tmp/a"}}]}}"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func earlier(_ lines: [String]) throws -> AgentQuestion? {
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            try data.write(to: url)
            return AgentFileWatcher.earlierState(in: url, before: UInt64(data.count)).question
        }
        #expect(try earlier([asked, work])?.id == "toolu_9")
        #expect(try earlier([asked, answered, work]) == nil)
    }

    /// A line stamped ahead of the clock is taken as now: a session orders its events by time, so a future
    /// one would make every later event look late and leave the session stuck where it was.
    @Test func aTimeAheadOfTheClockIsTakenAsNow() throws {
        let line = #"{"type":"user","timestamp":"2099-01-01T00:00:00.000Z","message":{"role":"user","content":"Go"}}"#
        let date = try #require(ClaudeTranscript.facts(in: Data(line.utf8)).date)
        #expect(date <= Date())
    }
}

struct AgentUsageInputTests {
    /// The Claude app's usage file, written while the clock was ahead: the reading has no age to go by, so
    /// it's left out rather than shown as just updated each time it's read.
    @Test func aClaudeAppReadingFromTheFutureIsLeftOut() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ahead = Int((Date().timeIntervalSince1970 + 3600) * 1000)
        try Data(#"{"version":2,"samples":[{"t":\#(ahead),"u":{"fh":40,"sd":10}}]}"#.utf8).write(to: url)
        #expect(AgentUsageStore.readClaudeDesktopCache(at: url) == nil)
    }

    /// Counts come from files any process can write: an absurd one must not overflow the sums and stop the app.
    @Test func hugeTokenCountsDontOverflow() throws {
        let line = #"{"type":"assistant","timestamp":"2026-10-29T03:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":9223372036854775807,"cache_creation_input_tokens":1,"output_tokens":9223372036854775807,"cache_read_input_tokens":9223372036854775807}}}"#
        let usage = try #require(TokenLogs.claudeUsage(in: Data(line.utf8)))
        var day = TokenDay()
        day.add(usage)
        day.add(day)
        #expect(day.total > 0)
    }

    /// Codex's usage is a percentage like the others: out of range or not finite, it doesn't reach the chip.
    @Test func codexUsageStaysAPercentage() {
        let limits: [String: Any] = ["result": ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 1e300], "secondary": ["usedPercent": -5]]]]
        let windows = CodexAppServer.parse(account: nil, limits: limits, hooks: nil).windows
        #expect(windows.allSatisfy { (0...100).contains($0.usedPercent) })
    }
}

struct RelayEventTests {
    /// The hooks' events are written by other processes: one stamped ahead of the clock is taken as now.
    @Test func anEventAheadOfTheClockIsTakenAsNow() throws {
        let line = #"{"v":1,"provider":"claude","kind":"UserPromptSubmit","session":"s1","ts":4102444800}"#
        guard case .agent(let event)? = RelayServer.decode(Data(line.utf8)) else { Issue.record("not decoded"); return }
        #expect(event.date <= Date())
    }

    /// Qwen Code and Qoder say when a tool was refused in the terminal: the card stops asking for approval.
    @Test func aRefusedToolEndsTheWaitForApproval() throws {
        func event(_ kind: String, at ts: Int) throws -> AgentEvent {
            let line = #"{"v":1,"provider":"qwen","kind":"\#(kind)","session":"s1","tool":"run_shell_command","ts":\#(ts)}"#
            guard case .agent(let event)? = RelayServer.decode(Data(line.utf8)) else { throw CocoaError(.coderReadCorrupt) }
            return event
        }
        var session = AgentSession(provider: .qwen, sessionID: "s1", at: Date(timeIntervalSince1970: 1000))
        session.apply(try event("PermissionRequest", at: 1001))
        #expect(session.needsAttention)
        session.apply(try event("PermissionDenied", at: 1002))
        #expect(!session.needsAttention)
    }
}

struct AgentToolNameTests {
    /// Tool names come in each agent's own words: every place that shows a wait or a tool at work names
    /// it the same readable way, an MCP tool by its name and server, Codex's and Qwen Code's tools as
    /// Claude Code's are named.
    @Test func toolsReadTheSameWayForEveryAgent() {
        #expect(AgentToolName.readable("mcp__github__create_issue") == "create issue (github)")
        #expect(AgentToolName.readable("run_shell_command") == "Bash")
        #expect(AgentToolName.readable("exec_command") == "Bash")
        #expect(AgentToolName.readable("apply_patch") == "Edit")
        #expect(AgentToolName.readable("view_image") == "view image")
        #expect(AgentToolName.readable("Bash") == "Bash")
    }

    /// Claude Code and Qoder ask for a plan's approval and their questions through the same prompt as
    /// for a tool: the session waits on a plan and a question, not on a tool called ExitPlanMode.
    @Test func aPlanAndAQuestionAreNotToolApprovals() {
        func event(_ kind: AgentEvent.Kind, at ts: TimeInterval) -> AgentEvent {
            AgentEvent(provider: .qoder, session: "s1", kind: kind, date: Date(timeIntervalSince1970: ts))
        }
        var session = AgentSession(provider: .qoder, sessionID: "s1", at: Date(timeIntervalSince1970: 1000))
        session.apply(event(.permissionRequest(tool: "ExitPlanMode"), at: 1001))
        #expect(session.phase == .attention(.plan))
        session.apply(event(.postToolUse(tool: "ExitPlanMode"), at: 1002))
        session.apply(event(.permissionRequest(tool: "AskUserQuestion"), at: 1003))
        #expect(session.phase == .attention(.question))
    }

    /// The permission notice can come before the request that names its tool: a wait that turns out to be
    /// a plan is still the same wait, so it keeps its start (and a set-aside wait stays set aside).
    @Test func aPromptThatTurnsOutToBeAPlanKeepsItsStart() {
        func event(_ kind: AgentEvent.Kind, at ts: TimeInterval) -> AgentEvent {
            AgentEvent(provider: .claude, session: "s1", kind: kind, date: Date(timeIntervalSince1970: ts))
        }
        var session = AgentSession(provider: .claude, sessionID: "s1", at: Date(timeIntervalSince1970: 1000))
        session.apply(event(.userPromptSubmit, at: 1001))
        session.apply(event(.notification(.permissionPrompt), at: 1002))
        session.apply(event(.permissionRequest(tool: "ExitPlanMode"), at: 1003))
        #expect(session.phase == .attention(.plan))
        #expect(session.phaseSince == Date(timeIntervalSince1970: 1002))
    }
}

struct RelayRequestTests {
    /// A plan Claude Code sends with nothing to show (its field renamed, no file named) goes back to
    /// Claude's own prompt instead of a card whose Approve approves a plan no one saw.
    @Test func aPlanWithNothingToShowIsHandedBack() {
        let input: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "ExitPlanMode",
                                    "tool_input": ["planText": "# Plan\n1. Do it"]]
        #expect(RelayRequestBuilder.claudeRequest(id: "r1", input: input) == nil)
    }
}

struct RelayAnswerTests {
    private let raw = "Which one?\r\n\u{2067}خيار\u{2069}"
    private var input: [String: Any] {
        ["hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion",
         "tool_input": ["questions": [["question": raw, "options": [["label": "A"], ["label": "B\u{202E}"]], "multiSelect": false]]]]
    }

    private func answers(in output: Data?) throws -> [String: String]? {
        let object = try JSONSerialization.jsonObject(with: try #require(output)) as? [String: Any]
        let decision = (object?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        return (decision?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]
    }

    /// The card shows a question cleaned of line breaks and text-direction marks; the answer still
    /// goes back under Claude's own question, with Claude's own option label.
    @Test func anAnswerUsesTheAgentsOwnWords() throws {
        let request = try #require(RelayRequestBuilder.claudeRequest(id: "r1", input: input))
        let answer = RelayAnswer(id: "r1", decision: .answer, choices: [RelayChoice(question: 0, options: [1], text: nil)])
        #expect(try answers(in: RelayRequestBuilder.claudeOutput(for: answer, request: request, input: input)) == [raw: "B\u{202E}"])
    }
}
