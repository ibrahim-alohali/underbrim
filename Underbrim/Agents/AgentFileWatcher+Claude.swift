//
//  AgentFileWatcher+Claude.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Claude Code's sessions: a status file per running process, and its transcript.
//

import Foundation

extension AgentFileWatcher {
    func statusFileChanged(pid: Int32, url: URL) {
        guard let record = ClaudeSessionRegistry.record(at: url) else {
            // Gone: the session exited, unless a newer process carries it on. (Unreadable mid-write: the next
            // change has it.)
            if !FileManager.default.fileExists(atPath: url.path), let old = claude.removeValue(forKey: pid),
               !claude.values.contains(where: { $0.record.sessionID == old.record.sessionID }) {
                emit(old, .sessionEnd, at: Date())
            }
            return
        }
        if var session = claude[pid], session.record.sessionID == record.sessionID {
            let previous = session.record
            session.record = record
            claude[pid] = session
            if previous.title != record.title || previous.cwd != record.cwd {
                emit(session, .update, at: record.updatedAt ?? Date())
            }
            if previous.status != record.status || previous.waitingFor != record.waitingFor {
                statusChanged(pid, from: previous.status)
            }
            return
        }
        // A new session, or a new conversation in the same process (/clear).
        if let old = claude.removeValue(forKey: pid) { emit(old, .sessionEnd, at: record.updatedAt ?? Date()) }
        guard let info = ProcessLineage.info(pid), Self.registered(record, by: info) else { return }
        // The same session in a new process (the Claude app restarted it): this one carries it on.
        for (other, _) in claude.filter({ $0.value.record.sessionID == record.sessionID }) { claude[other] = nil }

        let process = AgentProcess(stamp: ProcessStamp(pid: pid, start: info.start),
                                   host: ProcessLineage.agentAndHost(chain: ProcessLineage.ancestors(of: pid)).hostBundleID)
        var session = ClaudeSession(process: process, record: record)
        session.transcript = findTranscript(record.sessionID)
        if let transcript = session.transcript {
            // A task list, or a question, from long before the newest lines (the first read starts a window from the end).
            if let size = (try? transcript.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, UInt64(size) > JSONLTail.window {
                let earlier = Self.earlierState(in: transcript, before: UInt64(size) - JSONLTail.window)
                session.details.tasks = earlier.tasks
                session.details.nextStep = earlier.nextStep
                session.details.question = earlier.question
            }
            // Only to learn the tool in flight, the task list and how the last turn went.
            for line in session.tail.read(transcript) { _ = fold(line, into: &session) }
        }
        claude[pid] = session
        // The earliest time in the file, so no event after it reads as late.
        let earliest = [record.startedAt, record.statusChangedAt, record.updatedAt].compactMap { $0 }.min()
        emit(session, .sessionStart, at: earliest ?? Date())
        statusChanged(pid, from: nil, firstSight: true)
    }

    private func statusChanged(_ pid: Int32, from previous: ClaudeSessionRegistry.Status?, firstSight: Bool = false) {
        guard var session = claude[pid] else { return }
        let record = session.record
        let at = record.statusChangedAt ?? record.updatedAt ?? Date()
        switch record.status {
        case .busy?:
            if previous == .idle {
                // A new turn: the last one's question or offer is gone from Claude's window.
                session.turn = .running
                session.details.nextStep = nil
                session.details.offer = nil
                session.details.question = nil
                session.appWords = false
            } else if firstSight {
                session.turn = .running
            }
            // From approval back to work, the approved tool is running.
            emit(session, session.busyEvent, at: at)
        case .waiting?:
            if record.wantsApproval {
                emit(session, .permissionRequest(tool: session.tool), at: at)
            } else {
                emit(session, .notification(.elicitationDialog), at: at)
            }
        case .idle?:
            if firstSight {
                if session.turn != .none { emit(session, .notification(.idlePrompt), at: at) }
            } else if previous == .busy || previous == .waiting {
                let sessionID = record.sessionID
                queue.asyncAfter(deadline: .now() + Self.turnEndGrace) { [self] in
                    finishTurn(pid, sessionID: sessionID, at: at)
                }
            }
        case nil:
            // Claude Code before 2.1.162: the transcript is all there is.
            guard firstSight else { break }
            switch session.turn {
            case .none: break
            case .running: emit(session, session.busyEvent, at: at)
            case .ended(_, let ended): emit(session, .notification(.idlePrompt), at: ended)
            }
        }
        claude[pid] = session
    }

    /// The status went idle: done, interrupted or stopped by an error, as the transcript tells.
    private func finishTurn(_ pid: Int32, sessionID: String, at date: Date) {
        guard var session = claude[pid], session.record.sessionID == sessionID, session.record.status == .idle
        else { return }
        if let transcript = session.transcript {
            for line in session.tail.read(transcript) {
                for event in fold(line, into: &session) { pending.append(Update(event: event, live: true, details: session.details)) }
            }
        }
        session.running = []
        session.details.target = nil
        session.details.subagents = 0
        session.details.offer = nil
        session.details.question = nil
        claude[pid] = session
        switch session.turn {
        case .ended(let outcome, let ended): emit(session, outcome.event, at: max(date, ended))
        case .none, .running: emit(session, .stop, at: date)
        }
        flush()
    }

    func transcriptChanged(_ url: URL) {
        let id = url.deletingPathExtension().lastPathComponent
        guard let pid = claude.first(where: { $0.value.record.sessionID == id })?.key, var session = claude[pid] else { return }
        if session.transcript != url {
            session.transcript = url
            session.tail = JSONLTail()
        }
        for line in session.tail.read(url) {
            for event in fold(line, into: &session) { pending.append(Update(event: event, live: session.live, details: session.details)) }
        }
        claude[pid] = session
    }

    /// Folds one transcript line into `session`, returning its events. While Claude reports its
    /// status, that decides the phase and the transcript adds the tool; before 2.1.162, all.
    private func fold(_ line: Data, into session: inout ClaudeSession) -> [AgentEvent] {
        let (date, facts) = ClaudeTranscript.facts(in: line)
        let at = date ?? Date()
        let working = !session.live || session.record.status == .busy
        let detailsBefore = session.details
        var events: [AgentEvent] = []
        func runningChanged() {
            session.details.target = session.running.last?.target
            session.details.subagents = session.running.filter { ["Agent", "Task"].contains($0.name) }.count
        }
        for fact in facts {
            // Claude answered words the app wrote itself: they started a turn, which ends the last one's question.
            if session.appWords, fact.fromClaude {
                session.appWords = false
                session.details.nextStep = nil
                session.details.offer = nil
                session.details.question = nil
            }
            switch fact {
            case .prompt(let text):
                // Words the app writes itself (a slash command, another session's message, a task's note) start
                // a turn only if Claude goes to work on them: its status (statusChanged) or its next line says so.
                if text == nil, session.live {
                    session.appWords = true
                    break
                }
                session.appWords = false
                session.running = []
                runningChanged()
                session.turn = .running
                session.details.prompt = text
                session.details.reply = nil
                session.details.nextStep = nil
                session.details.offer = nil
                session.details.question = nil
                session.lastText = nil
                if !session.live { events.append(event(session, .userPromptSubmit, at: at)) }
            case .toolStarted(let name, let id, let target):
                session.running.append((id, name, target))
                runningChanged()
                session.turn = .running
                if working { events.append(event(session, .preToolUse(tool: name), at: at)) }
            case .toolFinished(let ids):
                // The questions answered, or turned down: the turn goes on.
                if let question = session.details.question, ids.isEmpty || question.id.map(ids.contains) ?? true {
                    session.details.question = nil
                }
                let before = session.running.count
                session.running.removeAll { call in ids.isEmpty || call.id.map(ids.contains) ?? true }
                // A result for a call that wasn't followed (a task list's own tool): nothing changed.
                guard session.running.count != before || before == 0 else { break }
                runningChanged()
                // The offer card answered (either button): the turn goes on.
                if let offer = session.details.offer, ids.isEmpty || offer.id.map(ids.contains) ?? true {
                    session.details.offer = nil
                }
                // Others still running in parallel: the newest of them is the tool now.
                if working {
                    events.append(event(session, session.details.offer == nil
                        ? session.tool.map { .preToolUse(tool: $0) } ?? .postToolUse(tool: nil) : session.busyEvent, at: at))
                }
            case .offer(let offer):
                session.running.append((offer.id, AgentToolInput.startSessionTool, nil))
                runningChanged()
                session.turn = .running
                session.details.offer = offer
                if working { events.append(event(session, .notification(.agentNeedsInput), at: at)) }
            case .tasks(let change):
                session.details.tasks.apply(change)
            case .nextStep(let step):
                session.details.nextStep = step
            case .question(let question):
                session.running.append((question.id, AgentToolInput.questionTool, nil))
                runningChanged()
                session.turn = .running
                session.details.question = question
                if working { events.append(event(session, .preToolUse(tool: AgentToolInput.questionTool), at: at)) }
            case .text(let text):
                session.lastText = text
            case .turnEnded, .interrupted, .failed:
                let outcome: ClaudeSession.Outcome = switch fact {
                case .interrupted: .interrupted
                case .failed(let reason): .failed(reason: reason)
                default: .done
                }
                session.turn = .ended(outcome, at: at)
                if outcome == .done { session.details.reply = session.lastText }
                session.details.offer = nil
                session.details.question = nil
                session.running = []
                runningChanged()
                if !session.live { events.append(event(session, outcome.event, at: at)) }
            }
        }
        // A new task list (or step), or a question asked or answered, alone changes no state; the
        // card and the island still hear of it.
        if events.isEmpty, session.details.tasks != detailsBefore.tasks || session.details.nextStep != detailsBefore.nextStep
            || session.details.offer != detailsBefore.offer || session.details.question != detailsBefore.question {
            events.append(event(session, .update, at: at))
        }
        return events
    }

    /// How far back, before the first read's window, a task list (or a question) is looked for.
    static let taskBackfill: UInt64 = 8 << 20

    /// The task list, the Claude app's pending question and questions with options still waiting, as of
    /// `end`, from earlier lines (up to `taskBackfill` back) that change them; other lines aren't parsed.
    static func earlierState(in url: URL, before end: UInt64) -> (tasks: [AgentTask], nextStep: AgentNextStep?, question: AgentQuestion?) {
        guard end > 0, let handle = try? FileHandle(forReadingFrom: url) else { return ([], nil, nil) }
        defer { try? handle.close() }
        let start = end > taskBackfill ? end - taskBackfill : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(end - start)) else { return ([], nil, nil) }
        let markers = ["update_plan", "wrap_up", "TodoWrite", "TaskCreate", "TaskUpdate", AgentToolInput.questionTool].map { Data($0.utf8) }
        let user = Data(#""type":"user""#.utf8), result = Data("tool_result".utf8)
        var tasks: [AgentTask] = []
        var nextStep: AgentNextStep?
        var question: AgentQuestion?
        // Tool results aren't read, but for the questions' own: their answer.
        var answer: Data?
        for line in data.split(separator: 0x0A) where line.count <= JSONLTail.maxLine
            && (markers.contains(where: { line.range(of: $0) != nil }) || (line.range(of: user) != nil && line.range(of: result) == nil)
                || answer.map { line.range(of: $0) != nil } == true) {
            for fact in ClaudeTranscript.facts(in: Data(line)).facts {
                switch fact {
                case .tasks(let change): tasks.apply(change)
                case .nextStep(let step): nextStep = step
                case .question(let asked): question = asked
                case .toolFinished(let ids):
                    if let asked = question, ids.isEmpty || asked.id.map(ids.contains) ?? true { question = nil }
                case .prompt:
                    nextStep = nil
                    question = nil
                case .interrupted, .turnEnded, .failed: question = nil
                default: break
                }
            }
            answer = question?.id.map { Data($0.utf8) }
        }
        return (tasks, nextStep, question)
    }

    private func findTranscript(_ sessionID: String) -> URL? {
        let name = sessionID + ".jsonl"
        let folders = (try? FileManager.default.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The process that wrote the file, not a later one that got its pid (a crashed session
    /// leaves its file behind): that one started after the file was written.
    static func registered(_ record: ClaudeSessionRegistry.Record, by process: ProcessLineage.Info) -> Bool {
        guard let registered = record.startedAt?.timeIntervalSince1970 else { return true }
        return Double(process.start) / 1_000_000 <= registered + 1
    }

    private func event(_ session: ClaudeSession, _ kind: AgentEvent.Kind, at date: Date) -> AgentEvent {
        let record = session.record
        return AgentEvent(provider: .claude, session: record.sessionID, kind: kind, date: date, cwd: record.cwd,
                          title: record.title, entry: record.entrypoint, hostSession: record.desktopSessionID,
                          attended: record.attended, host: session.process.host, process: session.process.stamp)
    }

    private func emit(_ session: ClaudeSession, _ kind: AgentEvent.Kind, at date: Date) {
        pending.append(Update(event: event(session, kind, at: date), live: session.live, details: session.details))
    }
}
