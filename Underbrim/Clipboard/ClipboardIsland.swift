//
//  ClipboardIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Clipboard: that copying is noticed, and pausing or resuming the history.
//

import Defaults
import SwiftUI

/// That copying is noticed, and how much is kept: never what. A click pauses or resumes recording.
struct ClipboardIsland: View {
    private let history = ClipboardHistory.shared
    @Default(.clipboardHistoryEnabled) private var on
    @Default(.clipboardPaused) private var paused

    var body: some View {
        let count = history.entries.count
        if !on {
            IslandRow(symbol: "list.clipboard.fill", title: SettingsTab.clipboard.title, dim: true)
        } else {
            switch history.state {
            // Stopped until something else changes (the page under it says what): a click on the
            // island wouldn't change what it shows, so it's no switch.
            case .opening:
                IslandRow(symbol: "key.fill", title: String(localized: "Opening"))
            case .keyUnavailable:
                IslandRow(symbol: "lock.trianglebadge.exclamationmark.fill", title: String(localized: "History is locked"))
            case .storageFailed:
                IslandRow(symbol: "externaldrive.fill.badge.exclamationmark", title: String(localized: "Stopped · error"))
            case .accessDenied:
                IslandRow(symbol: "hand.raised.fill", title: String(localized: "Not allowed"))
            default:
                IslandSwitch(name: String(localized: "Pause history"), isOn: $paused,
                             help: paused ? String(localized: "Resume history") : String(localized: "Pause history")) {
                    let items = String(localized: "\(count) items")
                    if paused || history.state == .paused || history.state == .locked {
                        IslandRow(symbol: history.state == .locked ? "lock.fill" : "pause.fill", title: String(localized: "Paused"),
                                  value: items, valueLit: false)
                    } else if history.state == .storageFull {
                        IslandRow(symbol: "externaldrive.fill.badge.exclamationmark", title: String(localized: "Storage full"),
                                  value: items, valueLit: false)
                    } else if count > 0 {
                        IslandRow(symbol: "checkmark", lit: true, title: String(localized: "Copied"), value: items, valueLit: false)
                    } else {
                        IslandRow(symbol: "list.clipboard.fill", title: SettingsTab.clipboard.title)
                    }
                }
            }
        }
    }
}
