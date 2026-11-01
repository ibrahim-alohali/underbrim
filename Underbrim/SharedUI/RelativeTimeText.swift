//
//  RelativeTimeText.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI

/// "just now", "4 min. ago", "in 8 min." in minute steps. `Text(_:style: .relative)`
/// counts seconds ("4 min, 12 sec") and redraws every second.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        // Measured from the real time: the schedule's date is the minute's start, putting new dates in the future.
        TimelineView(.everyMinute) { _ in
            Text(Self.string(for: date, now: .now))
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        // German, French and Russian abbreviate to "vor 12 m", "-12 min", "-12 мин"; their short style reads
        // better. Elsewhere the two are the same, or the short one is longer.
        formatter.unitsStyle = ["de", "fr", "ru"].contains(Locale.current.language.languageCode?.identifier) ? .short : .abbreviated
        return formatter
    }()

    static func string(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if (0..<60).contains(seconds) { return String(localized: "just now") }
        if seconds < 0, seconds > -60 { return String(localized: "now") }
        // Ahead, whole minutes round up, as a countdown does: at 9:57:04 a meeting at 10:00 is in 3 min, as
        // the clock says, not 2 (the formatter drops the 56 seconds).
        let shown = seconds < 0 ? now.addingTimeInterval((-seconds / 60).rounded(.up) * 60) : date
        return formatter.localizedString(for: shown, relativeTo: now)
    }
}
