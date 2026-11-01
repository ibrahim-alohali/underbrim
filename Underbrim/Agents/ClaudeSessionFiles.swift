//
//  ClaudeSessionFiles.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What Claude Code writes about its own sessions, read without any setup:
//  - `~/.claude/sessions/<pid>.json`, one per running session (as `claude agents
//    --json` reports): status, folder, title, how it started. Rewritten on every
//    change since 2.1.162, removed on exit. The `.key` files beside it are never read.
//  - `~/.claude/projects/<folder>/<session>.jsonl`, the transcript: tool names, turn
//    ends, interruptions, API errors, and for the card (AgentDetails) tool targets, the
//    task list, the start of the last prompt and reply, the Claude app's question, and
//    questions with options while they wait.
//    Nothing else is read; nothing is kept beyond the card, logged or sent.
//  Both formats are internal to Claude Code; anything unexpected is skipped.
//

import Foundation

/// Where the agents keep their session files, under the user's home folder.
enum AgentFiles {
    /// The home folder the agents' files are read from: in Debug builds, UNDERBRIM_AGENT_HOME if set, so a
    /// build can be run against sample sessions.
    static var home: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["UNDERBRIM_AGENT_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return URL(fileURLWithPath: Relay.homeDirectory)
    }

    static func claudeSessions(home: URL) -> URL { home.appendingPathComponent(".claude/sessions", isDirectory: true) }
    static func claudeProjects(home: URL) -> URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
}

enum ClaudeSessionRegistry {
    enum Status: String { case busy, waiting, idle }

    struct Record: Equatable {
        let sessionID: String
        var cwd: String?
        /// When the session registered; tells its process from a later one with the same pid.
        var startedAt: Date?
        /// A name the user or the Claude app gave it (not one derived from the folder).
        var title: String?
        var entrypoint: String?
        var desktopSessionID: String?
        var attended = true
        /// nil before Claude Code 2.1.162, which doesn't report it.
        var status: Status?
        var waitingFor: String?
        var statusChangedAt: Date?
        var updatedAt: Date?

        /// Waiting for approval (a tool, network access for a sandboxed
        /// command, a worker) rather than for an answer (a question, a dialog…).
        var wantsApproval: Bool {
            status == .waiting && ["permission prompt", "sandbox request", "worker request"].contains(waitingFor)
        }
    }

    /// "<pid>.json" → the pid. Anything else (the `.key` files) → nil.
    static func pid(fileName: String) -> Int32? {
        guard fileName.hasSuffix(".json") else { return nil }
        let stem = fileName.dropLast(5)
        guard !stem.isEmpty, stem.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let pid = Int32(stem), pid > 0
        else { return nil }
        return pid
    }

    static func record(at url: URL) -> Record? {
        guard pid(fileName: url.lastPathComponent) != nil,
              let data = try? Data(contentsOf: url), data.count < 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = Relay.identifier(object["sessionId"])
        else { return nil }
        let entrypoint = Relay.token(object["entrypoint"], allowed: RelaySanitizer.entrypoints)
        let scripted = entrypoint.map { $0.hasPrefix("sdk-") || $0 == "local-agent" } ?? false
        let kind = object["kind"] as? String
        return Record(
            sessionID: sessionID,
            cwd: Relay.path(object["cwd"]),
            startedAt: date(milliseconds: object["startedAt"]),
            title: object["nameSource"] as? String == "derived" ? nil : Relay.label(object["name"]),
            entrypoint: entrypoint,
            desktopSessionID: Relay.desktopSessionID(object["hostSessionId"] as? String),
            // Background ("bg") and scripted sessions aren't attended.
            attended: (kind == nil || kind == "interactive") && !scripted,
            // A status this build doesn't know reads as working, never as finished.
            status: (object["status"] as? String).map { Status(rawValue: $0) ?? .busy },
            waitingFor: Relay.label(object["waitingFor"], maxLength: 40),
            statusChangedAt: date(milliseconds: object["statusUpdatedAt"]),
            updatedAt: date(milliseconds: object["updatedAt"])
        )
    }

    /// A time ahead of the clock is taken as now, like `isoDate`.
    private static func date(milliseconds value: Any?) -> Date? {
        (value as? NSNumber).map { min(Date(timeIntervalSince1970: $0.doubleValue / 1000), Date()) }
    }
}

enum ClaudeTranscript {
    enum Fact: Equatable {
        case prompt(String?)
        case toolStarted(String, id: String?, target: String?)
        case toolFinished(ids: [String])
        case tasks(AgentTaskChange)
        case nextStep(AgentNextStep)
        /// The Claude app's session offer, a tool call waiting on its card.
        case offer(AgentOffer)
        /// Questions with options, a tool call waiting on the answers.
        case question(AgentQuestion)
        /// The start of text the agent wrote: the reply, if the turn ends after it.
        case text(String)
        case turnEnded
        case interrupted
        case failed(reason: String?)

        /// Written by Claude (not by the user or the app).
        var fromClaude: Bool {
            switch self {
            case .toolStarted, .tasks, .nextStep, .offer, .question, .text, .turnEnded, .failed: true
            case .prompt, .toolFinished, .interrupted: false
            }
        }
    }

    static let interruptMarker = "[Request interrupted by user"

    /// One transcript line → its timestamp and facts. Reads only `type`, `timestamp`, the
    /// sidechain/meta flags, the origin's kind, `stop_reason`, block types, tool names and ids,
    /// the API error, the interrupt marker, and for the card AgentToolInput's fields and the text's start.
    static func facts(in line: Data) -> (date: Date?, facts: [Fact]) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["message"] as? [String: Any],
              object["isSidechain"] as? Bool != true,
              object["isCompactSummary"] as? Bool != true, object["isVisibleInTranscriptOnly"] as? Bool != true
        else { return (nil, []) }
        let date = isoDate(object["timestamp"])
        // Another session's message starts a turn as a meta line, its words kept out of the card.
        if object["isMeta"] as? Bool == true {
            let fromPeer = (object["origin"] as? [String: Any])?["kind"] as? String == "peer"
            return fromPeer && object["type"] as? String == "user" ? (date, [.prompt(nil)]) : (nil, [])
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        func isInterrupt(_ text: Any?) -> Bool { (text as? String)?.hasPrefix(interruptMarker) == true }

        switch object["type"] as? String {
        case "assistant":
            if object["isApiErrorMessage"] as? Bool == true {
                return (date, [.failed(reason: Relay.token(object["error"], allowed: RelaySanitizer.detailTokens))])
            }
            var facts: [Fact] = []
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    guard let name = Relay.identifier(block["name"], maxLength: 96) else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    // A task list's own tools change the list; they aren't shown as work.
                    if let change = AgentToolInput.claudeTasks(tool: name, input: input) {
                        facts.append(.tasks(change))
                        if name == AgentToolInput.wrapUpTool,
                           let step = AgentToolInput.nextStep(input: input, at: date ?? Date(), id: Relay.identifier(block["id"])) {
                            facts.append(.nextStep(step))
                        }
                    } else if name == AgentToolInput.startSessionTool,
                              let offer = AgentToolInput.offer(input: input, at: date ?? Date(), id: Relay.identifier(block["id"])) {
                        facts.append(.offer(offer))
                    } else if name == AgentToolInput.questionTool,
                              let question = AgentToolInput.question(input: input, at: date ?? Date(), id: Relay.identifier(block["id"])) {
                        facts.append(.question(question))
                    } else if !AgentToolInput.isPlanTool(name) {
                        facts.append(.toolStarted(name, id: Relay.identifier(block["id"]),
                                                  target: AgentToolInput.claudeTarget(tool: name, input: input)))
                    }
                case "text":
                    if let text = AgentToolInput.excerpt(block["text"], max: AgentToolInput.maxReply) { facts.append(.text(text)) }
                default:
                    break
                }
            }
            if message["stop_reason"] as? String == "end_turn" { facts.append(.turnEnded) }
            return (date, facts)
        case "user":
            if let text = message["content"] as? String {
                return (date, [isInterrupt(text) ? .interrupted : .prompt(AgentToolInput.excerpt(text, max: AgentToolInput.maxPrompt))])
            }
            if blocks.contains(where: { $0["type"] as? String == "text" && isInterrupt($0["text"]) }) {
                return (date, [.interrupted])
            }
            let results = blocks.filter { $0["type"] as? String == "tool_result" }
            if !results.isEmpty { return (date, [.toolFinished(ids: results.compactMap { Relay.identifier($0["tool_use_id"]) })]) }
            let typed = blocks.first { $0["type"] as? String == "text" }
            return (date, blocks.isEmpty ? [] : [.prompt(typed.flatMap { AgentToolInput.excerpt($0["text"], max: AgentToolInput.maxPrompt) })])
        default:
            return (nil, [])
        }
    }
}

/// "2026-10-07T09:14:45.003Z", with or without the fraction. Every caller reads when something happened,
/// so a time ahead of the clock is taken as now: events are ordered by time, and one from the future
/// would make every later event look stale.
func isoDate(_ value: Any?) -> Date? {
    guard let text = value as? String,
          let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    else { return nil }
    return min(date, Date())
}
