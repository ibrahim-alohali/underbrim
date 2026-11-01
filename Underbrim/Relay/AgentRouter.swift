//
//  AgentRouter.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Hands each decoded relay event to the store that owns it.
//

import Defaults
import Foundation

@MainActor
enum AgentRouter {
    static func route(_ message: RelayMessage) {
        switch message {
        case .usage(let windows, let date):
            AgentUsageStore.shared.applyClaudeStatusLine(windows: windows, at: date)
        case .download(let download):
            DownloadsStore.shared.applyChrome(download)
        case .chromeHello:
            DownloadsStore.shared.chromeExtensionConnected()
        case .request(let arrival):
            AgentRequestStore.shared.receive(arrival)
        case .agent(let event) where !event.provider.readsFiles:
            // Their hooks are how these agents' sessions are followed. A request it was asking
            // in the agent too is over once the session moves on.
            AgentRequestStore.shared.sessionMovedOn(event)
            if Defaults[.showAgentActivity] { AgentSessionStore.shared.apply(event) }
        case .agent(let event):
            // The optional approval hook: Codex doesn't save approval requests. With sessions
            // off, nothing would ever clear the card. Other events of the agents read from
            // their files come from earlier versions' hooks.
            guard event.provider == .codex, case .permissionRequest = event.kind, Defaults[.showAgentActivity] else { return }
            AgentSessionStore.shared.apply(event)
        }
    }
}
