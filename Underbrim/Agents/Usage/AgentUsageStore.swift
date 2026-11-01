//
//  AgentUsageStore.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Plan usage for the two agents, from read-only sources: Codex's local `codex
//  app-server`, and Claude Code's documented status-line `rate_limits` (opt-in) plus the
//  readings Claude Desktop saves (labelled unofficial). No Claude credentials are read:
//  Anthropic's terms don't allow other apps to use Claude.ai logins. Values are never
//  inferred: missing windows are absent, a passed reset shows "—", old data reads stale, and
//  a stale reading without reset times shows no number.
//

import AppKit
import Defaults
import Foundation
import Observation
import os

@MainActor
@Observable
final class AgentUsageStore {
    static let shared = AgentUsageStore()

    struct Window: Equatable, Identifiable {
        var id: String
        var label: String
        /// Percent of the window used, 0–100. nil once the window has reset
        /// and no newer reading has arrived.
        var usedPercent: Double?
        var resetsAt: Date?
        /// Without a reset time: when this reading can no longer be taken for the
        /// current window, as it may have reset any time since.
        var expiresAt: Date?
    }

    struct Snapshot: Equatable {
        var plan: String?
        /// Account email — shown in Settings for verification, not in the notch.
        var account: String?
        var windows: [Window]
        var fetchedAt: Date
        var source: String
        /// Age after which the reading is marked stale (per source).
        var staleAfter: TimeInterval = AgentUsageStore.staleAfter
    }

    enum State: Equatable {
        case off
        case loading
        case loaded(Snapshot)
        case failed(String, last: Snapshot?)

        var snapshot: Snapshot? {
            switch self {
            case .off, .loading: nil
            case .failed(_, let last): last
            case .loaded(let snapshot): snapshot
            }
        }
    }

    private(set) var codex: State = .off {
        didSet { if codex.snapshot != oldValue.snapshot { UsageWarnings.shared.check(.codex, snapshot: codex.snapshot) } }
    }
    private(set) var claude: State = .off {
        didSet { if claude.snapshot != oldValue.snapshot { UsageWarnings.shared.check(.claude, snapshot: claude.snapshot) } }
    }

    /// The plan usage shown for an agent; only Claude Code and Codex report one.
    func state(for provider: AgentProvider) -> State {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .qwen, .qoder, .cursor, .antigravity: .off
        }
    }

    static let refreshInterval: TimeInterval = 5 * 60
    nonisolated static let staleAfter: TimeInterval = 15 * 60
    /// Claude's sources update less predictably (the Claude app checks about
    /// every 15 minutes while it's checking at all).
    nonisolated static let claudeStaleAfter: TimeInterval = 30 * 60

    @ObservationIgnored private var codexTimer: Task<Void, Never>?
    private(set) var codexInFlight = false
    @ObservationIgnored private var codexFailures = 0
    @ObservationIgnored private var lastCodexAttempt: Date?
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusLineWindows: [String: Window] = [:]
    @ObservationIgnored private var statusLineAt: Date?
    @ObservationIgnored private var cacheWatcher: DispatchSourceFileSystemObject?
    /// Last parse of the Claude app's cache; re-read only when the file changes.
    @ObservationIgnored private var desktopCache: Snapshot?
    @ObservationIgnored private let log = Logger(subsystem: bundleIdentifier, category: "agents")

    nonisolated static let claudeDesktopCacheURL = AgentFiles.home
        .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")

    // MARK: Lifecycle

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(false) }
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(false) }
        })
        Defaults.whenChanged([.codexUsageEnabled, .readClaudeDesktopUsage, .claudeStatusLineFeed]) { [weak self] in self?.applySettings() }
        applySettings()
    }

    func applySettings() {
        if Defaults[.codexUsageEnabled] {
            // Only when just turned on: other switches land here too.
            if codex == .off {
                codex = .loading
                scheduleCodex(after: 0)
            }
        } else {
            codexTimer?.cancel()
            codex = .off
        }
        if Defaults[.readClaudeDesktopUsage] {
            watchClaudeDesktopCache()
            reloadClaudeDesktopCache()
        } else {
            cacheWatcher?.cancel()
            cacheWatcher = nil
            desktopCache = nil
        }
        // A source switched off takes its last reading with it.
        if !Defaults[.claudeStatusLineFeed] {
            statusLineWindows = [:]
            statusLineAt = nil
        }
        publishClaude()
    }

    private func setPaused(_ value: Bool) {
        paused = value
        guard !value, Defaults[.codexUsageEnabled] else { return }
        // Back from sleep/lock: refresh if the last reading is due.
        let due = lastCodexAttempt.map { Date().timeIntervalSince($0) >= Self.refreshInterval } ?? true
        if due { scheduleCodex(after: 2) }
    }

    // MARK: Codex

    /// A click always refreshes; the automatic ones wait two minutes.
    func refreshCodex(userInitiated: Bool) {
        guard Defaults[.codexUsageEnabled], !codexInFlight else { return }
        if !userInitiated, let last = lastCodexAttempt, Date().timeIntervalSince(last) < 120 { return }
        scheduleCodex(after: 0)
    }

    private func scheduleCodex(after delay: TimeInterval) {
        // A fetch in flight schedules the next one itself; cancelling it here
        // would count as a failure and back off.
        guard !codexInFlight else { return }
        codexTimer?.cancel()
        codexTimer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.fetchCodex()
        }
    }

    private func fetchCodex() async {
        guard Defaults[.codexUsageEnabled], !paused, !codexInFlight else { return }
        codexInFlight = true
        lastCodexAttempt = Date()
        let last = codex.snapshot
        if case .failed = codex {} else if last == nil { codex = .loading }
        let outcome: State
        do {
            let result = try await CodexAppServer.fetch(hooksOnly: false)
            if let error = result.rateLimitError {
                outcome = .failed(Self.describeCodexError(error, account: result.account), last: last)
            } else {
                // Known by their limit and length, not their place in the list: a warning stays with its limit.
                var seen: [String: Int] = [:]
                let windows = result.windows.map { window in
                    let base = CodexAppServer.label(minutes: window.windowMinutes)
                    let key = "\(window.limitName ?? "codex")/\(window.windowMinutes.map(String.init) ?? "-")"
                    seen[key, default: 0] += 1
                    return Window(id: seen[key] == 1 ? key : "\(key)#\(seen[key] ?? 0)",
                                  label: window.limitName.map { "\($0) · \(base)" } ?? base,
                                  usedPercent: window.usedPercent, resetsAt: window.resetsAt)
                }
                outcome = .loaded(Snapshot(plan: result.account?.plan.map(Self.planName), account: result.account?.email,
                                           windows: windows, fetchedAt: Date(), source: String(localized: "Codex app-server")))
            }
        } catch CodexAppServer.Failure.notInstalled {
            outcome = .failed(String(localized: "Codex isn't installed"), last: last)
        } catch CodexAppServer.Failure.notSignedByOpenAI {
            outcome = .failed(String(localized: "Codex isn't signed by OpenAI"), last: last)
        } catch CodexAppServer.Failure.timeout {
            outcome = .failed(String(localized: "Codex didn't answer in time"), last: last)
        } catch {
            outcome = .failed(String(localized: "Couldn't read Codex usage"), last: last)
        }
        codexInFlight = false
        // Turned off meanwhile (which cancels this task): keep "off". If it was
        // turned back on before this one finished, that request waited for us.
        guard !Task.isCancelled, Defaults[.codexUsageEnabled] else {
            if Defaults[.codexUsageEnabled] { scheduleCodex(after: 0) }
            return
        }
        codex = outcome
        switch outcome {
        case .loaded(let snapshot):
            codexFailures = 0
            log.debug("codex usage: \(snapshot.windows.count) window(s) plan=\(snapshot.plan ?? "-", privacy: .public) labels=\(snapshot.windows.map(\.label).joined(separator: ","), privacy: .public)")
        case .failed(let message, _):
            codexFailures += 1
            log.debug("codex usage failed: \(message, privacy: .public)")
        default: break
        }
        // Next regular refresh; back off exponentially after errors (max 1 h).
        let backoff = min(3600, Self.refreshInterval * pow(2, Double(max(0, codexFailures - 1))))
        scheduleCodex(after: codexFailures == 0 ? Self.refreshInterval : backoff)
    }

    nonisolated static func describeCodexError(_ message: String, account: CodexAppServer.Account?) -> String {
        if message.localizedCaseInsensitiveContains("authentication required") {
            return account?.type == "apiKey"
                ? String(localized: "API key in use · no plan limits")  // short: the usage row has one line
                : String(localized: "Sign in to Codex to see usage")
        }
        return String(localized: "Codex usage unavailable")
    }

    nonisolated static func planName(_ raw: String) -> String {
        switch raw {
        case "prolite": "Pro Lite"
        case "promax": "Pro Max"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Claude

    /// A status-line reading from any terminal session. Per window the newest reset wins, then
    /// the higher percentage, so an idle session's older numbers can't overwrite fresher ones.
    func applyClaudeStatusLine(windows: [RelayWindow], at date: Date) {
        // A status line still sending after its source was switched off.
        guard Defaults[.claudeStatusLineFeed] else { return }
        for window in windows {
            let resets = window.resets.map { Date(timeIntervalSince1970: $0) }
            let incoming = Window(id: window.id, label: Self.claudeLabel(window.id), usedPercent: window.used, resetsAt: resets)
            if let existing = statusLineWindows[window.id] {
                let newerReset = (resets ?? .distantPast) > (existing.resetsAt ?? .distantPast)
                let sameReset = resets == existing.resetsAt
                guard newerReset || (sameReset && window.used >= (existing.usedPercent ?? 0)) else { continue }
            }
            statusLineWindows[window.id] = incoming
        }
        statusLineAt = date
        publishClaude()
    }

    nonisolated static func claudeLabel(_ id: String) -> String {
        switch id {
        case "five_hour", "fh": String(localized: "5-hour")
        case "seven_day", "sd": String(localized: "Weekly")
        default: id
        }
    }

    private func publishClaude() {
        let now = Date()
        var candidates: [Snapshot] = []
        if let at = statusLineAt, !statusLineWindows.isEmpty {
            let windows = ["five_hour", "seven_day"].compactMap { statusLineWindows[$0] }.map { window in
                var window = window
                if let reset = window.resetsAt, reset <= now { window.usedPercent = nil }
                return window
            }
            candidates.append(Snapshot(windows: windows, fetchedAt: at, source: String(localized: "Claude Code status line"),
                                       staleAfter: Self.claudeStaleAfter))
        }
        if Defaults[.readClaudeDesktopUsage], let desktopCache {
            candidates.append(desktopCache)
        }
        if let newest = candidates.max(by: { $0.fetchedAt < $1.fetchedAt }) {
            claude = .loaded(newest)
        } else if Defaults[.readClaudeDesktopUsage] || Defaults[.claudeStatusLineFeed] {
            claude = .failed(String(localized: "No reading yet"), last: nil)
        } else {
            claude = .off
        }
    }

    /// `{ version: 2, samples: [{ t: ms, org, u: { fh, sd } }] }` — integer
    /// percentages, no reset times. The Claude app appends a sample each time
    /// it checks usage. Undocumented: any other shape is ignored.
    nonisolated static func readClaudeDesktopCache(at url: URL = claudeDesktopCacheURL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 2,
              let last = (object["samples"] as? [[String: Any]])?.last,
              let ms = (last["t"] as? NSNumber)?.doubleValue,
              let usage = last["u"] as? [String: Any] else { return nil }
        // One from the future (a clock that was ahead, or a wrong value) has no age to go by, and taken
        // as now it would look fresh each time it's read: it's left out. A minute covers clock drift.
        let stamped = Date(timeIntervalSince1970: ms / 1000)
        guard stamped.timeIntervalSinceNow < 60 else { return nil }
        let taken = min(stamped, Date())
        // With no reset times, a window may have reset any time after the sample, so its number stands for
        // now only while the sample is fresh (the Claude app samples about every 15 minutes while it does).
        let windows = ["fh", "sd"].compactMap { key -> Window? in
            guard let value = (usage[key] as? NSNumber)?.doubleValue, (0...100).contains(value) else { return nil }
            return Window(id: key, label: claudeLabel(key), usedPercent: value, resetsAt: nil,
                          expiresAt: taken.addingTimeInterval(claudeStaleAfter))
        }
        guard !windows.isEmpty else { return nil }
        return Snapshot(windows: windows, fetchedAt: taken,
                        source: String(localized: "From the Claude app on this Mac (unofficial). It updates when the Claude app checks your usage."),
                        staleAfter: claudeStaleAfter)
    }

    private func reloadClaudeDesktopCache() {
        Task {
            let snapshot = await Task.detached(priority: .utility) { Self.readClaudeDesktopCache() }.value
            guard Defaults[.readClaudeDesktopUsage] else { return }
            desktopCache = snapshot
            publishClaude()
        }
    }

    /// Re-reads when Claude Desktop rewrites the file; no polling. Until the
    /// file exists, the nearest folder above it that does is watched for it.
    private func watchClaudeDesktopCache() {
        cacheWatcher?.cancel()
        var watched = Self.claudeDesktopCacheURL
        var fd = open(watched.path, O_EVTONLY)
        while fd < 0, watched.pathComponents.count > 1 {
            watched.deleteLastPathComponent()
            fd = open(watched.path, O_EVTONLY)
        }
        guard fd >= 0 else { return }
        let folder = watched != Self.claudeDesktopCacheURL
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let replaced = folder || !source.data.isDisjoint(with: [.rename, .delete])
                self.reloadClaudeDesktopCache()
                // Atomic rewrites replace the file, and a change in the folder
                // may be the file (or a folder on its way) appearing: watch again.
                if replaced {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        if Defaults[.readClaudeDesktopUsage] { self.watchClaudeDesktopCache(); self.reloadClaudeDesktopCache() }
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        cacheWatcher = source
        source.resume()
    }
}
