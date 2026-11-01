//
//  RelayListener.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Receives the agents' hooks and Chrome's extension: links the helper they run, listens on the
//  socket, hands what arrives to AgentRouter, sends the answers back, and says how it's going.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class RelayListener {
    static let shared = RelayListener()

    /// Whether hooks and Chrome reach the app; nil until listening starts.
    private(set) var health: RelayHealth?

    @ObservationIgnored private var listening = false
    @ObservationIgnored private var server: RelayServer?
    @ObservationIgnored private let log = Logger(subsystem: bundleIdentifier, category: "relay")

    private init() {}

    func start() {
        guard !listening else { return }
        listening = true
        check()
    }

    /// Links the relay helper, starts listening if that failed before (another copy may have quit
    /// since), and says how it went. Settings checks again each time it shows the relay's state.
    func check() {
        guard listening else { return }
        var health = RelayHealth.ready
        do {
            try RelayLink.refresh()
        } catch {
            health = .link(error)
        }
        if server == nil {
            let server = RelayServer { message in
                Task { @MainActor in AgentRouter.route(message) }
            } onRequestEnded: { id in
                Task { @MainActor in AgentRequestStore.shared.withdraw(id) }
            }
            do {
                try server.start()
                self.server = server
            } catch {
                log.error("relay listener failed: \(String(describing: error), privacy: .public)")
                health = .listener(error)
            }
        }
        if case .link(let error) = health {
            log.error("relay link: \(String(describing: error), privacy: .public)")
        }
        if self.health != health { self.health = health }
    }

    /// Sends an answer (nil: hands the request back) on the request's connection.
    func reply(_ answer: RelayAnswer?, to id: String) {
        server?.reply(answer, to: id)
    }

    func stop() {
        listening = false
        server?.stop()
        server = nil
    }
}
