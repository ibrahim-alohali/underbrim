//
//  UsageWarnings.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A word on the closed notch when a usage window reaches the user's warning line, and
//  again when it resets; once per window and reset time, across relaunches. Uses only
//  readings the usage store already has.
//

import Defaults
import Foundation
import SwiftUI

@MainActor
final class UsageWarnings {
    static let shared = UsageWarnings()

    /// The warning lines offered in Settings (0: off).
    static let choices = [0, 75, 80, 90, 95]

    enum Notice: Equatable {
        case reached(percent: Int)
        case reset
    }

    /// What a new reading should announce, and what to remember: per window, the reset
    /// time it was warned for (0 when the reading has none).
    nonisolated static func notices(provider: String, windows: [AgentUsageStore.Window], line: Int, now: Date,
                        warned: [String: Double]) -> (notices: [(window: AgentUsageStore.Window, notice: Notice)], warned: [String: Double]) {
        guard line > 0 else { return ([], warned) }
        var warned = warned
        var notices: [(AgentUsageStore.Window, Notice)] = []
        for window in windows {
            let key = "\(provider).\(window.id)"
            // Without a reset time, when the reading stops describing the window.
            let resets = (window.resetsAt ?? window.expiresAt)?.timeIntervalSince1970 ?? 0
            if let warnedFor = warned[key] {
                // A later reset time is a new window; a passed one, the same window reset. A lower
                // reading alone doesn't count: one with no reset time can't tell.
                let newWindow = resets > warnedFor + 60 || (warnedFor > 0 && now.timeIntervalSince1970 >= warnedFor)
                if newWindow, (window.usedPercent ?? 0) < Double(line) {
                    warned[key] = nil
                    notices.append((window, .reset))
                }
                continue
            }
            if let used = window.usedPercent, used >= Double(line) {
                warned[key] = resets
                notices.append((window, .reached(percent: Int(used.rounded(.down)))))
            }
        }
        return (notices, warned)
    }

    func check(_ provider: AgentProvider, snapshot: AgentUsageStore.Snapshot?) {
        guard let snapshot, Defaults[.showAgentActivity] else { return }
        let result = Self.notices(provider: provider.rawValue, windows: snapshot.windows, line: Defaults[.usageWarningPercent],
                                  now: Date(), warned: Defaults[.usageWarned])
        Defaults[.usageWarned] = result.warned
        // The most pressing one, if several arrive at once.
        guard let (window, notice) = result.notices.first(where: { if case .reached = $0.notice { true } else { false } })
                ?? result.notices.first
        else { return }
        StatusFlash.shared.show(Self.flash(provider, window: window, notice: notice), for: 4)
    }

    static func flash(_ provider: AgentProvider, window: AgentUsageStore.Window, notice: Notice) -> StatusFlash.Flash {
        let app = provider.appName
        switch notice {
        case .reached(let percent):
            let resets = window.resetsAt.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
            let spoken = resets.map { String(localized: "\(app) \(window.label) limit \(percent)% used, resets \($0)") }
                ?? String(localized: "\(app) \(window.label) limit \(percent)% used")
            return .init(symbol: "gauge.with.dots.needle.67percent", label: (Double(percent) / 100).formatted(.percent), tint: .orange, spoken: spoken)
        case .reset:
            return .init(symbol: "gauge.with.dots.needle.0percent", label: String(localized: "Reset"), tint: .green,
                         spoken: String(localized: "\(app) \(window.label) limit available again"))
        }
    }
}
