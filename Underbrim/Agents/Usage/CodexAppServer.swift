//
//  CodexAppServer.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Client for the local `codex app-server` (newline-delimited JSON-RPC over stdio, no
//  "jsonrpc" field). Each call starts a short-lived process (an idle server holds ~100 MB),
//  reads the rate limits or only the hooks' trust state, then closes stdin. Its one write
//  trusts Underbrim's own hook when the user switches answering on, as Codex's /hooks review
//  does; it never refreshes tokens on purpose, redeems credits, or logs in or out.
//

import AppKit
import Foundation
import os

enum CodexAppServer {
    struct Account: Equatable {
        /// "chatgpt", "apiKey", "amazonBedrock"…
        var type: String
        var email: String?
        var plan: String?
    }

    struct Window: Equatable {
        var limitName: String?
        var usedPercent: Double
        var windowMinutes: Int?
        var resetsAt: Date?
    }

    struct HookTrust: Equatable {
        var event: String
        var trustStatus: String
        var enabled: Bool
        /// Codex's name for the hook ("<hooks.json>:permission_request:<group>:<handler>").
        var key: String?
        var currentHash: String?
    }

    enum Mode { case usage, hooks, trustOwnHooks }

    struct Result: Equatable {
        var account: Account?
        var windows: [Window]
        var hooks: [HookTrust]?
        var rateLimitError: String?
    }

    enum Failure: Error, Equatable {
        case notInstalled
        case launch(String)
        case timeout
        case server(String)
        case notSignedByOpenAI
    }

    /// The Codex app's bundled CLI first, then common installs, only if signed by OpenAI (it runs
    /// with Underbrim's privacy permissions); links resolved, so the checked file is what runs.
    static func locateBinary() throws -> URL {
        var candidates: [String] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentProvider.codex.defaultHostBundleID) {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path)
        }
        let home = Relay.homeDirectory
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
        ]
        let found = candidates.filter(FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
        if let signed = found.first(where: { CodeSignature.satisfies($0, requirement: CodeSignature.openAI) }) { return signed }
        throw found.isEmpty ? Failure.notInstalled : Failure.notSignedByOpenAI
    }

    /// `hooksOnly`: just the hooks' trust state, so checking the approval hook
    /// doesn't ask OpenAI for plan usage the user hasn't turned on.
    static func fetch(hooksOnly: Bool) async throws -> Result {
        try await call(hooksOnly ? .hooks : .usage)
    }

    /// Trusts Underbrim's own hooks (only those running its relay), then reads the state back.
    static func trustOwnHooks() async throws -> Result {
        try await call(.trustOwnHooks)
    }

    private static func call(_ mode: Mode) async throws -> Result {
        let binary = try locateBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        process.environment = Process.cleanEnvironment(keeping: ["CODEX_HOME", "SSL_CERT_FILE", "HTTPS_PROXY", "HTTP_PROXY",
                                                                 "NO_PROXY", "https_proxy", "http_proxy", "no_proxy"])
        process.currentDirectoryURL = URL(fileURLWithPath: Relay.homeDirectory)
        let input = Pipe()
        let output = Pipe()
        // If codex dies mid-exchange, a write must fail, not SIGPIPE the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // Lines are delivered as soon as they arrive: FileHandle.bytes waits for more data before
        // yielding a short line, which deadlocks a request/response exchange.
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            guard let lines = buffer.append(chunk) else {
                // A reply this long isn't one we asked for: stop reading, and the call fails.
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in lines { continuation.yield(line) }
        }
        do { try process.run() } catch { throw Failure.launch(error.localizedDescription) }

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            continuation.finish()
            if process.isRunning { process.terminate() }
        }
        defer {
            watchdog.cancel()
            output.fileHandleForReading.readabilityHandler = nil
            // Closing stdin ends the server; don't let a stuck one linger.
            try? input.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
        }

        do {
            return try await Session(writer: input.fileHandleForWriting).run(lines: lines, mode: mode)
        } catch {
            throw timedOut.withLock { $0 } ? Failure.timeout : error
        }
    }

    /// Its replies are small (an account, rate limits, a hook list).
    static let maxLineBytes = 4 << 20

    private final class LineBuffer: @unchecked Sendable {
        private var splitter = LineSplitter(maxLine: CodexAppServer.maxLineBytes)
        /// readabilityHandler calls are serialized, so no lock is needed. nil: a line ran past the limit.
        func append(_ chunk: Data) -> [String]? {
            let lines = splitter.append(chunk)
            guard !splitter.overflowed else { return nil }
            return lines.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// Drives one request/response exchange. Responses can arrive out of
    /// order, so they're matched by id.
    private final class Session: @unchecked Sendable {
        let writer: FileHandle
        init(writer: FileHandle) { self.writer = writer }

        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            try? writer.write(contentsOf: data)
        }

        func run(lines: AsyncStream<String>, mode: Mode) async throws -> Result {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
            send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "underbrim", "title": "Underbrim", "version": version],
                "capabilities": ["experimentalApi": false, "explicitGatewayOauth": true],
            ]])
            var pending: Set<Int> = [1]
            var responses: [Int: [String: Any]] = [:]

            for await line in lines {
                guard let data = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if message["method"] != nil, let id = message["id"] {
                    // A request from the server (approval, token refresh…): we never act on those.
                    send(["id": id, "error": ["code": -32601, "message": "not supported by this client"]])
                    continue
                }
                guard let id = message["id"] as? Int, pending.remove(id) != nil else { continue }
                responses[id] = message
                // Ours, not yet trusted: trust each at the hash Codex shows, then list again.
                if id == 4, mode == .trustOwnHooks {
                    let untrusted = (CodexAppServer.parse(account: nil, limits: nil, hooks: message).hooks ?? [])
                        .filter { $0.trustStatus != "trusted" && $0.trustStatus != "managed" }
                    var state: [String: Any] = [:]
                    for hook in untrusted {
                        if let key = hook.key, let hash = hook.currentHash { state[key] = ["trusted_hash": hash] }
                    }
                    if !state.isEmpty {
                        send(["id": 5, "method": "config/value/write",
                              "params": ["keyPath": "hooks.state", "mergeStrategy": "upsert", "value": state]])
                        pending.insert(5)
                    }
                }
                if id == 5 {
                    if let error = message["error"] as? [String: Any] {
                        throw Failure.server(error["message"] as? String ?? "config write failed")
                    }
                    send(["id": 6, "method": "hooks/list", "params": ["cwds": [Relay.homeDirectory]]])
                    pending.insert(6)
                }
                if id == 1 {
                    if let error = message["error"] as? [String: Any] {
                        throw Failure.server(error["message"] as? String ?? "initialize failed")
                    }
                    send(["method": "initialized"])
                    if mode != .usage {
                        send(["id": 4, "method": "hooks/list", "params": ["cwds": [Relay.homeDirectory]]])
                        pending.insert(4)
                    } else {
                        send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                        send(["id": 3, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
                        pending.formUnion([2, 3])
                    }
                }
                if pending.isEmpty { break }
            }
            guard pending.isEmpty else { throw Failure.server("app-server closed early") }
            return CodexAppServer.parse(account: responses[2], limits: responses[3], hooks: responses[6] ?? responses[4])
        }
    }

    // MARK: Parsing (lenient: unknown fields ignored, newer shapes tolerated)

    static func parse(account: [String: Any]?, limits: [String: Any]?, hooks: [String: Any]?) -> Result {
        var result = Result(account: nil, windows: [], hooks: nil, rateLimitError: nil)

        if let accountObject = (account?["result"] as? [String: Any])?["account"] as? [String: Any],
           let type = accountObject["type"] as? String {
            result.account = Account(type: type, email: Relay.label(accountObject["email"]), plan: Relay.label(accountObject["planType"], maxLength: 40))
        }

        if let error = limits?["error"] as? [String: Any] {
            result.rateLimitError = error["message"] as? String ?? "rate limits unavailable"
        } else if let body = limits?["result"] as? [String: Any] {
            var snapshots: [[String: Any]] = []
            if let byID = body["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
                snapshots = byID.keys.sorted().compactMap { byID[$0] as? [String: Any] }
            } else if let single = body["rateLimits"] as? [String: Any] {
                snapshots = [single]
            }
            for snapshot in snapshots {
                let limitID = snapshot["limitId"] as? String
                let name = Relay.label(snapshot["limitName"], maxLength: 40) ?? (limitID == "codex" ? nil : Relay.label(limitID, maxLength: 40))
                for key in ["primary", "secondary"] {
                    // A share of the limit: anything else isn't one, and isn't shown.
                    guard let window = snapshot[key] as? [String: Any],
                          let used = (window["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
                    let resets = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    result.windows.append(Window(limitName: name, usedPercent: min(max(used, 0), 100),
                                                 windowMinutes: (window["windowDurationMins"] as? NSNumber)?.intValue,
                                                 resetsAt: resets))
                }
                if result.account?.plan == nil, let plan = Relay.label(snapshot["planType"], maxLength: 40) {
                    result.account?.plan = plan
                }
            }
        }

        if let data = (hooks?["result"] as? [String: Any])?["data"] as? [[String: Any]] {
            result.hooks = data.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { hook in
                guard let command = hook["command"] as? String, command.contains(RelayLink.helperName),
                      command.contains(" hook codex") || command.contains(" ask codex") else { return nil }
                return HookTrust(event: hook["eventName"] as? String ?? "?",
                                 trustStatus: hook["trustStatus"] as? String ?? "unknown",
                                 enabled: hook["enabled"] as? Bool ?? true,
                                 key: hook["key"] as? String, currentHash: hook["currentHash"] as? String)
            }
        }
        return result
    }

    /// "5-hour", "Weekly", "Daily" — derived from the window length.
    static func label(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return String(localized: "Usage") }
        switch minutes {
        case 10080: return String(localized: "Weekly")
        case 1440: return String(localized: "Daily")
        case let m where m % 1440 == 0: return String(localized: "\(m / 1440)-day")
        case let m where m % 60 == 0: return String(localized: "\(m / 60)-hour")
        default: return String(localized: "\(minutes)-minute")
        }
    }
}
