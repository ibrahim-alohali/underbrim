//
//  CalendarIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Calendar: meeting countdowns and how early they start.
//

import Defaults
import SwiftUI

struct CalendarIsland: View {
    private let store = MeetingStore.shared
    @Default(.meetingCountdown) private var countdown
    @Default(.meetingLeadMinutes) private var lead
    @State private var carry: CGFloat = 0
    @State private var leadShown: Date?

    private static let leads = [5, 10, 15]

    var body: some View {
        IslandSwitch(name: String(localized: "Count down to meetings in the closed notch"), isOn: $countdown,
                     note: countdown ? String(localized: "Scroll to change when the countdown starts") : nil) {
            TimelineView(.everyMinute) { context in
                if !countdown {
                    IslandRow(symbol: "calendar", title: SettingsTab.calendar.title, dim: true)
                } else if let leadShown, Date.now.timeIntervalSince(leadShown) < 1.5 {
                    IslandRow(symbol: "calendar", title: String(localized: "Start the countdown"),
                              value: String(localized: "\(lead) minutes before"))
                } else if store.access == .granted {
                    if let next = store.next(at: context.date) {
                        IslandRow(symbol: "calendar", title: next.title,
                                  value: RelativeTimeText.string(for: next.start, now: context.date))
                    } else {
                        IslandRow(symbol: "calendar", title: String(localized: "Nothing else today"))
                    }
                } else {
                    IslandRow(symbol: "calendar", title: SettingsTab.calendar.title)
                }
            }
        }
        .islandScrollSteps($carry) { step in
            guard countdown else { return }
            setLead(by: step)
        }
        .accessibilityAdjustableAction { step in
            if countdown { setLead(by: step == .increment ? 1 : -1) }
        }
        .task(id: leadShown) {
            guard leadShown != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            leadShown = nil
        }
    }

    private func setLead(by step: Int) {
        let index = Self.leads.firstIndex(of: lead) ?? 1
        lead = Self.leads[min(max(index + step, 0), Self.leads.count - 1)]
        leadShown = .now
    }
}
