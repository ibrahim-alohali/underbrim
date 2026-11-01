//
//  AgentOpener.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Opens the exact session only where a link is known to work; otherwise brings
//  the hosting app forward and says so.
//  - Codex: `codex://threads/<id>` is documented; the log's session id is the
//    thread id. Only for threads in the Codex app, not a terminal or an editor.
//  - Claude Desktop: `claude://code/continue?session=local_…` is undocumented (the
//    app builds it for its Spotlight results), so Settings can turn it off.
//  - Terminal and iTerm2: the agent's tab, found by tty and selected by AppleScript
//    (macOS asks once per terminal). Other terminals: the app is activated.
//  New sessions: `claude://code/new?folder=…` and `codex://threads/new?path=…`.
//  Links open in the app found by bundle ID; the web only without the app.
//

import AppKit
import Defaults

/// The apps agents run in besides their own.
enum AgentHostApps {
    /// Where an agent runs in a terminal tab: terminals, and editors with a terminal of their own.
    static let terminals = Set([
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty",
    ]).union(editors.keys)

    /// The terminals whose tabs can be picked by script.
    static let scriptableTerminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

    /// Editors, by the name a session's card gives them.
    static let editors: [String: String] = [
        "com.microsoft.VSCode": "VS Code", "com.todesktop.230313mzl4w4u92": "Cursor", "dev.zed.Zed": "Zed",
    ]
}

@MainActor
enum AgentOpener {
    enum Route: Equatable {
        case link(URL)
        case terminalTab(bundleID: String, tty: String)
        case activate(bundleID: String)
        case none
    }

    static func route(for session: AgentSession) -> Route {
        let inTerminal = session.hostBundleID.map(AgentHostApps.terminals.contains) ?? false
        switch session.provider {
        case .codex:
            let inCodexApp = session.hostBundleID.map { $0 == session.provider.defaultHostBundleID } ?? true
            if inCodexApp, let url = session.provider.sessionLink(id: session.sessionID) {
                return .link(url)
            }
        case .claude:
            if Defaults[.useClaudeDesktopSessionLinks], !inTerminal, let id = session.desktopSessionID,
               let url = session.provider.sessionLink(id: id) {
                return .link(url)
            }
        case .qwen, .qoder, .cursor, .antigravity:
            // No link to one session: its terminal tab, or the app comes forward.
            break
        }
        if let host = session.hostBundleID, AgentHostApps.scriptableTerminals.contains(host),
           let pid = session.agentPID, let tty = terminalDevice(of: pid) {
            return .terminalTab(bundleID: host, tty: tty)
        }
        if let host = session.hostBundleID { return .activate(bundleID: host) }
        if session.entrypoint?.hasPrefix("claude-desktop") == true || session.provider.runsInOwnApp {
            return .activate(bundleID: session.provider.defaultHostBundleID)
        }
        return .none
    }

    /// Spoken / shown before acting, so the user knows what a click does.
    static func actionDescription(for session: AgentSession) -> String {
        switch route(for: session) {
        case .link:
            return String(localized: "Opens this session in \(session.provider.appName)")
        case .terminalTab(let bundleID, _):
            let name = AppInfo.name(bundleID: bundleID) ?? String(localized: "the app")
            return String(localized: "Shows this session's tab in \(name)")
        case .activate(let bundleID):
            let name = AppInfo.name(bundleID: bundleID) ?? String(localized: "the app")
            return AgentHostApps.terminals.contains(bundleID)
                ? String(localized: "Brings \(name) to the front — the exact tab can't be selected")
                : String(localized: "Brings \(name) to the front")
        case .none:
            return String(localized: "The app running this session couldn't be identified")
        }
    }

    static func open(_ session: AgentSession) {
        switch route(for: session) {
        case .link(let url):
            open(url, with: session.provider)
        case .terminalTab(let bundleID, let tty):
            selectTab(in: bundleID, tty: tty)
        case .activate(let bundleID):
            AppInfo.activate(bundleID)
        case .none:
            NSSound.beep()
        }
    }

    // MARK: A terminal's tab

    nonisolated static func terminalDevice(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32.max,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR)
        else { return nil }
        let device = String(cString: name)
        return device.hasPrefix("tty") ? "/dev/" + device : nil
    }

    /// Selects the tab with the terminal's AppleScript, in osascript so the main thread
    /// never waits on macOS's permission prompt. The tty goes in as an argument, never
    /// into the script's text. Refused, or the tab is gone: the app comes forward.
    static func selectTab(in bundleID: String, tty: String) {
        guard let script = tabScript(for: bundleID) else { return AppInfo.activate(bundleID) }
        Task.detached(priority: .userInitiated) {
            if run(script, argument: tty)?.hasPrefix("ok") != true { await MainActor.run { AppInfo.activate(bundleID) } }
        }
    }

    nonisolated private static func run(_ script: String, argument: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + (argument.map { [$0] } ?? [])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Already in front

    /// Whether a session's own window is in front: its app, or its tab in the front window
    /// of Terminal or iTerm2 (asked only if macOS already allows scripting; never prompts).
    /// Other terminals and editors: not in front. Unknown permission or process: `ifUnknown`.
    static func isInFront(host: String?, provider: AgentProvider, agentPID: Int32?, ifUnknown: Bool = false) async -> Bool {
        if let known = inFrontNow(host: host, provider: provider) { return known }
        let host = host ?? provider.defaultHostBundleID
        guard let pid = agentPID, let script = selectedTabScript(for: host) else { return ifUnknown }
        return await Task.detached(priority: .userInitiated) {
            guard let tty = terminalDevice(of: pid), mayScript(host), let selected = run(script) else { return ifUnknown }
            return selected == tty
        }.value
    }

    /// The answer when no terminal needs asking; nil when one does.
    static func inFrontNow(host: String?, provider: AgentProvider) -> Bool? {
        let host = host ?? provider.defaultHostBundleID
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host else { return false }
        if !AgentHostApps.terminals.contains(host) { return true }
        return AgentHostApps.scriptableTerminals.contains(host) ? nil : false
    }

    nonisolated private static func mayScript(_ bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let id = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr
    }

    private static func selectedTabScript(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal": #"tell application id "com.apple.Terminal" to return tty of selected tab of front window"#
        case "com.googlecode.iterm2": #"tell application id "com.googlecode.iterm2" to return tty of current session of current window"#
        default: nil
        }
    }

    private static func tabScript(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal":
            return """
            on run argv
                set wanted to item 1 of argv
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is wanted then
                                if miniaturized of w then set miniaturized of w to false
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """
        case "com.googlecode.iterm2":
            return """
            on run argv
                set wanted to item 1 of argv
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is wanted then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                return "missing"
            end run
            """
        default:
            return nil
        }
    }

    // MARK: New sessions and folders

    static func newSessionURL(for provider: AgentProvider, folder: String? = nil) -> URL? {
        guard provider.readsFiles else { return nil }
        let base = provider == .codex ? "codex://threads/new" : "claude://code/new"
        guard let folder else { return URL(string: base) }
        // Both apps decode with URLSearchParams, where "+" means a space.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?")
        return folder.addingPercentEncoding(withAllowedCharacters: allowed)
            .flatMap { URL(string: "\(base)?\(provider == .codex ? "path" : "folder")=\($0)") }
    }

    /// The provider's app, found by bundle ID, opens its own links (not whatever
    /// else claims the scheme); a web page opens in the browser.
    static func open(_ url: URL, with provider: AgentProvider) {
        if url.scheme?.hasPrefix("http") != true,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.defaultHostBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()  // nothing on this Mac opens the link
        }
    }

    /// Cached for a minute: the list header asks on every redraw.
    private static var installed: [AgentProvider: (found: Bool, at: Date)] = [:]

    /// The agent's own app is on this Mac (not a command-line tool: see AgentSetupModel.isAvailable).
    static func hasApp(_ provider: AgentProvider) -> Bool {
        if let known = installed[provider], Date().timeIntervalSince(known.at) < 60 { return known.found }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.defaultHostBundleID) != nil
        installed[provider] = (found, Date())
        return found
    }

    static func startNewSession(_ provider: AgentProvider, folder: String? = nil) {
        guard let url = newSessionURL(for: provider, folder: folder) else { return NSSound.beep() }
        open(url, with: provider)
    }

    static func showInFinder(_ session: AgentSession) {
        guard let cwd = session.cwd else { return NSSound.beep() }
        showInFinder(path: cwd)
    }

    static func showInFinder(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return NSSound.beep() }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
