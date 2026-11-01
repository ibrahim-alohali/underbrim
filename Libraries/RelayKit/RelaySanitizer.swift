//
//  RelaySanitizer.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Reduces raw hook / native-messaging JSON to a `RelayEvent`. Only the
//  fields named here are read; everything else (prompts, tool inputs and
//  responses, transcript paths, messages) is dropped inside the helper.
//

import Foundation

enum RelaySanitizer {
    /// API error kinds Claude Code records when a turn stops on one.
    static let detailTokens: Set<String> = [
        "rate_limit", "overloaded", "authentication_failed", "oauth_org_not_allowed", "account_on_hold",
        "billing_error", "invalid_request", "model_not_found", "server_error", "max_output_tokens",
        "cloud_credential_error", "unknown",
    ]

    static let entrypoints: Set<String> = [
        "cli", "claude-desktop", "claude-desktop-3p", "claude-vscode", "sdk-ts", "sdk-py", "sdk-cli",
        "local-agent", "ssh-remote",
    ]

    /// Notification types worth a state, in Claude Code's words (Qwen Code and Qoder use them).
    static let notificationTokens: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog"]

    /// A hook's input → an event: session progress for the hook-only agents, or Codex's
    /// legacy approval hook. Anything else is dropped (those sessions come from files).
    static func hookEvent(
        provider: AgentProvider,
        event hookName: String?,
        input: Data,
        lineage: (agent: ProcessLineage.Info?, hostBundleID: String?)
    ) -> RelayEvent? {
        switch provider.spec.source {
        case .hooks, .plugin:
            return agentHookEvent(provider: provider, event: hookName, input: input, lineage: lineage)
        case .files:
            // Earlier versions' status hooks: only Codex's approval hook still says something.
            guard provider == .codex,
                  let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
                  object["hook_event_name"] as? String == "PermissionRequest"
            else { return nil }
            return legacyCodexApproval(object, lineage: lineage)
        }
    }

    private static func legacyCodexApproval(
        _ object: [String: Any],
        lineage: (agent: ProcessLineage.Info?, hostBundleID: String?)
    ) -> RelayEvent {
        RelayEvent(
            provider: AgentProvider.codex.rawValue,
            kind: "PermissionRequest",
            session: Relay.identifier(object["session_id"] ?? object["thread_id"]),
            cwd: Relay.path(object["cwd"]),
            tool: Relay.identifier(object["tool_name"], maxLength: 96),
            ts: Date().timeIntervalSince1970,
            pid: lineage.agent?.pid,
            pidStart: lineage.agent?.start,
            host: Relay.identifier(lineage.hostBundleID)
        )
    }

    /// A hook-only agent's hook → progress in Claude Code's event names. Reads only ids, the
    /// folder, the tool name and one allowlisted word; never prompts or tool input/output.
    private static func agentHookEvent(
        provider: AgentProvider,
        event hookName: String?,
        input: Data,
        lineage: (agent: ProcessLineage.Info?, hostBundleID: String?)
    ) -> RelayEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let name = hookName ?? object["hook_event_name"] as? String
        else { return nil }
        var detail: String?
        let kind: String
        switch provider {
        case .cursor:
            switch name {
            case "sessionStart": kind = "SessionStart"
            case "beforeSubmitPrompt": kind = "UserPromptSubmit"
            case "preToolUse": kind = "PreToolUse"
            case "postToolUse", "postToolUseFailure": kind = "PostToolUse"
            case "stop":
                // "completed", "aborted" or "error".
                switch object["status"] as? String {
                case "aborted": kind = "Interrupt"
                case "error": kind = "StopFailure"
                default: kind = "Stop"
                }
            case "sessionEnd": kind = "SessionEnd"
            default: return nil
            }
        case .antigravity:
            switch name {
            case "PreInvocation": kind = "UserPromptSubmit"
            case "PostToolUse": kind = "PostToolUse"
            case "Stop":
                let error = object["error"] as? String
                kind = error?.isEmpty == false ? "StopFailure" : "Stop"
            default: return nil
            }
        case .qwen, .qoder:
            switch name {
            case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                 "PermissionDenied", "Stop", "StopFailure", "SessionEnd":
                kind = name
            case "PostToolUseFailure": kind = "PostToolUse"
            case "Notification":
                guard let type = object["notification_type"] as? String, notificationTokens.contains(type) else { return nil }
                kind = name
                detail = type
            default: return nil
            }
        case .claude, .codex:
            // Followed through their files.
            return nil
        }
        let session = object["session_id"] ?? object["conversation_id"] ?? object["conversationId"]
        let folder = object["cwd"] ?? (object["workspace_roots"] as? [Any])?.first ?? (object["workspacePaths"] as? [Any])?.first
        let tool = object["tool_name"] ?? (object["toolCall"] as? [String: Any])?["name"]
        return RelayEvent(
            provider: provider.rawValue,
            kind: kind,
            session: Relay.identifier(session),
            cwd: Relay.path(folder),
            tool: kind == "PreToolUse" || kind == "PermissionRequest" || kind == "PostToolUse" || kind == "PermissionDenied"
                ? Relay.identifier(tool, maxLength: 96) : nil,
            detail: detail,
            ts: Date().timeIntervalSince1970,
            pid: lineage.agent?.pid,
            pidStart: lineage.agent?.start,
            host: Relay.identifier(lineage.hostBundleID)
        )
    }

    /// Chrome `downloads.DownloadItem` subset. Incognito items are dropped; byte counts
    /// only when Chrome gave them (`totalBytes` <= 0 means unknown, so it's left out).
    static func chromeDownload(_ object: [String: Any]) -> RelayEvent? {
        guard let id = object["id"] as? Int, id >= 0, object["incognito"] as? Bool != true else { return nil }
        let state = object["state"] as? String
        let danger = object["danger"] as? String ?? "safe"
        let error = object["error"] as? String
        let detail: ChromeDownloadState
        switch state {
        case "complete": detail = .complete
        case "interrupted": detail = error == "USER_CANCELED" ? .cancelled : .failed
        case "in_progress":
            if !["safe", "accepted", "allowlistedByPolicy", "deepScannedSafe"].contains(danger) {
                detail = .dangerous
            } else {
                detail = object["paused"] as? Bool == true ? .paused : .inProgress
            }
        default: return nil
        }
        let received = (object["bytesReceived"] as? NSNumber)?.int64Value
        let total = (object["totalBytes"] as? NSNumber)?.int64Value
        return RelayEvent(
            provider: "chrome",
            kind: "download",
            session: String(id),
            cwd: Relay.path(object["filename"]),
            detail: detail.rawValue,
            ts: Date().timeIntervalSince1970,
            name: Relay.fileName(object["filename"]),
            received: received.map { max(0, $0) },
            total: total.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    /// Claude Code status-line input → a usage event plus the line to print.
    /// Only `rate_limits`, the session id and the model's display name are read.
    static func statusLine(_ input: Data) -> (event: RelayEvent?, text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return (nil, "") }
        let model = Relay.label((object["model"] as? [String: Any])?["display_name"], maxLength: 40)
        var windows: [RelayWindow] = []
        if let limits = object["rate_limits"] as? [String: Any] {
            for key in ["five_hour", "seven_day"] {
                guard let window = limits[key] as? [String: Any],
                      let used = (window["used_percentage"] as? NSNumber)?.doubleValue, (0...100).contains(used)
                else { continue }
                let resets = (window["resets_at"] as? NSNumber)?.doubleValue
                windows.append(RelayWindow(id: key, used: used, resets: resets.flatMap { $0 > 0 ? $0 : nil }))
            }
        }
        let short = ["five_hour": "5h", "seven_day": "7d"]
        let parts = [model].compactMap { $0 } + windows.map { "\(short[$0.id] ?? $0.id) \(Int($0.used.rounded()))%" }
        let event = windows.isEmpty ? nil : RelayEvent(
            provider: "claude",
            kind: "usage",
            session: Relay.identifier(object["session_id"]),
            ts: Date().timeIntervalSince1970,
            windows: windows
        )
        return (event, parts.joined(separator: " · "))
    }
}
