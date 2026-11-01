//
//  AgentRecentSessions.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The apps' previous sessions, to go back to from the Agents tab; read on demand, off
//  the main thread, nothing kept.
//  - Claude: the app's undocumented records in ~/Library/Application Support/Claude/
//    claude-code-sessions/…/local_<id>.json (only id, title, folder, last activity,
//    archived), offered only while "Open Claude app sessions directly" is on.
//  - Codex: threads whose logs are still in ~/.codex/sessions (archiving moves them),
//    named from Codex's names list; only each log's first record is read.
//  Terminal sessions have no link to reopen them, so they aren't listed.
//

import Foundation

struct RecentAgentSession: Identifiable, Equatable, Sendable {
    let id: String
    let provider: AgentProvider
    let title: String
    let folder: String?
    let lastActive: Date

    var link: URL? { provider.sessionLink(id: id) }
}

enum AgentRecentSessions {
    static let limit = 12

    /// The provider's previous sessions, latest first, without those running now (`excluding`).
    @concurrent
    static func load(_ provider: AgentProvider, excluding: Set<String>) async -> [RecentAgentSession] {
        let home = AgentFiles.home
        let all: [RecentAgentSession] = switch provider {
        case .claude: claude(home: home)
        case .codex: codex(home: home)
        // Their sessions have no link to reopen them.
        case .qwen, .qoder, .cursor, .antigravity: []
        }
        return Array(all.filter { !excluding.contains($0.id) }.sorted { $0.lastActive > $1.lastActive }.prefix(limit))
    }

    nonisolated static func claude(home: URL) -> [RecentAgentSession] {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        // Two folder levels (account, then organisation) above the records.
        let files = (subfolders(of: root).flatMap(subfolders(of:))).flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
        }
        // Each record is a few hundred kilobytes: only the latest are read.
        let latest = files.sorted { modified($0) > modified($1) }.prefix(limit * 2)
        return latest.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["isArchived"] as? Bool != true,
                  let id = Relay.desktopSessionID(object["sessionId"] as? String)
            else { return nil }
            let folder = Relay.path(object["cwd"])
            guard let title = Relay.label(object["title"]) ?? folder.map({ ($0 as NSString).lastPathComponent }) else { return nil }
            let when = (object["lastActivityAt"] as? Double).map { min(Date(timeIntervalSince1970: $0 / 1000), Date()) } ?? modified(url)
            return RecentAgentSession(id: id, provider: .claude, title: title, folder: folder, lastActive: when)
        }
    }

    nonisolated static func codex(home: URL) -> [RecentAgentSession] {
        let names = (try? Data(contentsOf: AgentFiles.codexIndex(home: home))).map(CodexRollout.threadNames(in:)) ?? [:]
        guard let walk = FileManager.default.enumerator(at: AgentFiles.codexSessions(home: home),
                                                        includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let logs = walk.compactMap { $0 as? URL }.compactMap { url in CodexRollout.threadID(fileName: url.lastPathComponent).map { (id: $0, url: url) } }
        return logs.sorted { modified($0.url) > modified($1.url) }.prefix(limit * 2).compactMap { log in
            guard case .meta(let meta)? = JSONLines.firstLine(of: log.url).flatMap(CodexRollout.entry(in:)), meta.attended else { return nil }
            // A chat outside a project runs in a folder Codex makes for it (…/Codex/<date>/<word>):
            // no folder worth naming.
            let folder = meta.cwd.flatMap { cwd in
                let parent = (cwd as NSString).deletingLastPathComponent as NSString
                let made = parent.lastPathComponent.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
                    && (parent.deletingLastPathComponent as NSString).lastPathComponent == "Codex"
                return made ? nil : cwd
            }
            guard let title = names[log.id] ?? folder.map({ ($0 as NSString).lastPathComponent }) else { return nil }
            return RecentAgentSession(id: log.id, provider: .codex, title: title, folder: folder, lastActive: modified(log.url))
        }
    }

    private nonisolated static func subfolders(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private nonisolated static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
