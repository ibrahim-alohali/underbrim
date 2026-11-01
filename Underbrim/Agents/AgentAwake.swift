//
//  AgentAwake.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Keeps the Mac from idle sleep while a shown session is working, so a long task
//  isn't cut off. The display can still sleep, and closing the lid still sleeps the
//  Mac. Let go when nothing works (quiet sessions don't count), switched off, or on quit.
//

import Defaults
import Foundation
import IOKit.pwr_mgt
import os

@MainActor @Observable
final class AgentAwake {
    static let shared = AgentAwake()

    private(set) var holding = false

    @ObservationIgnored private var assertion: IOPMAssertionID?
    @ObservationIgnored private var working = false
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: bundleIdentifier, category: "agents")

    private init() {
        switchTask = Defaults.whenChanged([.keepAwakeWhileAgentsWork]) { [weak self] in self?.apply() }
    }

    /// Whether any session the island shows is working, after every change to them.
    func update(working: Bool) {
        guard working != self.working else { return }
        self.working = working
        apply()
    }

    private func apply() {
        let wanted = working && Defaults[.keepAwakeWhileAgentsWork]
        if wanted, assertion == nil {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "A coding session is working" as CFString, &id)
            if status == kIOReturnSuccess {
                assertion = id
            } else {
                log.error("keeping the Mac awake failed: \(status)")
            }
        } else if !wanted, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
        if holding != (assertion != nil) { holding = assertion != nil }
    }
}
