//
//  ElapsedText.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI

/// How long since `since`, as a duration: "45s", "21m 26s", "1h 5m" in each language. A stopwatch
/// (`Text(_:style: .timer)`) shows "21:26", which reads as a time of day; calls keep theirs, as
/// phones show a call's length.
struct ElapsedText: View {
    let since: Date
    /// What VoiceOver calls it ("Waiting"), before how long.
    var spokenAs: String?

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let text = Self.string(context.date.timeIntervalSince(since))
            if let spokenAs {
                Text(text).accessibilityLabel(spokenAs).accessibilityValue(text)
            } else {
                Text(text)
            }
        }
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func string(_ seconds: TimeInterval) -> String {
        formatter.string(from: max(0, seconds.rounded(.down))) ?? ""
    }
}
