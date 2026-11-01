//
//  AgentRoster.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Which of the agents followed through their hooks have them on, for the Agents tab's strip,
//  and whether Claude Code's and Codex's approvals are answered in the notch. Read from their
//  settings files off the main thread whenever the tab or a wait without a hook appears, and
//  whenever Settings or the island changes them.
//

import Foundation

@MainActor @Observable
final class AgentRoster {
    static let shared = AgentRoster()

    /// The agents followed through their hooks (Qwen Code, Qoder, Cursor, Antigravity) that have them in place.
    private(set) var followed: Set<AgentProvider> = []
    /// Claude Code and Codex, when their approvals are answered in the notch; nil until read.
    private(set) var answering: Set<AgentProvider>?
    @ObservationIgnored private var reading = false
    /// Asked again while reading: the files may have changed after they were read.
    @ObservationIgnored private var readAgain = false

    func refresh() {
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        Task {
            repeat {
                readAgain = false
                let (found, answers) = await Task.detached(priority: .utility) { (Self.read(), Self.readAnswering()) }.value
                if found != followed { followed = found }
                if answers != answering { answering = answers }
            } while readAgain
            reading = false
        }
    }

    nonisolated private static func read() -> Set<AgentProvider> {
        Set(AgentProvider.allCases.filter { $0.hookSetup(answers: false)?.status().follows == true })
    }

    nonisolated private static func readAnswering() -> Set<AgentProvider> {
        var answering: Set<AgentProvider> = []
        if (HookInstaller(agent: .claude)?.currentCount() ?? 0) > 0 { answering.insert(.claude) }
        if HookInstaller(agent: .codex)?.status() == .installed { answering.insert(.codex) }
        return answering
    }
}
