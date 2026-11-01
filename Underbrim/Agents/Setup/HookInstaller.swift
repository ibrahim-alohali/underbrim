//
//  HookInstaller.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The opt-in agent hooks: each agent's PermissionRequest hook (approvals, and
//  Claude's questions and plans, answered from the notch), and progress hooks for
//  agents that keep no session files (Antigravity's are in AntigravityPlugin). Also
//  removes legacy status hooks and manages the opt-in Claude status line. Every write
//  is backed up, keeps other content and key order, follows symlinks, keeps
//  permissions and is verified by re-reading; removal takes out only our entries.
//

import Foundation

/// How Underbrim's hooks for one agent are set up: in its settings file (HookInstaller) or in a
/// plugin folder of its own (AntigravityPlugin).
protocol HookAgentSetup {
    func status() -> HookInstaller.Status
    /// The backup of the file it changed, if it changed one.
    @discardableResult func install() throws -> URL?
    @discardableResult func uninstall() throws -> URL?
    /// Its approvals are answered in the notch.
    func answersInNotch() -> Bool
}

extension AgentProvider {
    /// The hooks that follow its sessions; nil for the agents read from their files (Claude Code's
    /// and Codex's answering hooks have switches of their own).
    func hookSetup(answers: Bool) -> HookAgentSetup? {
        switch self {
        case .claude, .codex: nil
        case .cursor, .qwen, .qoder: HookInstaller(agent: self, answers: answers)
        case .antigravity: AntigravityPlugin()
        }
    }
}

struct HookInstaller: HookAgentSetup {
    struct Entry: Equatable {
        let name: String
        /// Seconds.
        let timeout: Int
        /// The agent goes on without waiting for it (Qoder's own word for it).
        var async = false
        var asks = false
        var matcher: String?
    }

    enum Status: Equatable {
        case notInstalled
        case installed
        /// Some of our entries exist but differ from what this build writes.
        case outdated
        /// The config file exists but can't be parsed; we won't touch it.
        case unreadable(String)

        /// Hooks of ours are in place, even ones an earlier build wrote (they're refreshed when switched).
        var follows: Bool {
            switch self {
            case .installed, .outdated: true
            case .notInstalled, .unreadable: false
            }
        }
    }

    enum InstallError: LocalizedError {
        case unreadable(String)
        case changedWhileWriting
        case verificationFailed
        case previewCopy

        var errorDescription: String? {
            switch self {
            case .previewCopy: String(localized: "The preview copy doesn't change other apps' settings.")
            case .unreadable(let reason): String(localized: "The settings file couldn't be read safely (\(reason)). Nothing was changed.")
            case .changedWhileWriting: String(localized: "The settings file changed while it was being updated. Nothing was changed; try again.")
            case .verificationFailed: String(localized: "The settings file changed again right after it was updated, so it was left as it is. Try again.")
            }
        }
    }

    let agent: AgentProvider
    let configURL: URL
    let relayPath: String
    /// Qwen Code and Qoder: their requests are answered in the notch too.
    let answers: Bool
    private let layout: AgentSpec.HookLayout

    /// nil for an agent whose hooks aren't in a settings file of its own (Antigravity's plugin). The home is
    /// the one the agents' files are read from, so a build run against sample sessions changes only theirs.
    init?(agent: AgentProvider, answers: Bool = true, home: String = AgentFiles.home.path,
          relayPath: String = RelayLink.stablePath) {
        guard let file = agent.spec.hookFile else { return nil }
        self.agent = agent
        self.answers = answers
        self.relayPath = relayPath
        layout = file.layout
        configURL = URL(fileURLWithPath: home).appendingPathComponent(file.path)
    }

    // MARK: Entries

    /// How long the notch holds a request from an agent that waits for its hook (Codex, Qwen
    /// Code) before handing it back to the agent's own prompt.
    static let handBackAfter: TimeInterval = 10 * 60
    /// Their hook's timeout: a minute past the hand-back, so the app always answers first.
    static let waitingAskTimeout = Int(handBackAfter) + 60

    /// For Claude Code and Codex, the permission request: Claude asks in its own window
    /// meanwhile, so its hook may wait a day; Codex waits for the hook, and the app hands it
    /// back after `handBackAfter`, as for Qwen Code. Qoder asks at the same time, like Claude.
    /// Progress events take five seconds at most; Qoder doesn't wait.
    var events: [Entry] {
        switch agent {
        case .claude: return [Entry(name: "PermissionRequest", timeout: 86_400, asks: true)]
        case .codex: return [Entry(name: "PermissionRequest", timeout: Self.waitingAskTimeout, asks: true)]
        case .qwen, .qoder:
            // Qwen Code reads a timeout of 1000 or more as milliseconds: these stay below.
            let observe = agent == .qoder
            var list = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "StopFailure", "SessionEnd"]
                .map { Entry(name: $0, timeout: 5, async: observe) }
            list += ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"]
                .map { Entry(name: $0, timeout: 5, async: observe, matcher: "*") }
            list.append(answers
                ? Entry(name: "PermissionRequest", timeout: agent.spec.waitsForHook ? Self.waitingAskTimeout : 86_400, asks: true, matcher: "*")
                : Entry(name: "PermissionRequest", timeout: 5, async: observe, matcher: "*"))
            return list
        case .cursor:
            return ["sessionStart", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure", "stop", "sessionEnd"]
                .map { Entry(name: $0, timeout: 5) }
        case .antigravity:
            // Its hooks are a plugin (AntigravityPlugin); no installer is made for it.
            return []
        }
    }

    /// The relay run as `verb` ("ask", "hook") for `agent`, with `arguments` after it. It prints
    /// what the relay prints, or nothing; it exits 0 even if the app was deleted (stdin is then
    /// drained so the agent never sees a broken pipe).
    static func hookCommand(relayPath: String, verb: String, agent: AgentProvider, arguments: [String] = []) -> String {
        ([quoted(relayPath), verb, agent.rawValue] + arguments).joined(separator: " ") + " 2>/dev/null || cat >/dev/null; exit 0"
    }

    /// Prints the answer given in the notch, or nothing.
    var command: String {
        Self.hookCommand(relayPath: relayPath, verb: "ask", agent: agent)
    }

    func command(for entry: Entry) -> String {
        entry.asks ? command : Self.hookCommand(relayPath: relayPath, verb: "hook", agent: agent, arguments: [entry.name])
    }

    /// Single-quoted for the shell, so spaces or quotes in the path stay literal.
    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An entry as the file holds it: Claude Code's group of handlers (Codex, Qwen Code and Qoder
    /// use it too), or Cursor's handler alone.
    func group(for entry: Entry) -> OrderedJSON {
        if layout == .handlers {
            return .object([.init(key: "command", value: .string(command(for: entry))),
                            .init(key: "timeout", value: .number(String(entry.timeout)))])
        }
        var handler: [OrderedJSON.Member] = [
            .init(key: "type", value: .string("command")),
            .init(key: "command", value: .string(command(for: entry))),
            .init(key: "timeout", value: .number(String(entry.timeout))),
        ]
        if entry.async { handler.append(.init(key: "async", value: .bool(true))) }
        var members: [OrderedJSON.Member] = []
        if let matcher = entry.matcher { members.append(.init(key: "matcher", value: .string(matcher))) }
        members.append(.init(key: "hooks", value: .array([.object(handler)])))
        return .object(members)
    }

    func isOwned(_ handler: OrderedJSON) -> Bool {
        guard let command = handler["command"]?.stringValue else { return false }
        return command.contains(RelayLink.helperName)
            && (command.contains(" hook \(agent.rawValue)") || command.contains(" ask \(agent.rawValue)"))
    }

    /// A group with an entry of ours. Codex keys its approvals by group, so there only a group
    /// that's all ours counts; elsewhere another app may have added its handler to ours.
    private func holdsOwned(_ group: OrderedJSON) -> Bool {
        switch layout {
        case .handlers:
            return isOwned(group)
        case .groups, .pinnedGroups:
            guard let handlers = group["hooks"]?.arrayValue, !handlers.isEmpty else { return false }
            return layout == .pinnedGroups ? handlers.allSatisfy(isOwned) : handlers.contains(where: isOwned)
        }
    }

    /// The groups with our entries taken out, and any group they leave empty (not for Codex).
    private func withoutOwned(_ groups: [OrderedJSON]) -> [OrderedJSON] {
        groups.compactMap { group in
            if layout == .handlers { return isOwned(group) ? nil : group }
            guard var handlers = group["hooks"]?.arrayValue, handlers.contains(where: isOwned) else { return group }
            handlers.removeAll(where: isOwned)
            guard !handlers.isEmpty else { return nil }
            var kept = group
            kept["hooks"] = .array(handlers)
            return kept
        }
    }

    func answersInNotch() -> Bool {
        guard case .loaded(let root, _) = load(), let groups = root["hooks"]?["PermissionRequest"]?.arrayValue else { return false }
        return groups.flatMap { $0["hooks"]?.arrayValue ?? [$0] }
            .contains { isOwned($0) && $0["command"]?.stringValue?.contains(" ask \(agent.rawValue)") == true }
    }

    // MARK: Status

    func status() -> Status {
        let root: OrderedJSON
        switch load() {
        case .missing: return .notInstalled
        case .invalid(let reason): return .unreadable(reason)
        case .loaded(let value, _): root = value
        }
        var found = 0
        var current = 0
        guard case .object(let members)? = root["hooks"] else { return .notInstalled }
        for member in members {
            for group in member.value.arrayValue ?? [] where holdsOwned(group) {
                found += 1
                if let event = events.first(where: { $0.name == member.key }), group == self.group(for: event) { current += 1 }
            }
        }
        if found == 0 { return .notInstalled }
        return current == events.count && found == events.count ? .installed : .outdated
    }

    func currentCount() -> Int {
        guard case .loaded(let root, _) = load(), case .object(let members)? = root["hooks"] else { return 0 }
        return members.reduce(0) { total, member in
            guard let event = events.first(where: { $0.name == member.key }) else { return total }
            return total + (member.value.arrayValue ?? []).filter { holdsOwned($0) && $0 == group(for: event) }.count
        }
    }

    /// Other apps' command hooks that can answer a PermissionRequest (not async):
    /// the program each runs, by name.
    func foreignAnswerers() -> [String] {
        guard case .loaded(let root, _) = load(), let groups = root["hooks"]?["PermissionRequest"]?.arrayValue else { return [] }
        return groups.flatMap { $0["hooks"]?.arrayValue ?? [] }
            .filter { !isOwned($0) && $0["async"] != .bool(true) }
            .compactMap { $0["command"]?.stringValue.map(Self.programName) }
    }

    /// "/bin/sh -c '[ -x \"$HOME/.x/bin/tool\" ] && …'" → "tool": the last
    /// path-like word that isn't a shell.
    static func programName(in command: String) -> String {
        let words = command.split(whereSeparator: { " '\";&|()[]".contains($0) }).map(String.init)
        let paths = words.filter { $0.contains("/") && !$0.hasPrefix("/bin/") && !$0.hasPrefix("/usr/bin/") }
        let name = (paths.first ?? words.first ?? command) as NSString
        return Relay.label(name.lastPathComponent, maxLength: 60) ?? "?"
    }

    /// How many of our entries the file holds (legacy ones too), or only those for `event`.
    func ownedCount(in event: String? = nil) -> Int {
        guard case .loaded(let root, _) = load(), case .object(let members)? = root["hooks"] else { return 0 }
        return members.filter { event == nil || $0.key == event }
            .reduce(0) { $0 + ($1.value.arrayValue ?? []).filter(holdsOwned).count }
    }

    // MARK: Install / uninstall

    /// What a removal leaves in a Codex slot, so later groups keep their index.
    private static let placeholder: OrderedJSON = .object([.init(key: "hooks", value: .array([]))])

    /// Adds or refreshes our entries and removes ours for unused events. Groups keep their
    /// positions (Codex keys approvals by index); new ones reuse a freed slot or go last.
    @discardableResult
    func install() throws -> URL? { try install(backupDirectory: Self.backupDirectory) }

    @discardableResult
    func install(backupDirectory: URL) throws -> URL? {
        try modify(backupDirectory: backupDirectory) { root in
            removeOwned(from: &root, keeping: Set(events.map(\.name)))
            // Cursor's file says which version of it it is.
            if layout == .handlers, root["version"] == nil { root["version"] = .number("1") }
            var hooks = root["hooks"] ?? .object([])
            for event in events {
                var groups = hooks[event.name]?.arrayValue ?? []
                let ours = group(for: event)
                if layout != .pinnedGroups {
                    // Ours alone, once, after everyone else's.
                    if groups.filter(holdsOwned) != [ours] { groups = withoutOwned(groups) + [ours] }
                } else if let index = groups.firstIndex(where: holdsOwned) {
                    groups[index] = ours
                    // Duplicates beyond the first become placeholders, so the groups
                    // after them keep their index.
                    for other in groups.indices where other != index && holdsOwned(groups[other]) {
                        groups[other] = Self.placeholder
                    }
                } else if let slot = groups.firstIndex(of: Self.placeholder) {
                    groups[slot] = ours
                } else {
                    groups.append(ours)
                }
                hooks[event.name] = .array(groups)
            }
            root["hooks"] = hooks
        }
    }

    /// Removes only our entries; a Codex group that others follow becomes `placeholder`.
    @discardableResult
    func uninstall() throws -> URL? { try uninstall(backupDirectory: Self.backupDirectory) }

    @discardableResult
    func uninstall(backupDirectory: URL) throws -> URL? {
        if case .missing = load() { return nil }
        return try modify(backupDirectory: backupDirectory) { removeOwned(from: &$0, keeping: []) }
    }

    private func removeOwned(from root: inout OrderedJSON, keeping kept: Set<String>) {
        guard var hooks = root["hooks"], case .object(let members) = hooks,
              members.contains(where: { !kept.contains($0.key) && $0.value.arrayValue?.contains(where: holdsOwned) == true })
        else { return }
        for member in members where !kept.contains(member.key) {
            guard var groups = member.value.arrayValue, groups.contains(where: holdsOwned) else { continue }
            if layout != .pinnedGroups {
                groups = withoutOwned(groups)
            } else {
                for index in groups.indices.reversed() where holdsOwned(groups[index]) {
                    if index < groups.count - 1 { groups[index] = Self.placeholder } else { groups.remove(at: index) }
                }
            }
            hooks[member.key] = groups.isEmpty ? nil : .array(groups)
        }
        if case .object(let left) = hooks, left.isEmpty, layout != .pinnedGroups {
            root["hooks"] = nil
        } else {
            root["hooks"] = hooks
        }
    }

    // MARK: Claude status line (plan-usage feed)

    enum StatusLineState: Equatable {
        case notInstalled, installed, outdated
        case foreign
        case unreadable(String)
    }

    var statusLineCommand: String {
        "\(Self.quoted(relayPath)) statusline 2>/dev/null || cat >/dev/null"
    }

    private var statusLineValue: OrderedJSON {
        .object([.init(key: "type", value: .string("command")),
                 .init(key: "command", value: .string(statusLineCommand)),
                 .init(key: "padding", value: .number("0"))])
    }

    private func statusLineIsOwned(_ value: OrderedJSON?) -> Bool {
        guard let command = value?["command"]?.stringValue else { return false }
        return command.contains(RelayLink.helperName) && command.contains(" statusline")
    }

    func statusLineState() -> StatusLineState {
        switch load() {
        case .missing: return .notInstalled
        case .invalid(let reason): return .unreadable(reason)
        case .loaded(let root, _):
            guard let current = root["statusLine"] else { return .notInstalled }
            guard statusLineIsOwned(current) else { return .foreign }
            return current == statusLineValue ? .installed : .outdated
        }
    }

    /// Never replaces a status line the user configured themselves.
    @discardableResult
    func installStatusLine() throws -> URL? {
        guard agent == .claude, statusLineState() != .foreign else { return nil }
        return try modify(backupDirectory: Self.backupDirectory) { root in root["statusLine"] = statusLineValue }
    }

    @discardableResult
    func uninstallStatusLine() throws -> URL? {
        guard agent == .claude else { return nil }
        if case .missing = load() { return nil }
        return try modify(backupDirectory: Self.backupDirectory) { root in
            if statusLineIsOwned(root["statusLine"]) { root["statusLine"] = nil }
        }
    }

    // MARK: File handling

    static var backupDirectory: URL { Relay.supportDirectory.appendingPathComponent("backups", isDirectory: true) }

    private enum Loaded {
        case missing
        case invalid(String)
        case loaded(OrderedJSON, Data)
    }

    private var targetURL: URL { configURL.resolvingSymlinksInPath() }

    private func load() -> Loaded {
        guard let data = try? Data(contentsOf: targetURL) else {
            return FileManager.default.fileExists(atPath: targetURL.path) ? .invalid(String(localized: "not readable")) : .missing
        }
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .loaded(.object([]), data) }
        do {
            let value = try OrderedJSON.parse(data)
            guard case .object = value else { return .invalid(String(localized: "not a JSON object")) }
            return .loaded(value, data)
        } catch {
            return .invalid(String(localized: "invalid JSON"))
        }
    }

    private func modify(backupDirectory: URL, _ change: (inout OrderedJSON) -> Void) throws -> URL? {
        // The preview copy leaves your own agents' settings alone; a sample home's are its to change.
        if Relay.isPreviewCopy, configURL.path.hasPrefix(Relay.homeDirectory + "/") { throw InstallError.previewCopy }
        var root: OrderedJSON
        var original: Data?
        switch load() {
        case .invalid(let reason): throw InstallError.unreadable(reason)
        case .missing: root = .object([])
        case .loaded(let value, let data): root = value; original = data
        }
        let before = root
        change(&root)
        guard root != before else { return nil }

        let fm = FileManager.default
        let target = targetURL
        var backup: URL?
        if let original {
            backup = try writeBackup(original, to: backupDirectory)
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let permissions = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber

        // Refuse to clobber a concurrent edit by the agent itself.
        let current = try? Data(contentsOf: target)
        guard current == original else { throw InstallError.changedWhileWriting }

        let output = root.serialized()
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).underbrim-\(UUID().uuidString)")
        // Created with the original's mode, so a private (0600) settings file
        // never has a readable copy, not even briefly.
        let mode = mode_t(truncatingIfNeeded: permissions?.intValue ?? 0o644)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            fchmod(fd, mode)  // exactly the original's, whatever the umask
            try handle.write(contentsOf: output)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, target.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        // A mismatch means another program wrote the file just now: leave its
        // version (the backup holds the one before ours).
        guard let reread = try? Data(contentsOf: target), (try? OrderedJSON.parse(reread)) == root else {
            throw InstallError.verificationFailed
        }
        return backup
    }

    private func writeBackup(_ data: Data, to directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]  // two changes in one second
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("\(agent.rawValue)-\(configURL.lastPathComponent)-\(stamp).bak")
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Keep the ten newest backups per agent.
        let prefix = "\(agent.rawValue)-"
        Relay.removeEntries(in: directory) { Set($0.map(\.name).filter { $0.hasPrefix(prefix) }.sorted().dropLast(10)) }
        return url
    }
}
