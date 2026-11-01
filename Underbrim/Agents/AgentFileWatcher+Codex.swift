//
//  AgentFileWatcher+Codex.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Codex's threads: their logs (rollouts), followed while a Codex process holds them
//  open, and the names in its session index.
//

import Darwin
import Foundation

extension AgentFileWatcher {
    /// `holder`: the Codex process found holding the log open, when that's how it was found.
    func rolloutChanged(_ url: URL, holder: pid_t? = nil) {
        guard let id = CodexRollout.threadID(fileName: url.lastPathComponent) else { return }
        watchCodexIndex()
        let isNew = codex[url.path] == nil
        var thread: CodexThread
        if let known = codex[url.path] {
            thread = known
        } else {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // Threads not seen for hours are forgotten; a new line brings one back.
            // A log whose Codex has quit stops being followed (FSEvents saw it close).
            for (path, old) in codex {
                if old.seenAt.timeIntervalSinceNow < -3 * 3600 {
                    old.source?.cancel()
                    codex[path] = nil
                } else if old.source != nil, let process = old.process.stamp, ProcessLineage.info(process.pid)?.start != process.start {
                    old.source?.cancel()
                    codex[path]?.source = nil
                }
            }
            thread = CodexThread(id: id)
            if let line = JSONLines.firstLine(of: url), case .meta(let meta)? = CodexRollout.entry(in: line) { thread.meta = meta }
        }
        thread.seenAt = Date()
        var events: [(kind: AgentEvent.Kind, date: Date)] = []
        let detailsBefore = thread.details
        // The newest line's own time, for a change of plan alone (not when it was read).
        var newest: Date?
        for line in thread.tail.read(url) {
            let (lineDate, entries) = CodexRollout.lineEntries(in: line)
            if let lineDate { newest = max(newest ?? lineDate, lineDate) }
            for entry in entries {
                switch entry {
                case .event(let kind, let date):
                    switch kind {
                    case .userPromptSubmit: thread.details.reply = nil; thread.details.target = nil; thread.lastText = nil
                    case .postToolUse, .interrupt: thread.details.target = nil
                    case .stop: thread.details.target = nil; thread.details.reply = thread.details.reply ?? thread.lastText
                    default: break
                    }
                    events.append((kind, date ?? Date()))
                case .note(.target(let target)): thread.details.target = target
                case .note(.tasks(let change)): thread.details.tasks.apply(change)
                case .note(.prompt(let text)): thread.details.prompt = text; thread.details.reply = nil
                case .note(.text(let text)): thread.lastText = text
                case .note(.reply(let text)): thread.details.reply = text
                case .note(.folder(let folder)): thread.meta.cwd = folder
                case .meta: break
                }
            }
        }
        // A new plan alone changes no state; the card still hears of it.
        if events.isEmpty, thread.details != detailsBefore {
            events.append((.update, newest ?? Date()))
        }
        // The process writing the log: its exit ends the session, its ancestors name the app to
        // bring forward. Looked for when a thread appears, a turn starts, Codex reopens it, or the log
        // grows after its Codex quit (a new process took the thread up: `codex resume`, a relaunched app).
        let known = thread.process.stamp
        let quit = known.map { ProcessLineage.info($0.pid)?.start != $0.start } ?? false
        let look = known == nil ? isNew || events.contains(where: { $0.kind == .userPromptSubmit })
                                : holder.map { $0 != known?.pid } ?? (quit && !events.isEmpty)
        if look, let pid = holder ?? ProcessLineage.holder(of: url.path, namePrefix: "codex"), let info = ProcessLineage.info(pid) {
            thread.process = AgentProcess(stamp: ProcessStamp(pid: pid, start: info.start),
                                          host: ProcessLineage.agentAndHost(chain: ProcessLineage.ancestors(of: pid)).hostBundleID)
            // Taken up by another process after the last one quit: the thread is going again.
            if quit, !isNew { events.insert((.sessionStart, events.first?.date ?? Date()), at: 0) }
        }
        if thread.process.stamp != nil, thread.source == nil { thread.source = follow(url) }
        codex[url.path] = thread
        // A log no Codex has open (an old thread, or one Codex quit in the
        // middle of) is history: read, but not shown until it grows again.
        if isNew {
            guard thread.process.stamp != nil else { return }
            // Open but untouched for long (a thread only looked at in Codex): followed, and shown once it grows.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if holder != nil, modified.map({ $0.timeIntervalSinceNow < -Self.launchWindow }) ?? true { return }
            events.insert((.sessionStart, thread.meta.date ?? Date()), at: 0)
        }
        for (kind, date) in events {
            var event = Self.codexEvent(thread, kind, at: date)
            event.cwd = thread.meta.cwd
            event.title = codexNames[id]
            event.attended = thread.meta.attended
            pending.append(Update(event: event, live: false, details: thread.details))
        }
    }

    private func follow(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                codex[url.path]?.source = nil
                // Moved away, not replaced: archived or deleted in Codex, so the thread is over.
                if !FileManager.default.fileExists(atPath: url.path), let thread = codex.removeValue(forKey: url.path) {
                    pending.append(Update(event: Self.codexEvent(thread, .sessionEnd, at: Date()), live: false))
                    flush()
                    return
                }
            }
            rolloutChanged(url)
            flush()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func watchCodexIndex() {
        guard codexIndexSource == nil else { return }
        let fd = open(codexIndex.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                codexIndexSource = nil
                watchCodexIndex()
            }
            refreshCodexNames()
            flush()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        codexIndexSource = source
        refreshCodexNames()
    }

    /// Rereads the names and passes on shown threads' new ones; a vanished name leaves the last.
    private func refreshCodexNames() {
        let old = codexNames
        codexNames = (try? FileHandle(forReadingFrom: codexIndex).read(upToCount: 16 << 20)).map(CodexRollout.threadNames) ?? [:]
        for thread in codex.values where thread.process.stamp != nil {
            guard let name = codexNames[thread.id], name != old[thread.id] else { continue }
            var event = Self.codexEvent(thread, .title, at: Date())
            event.title = name
            pending.append(Update(event: event, live: false))
        }
    }

    private static func codexEvent(_ thread: CodexThread, _ kind: AgentEvent.Kind, at date: Date) -> AgentEvent {
        AgentEvent(provider: .codex, session: thread.id, kind: kind, date: date, host: thread.process.host,
                   process: thread.process.stamp)
    }
}
