//
//  MeetingViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import SwiftUI

extension Duration {
    /// "4m" ("4د" in Arabic): minutes as the notch's small labels show them.
    static func minutesShort(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .narrow))
    }
}

/// "4m", "<1m", "Now": refreshed once a minute by its own timeline. The minutes round up, as a countdown
/// does (the timer's too): what the clock says is left, and the same however far into a minute it appeared.
struct MeetingCountdownText: View {
    let start: Date

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let seconds = start.timeIntervalSince(.now)
            Text(seconds <= 0 ? Self.now : seconds < 60 ? "<" + Self.minutes(1) : Self.minutes(Int((seconds / 60).rounded(.up))))
                .font(.notchCaption.weight(.semibold).monospacedDigit())
                .foregroundStyle(seconds <= 60 ? .orange : .white)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
        }
    }

    /// A word of its own for this 26 pt slot: "Maintenant", "Adesso" and "Сейчас" don't fit.
    private static var now: String {
        String(localized: "Now (closed notch)", defaultValue: "Now",
               comment: "A meeting starting now, beside the camera: a short word, at most about 5 letters.")
    }

    /// Without the space some languages put in ("45 min", "<1 мин" get cut).
    private static func minutes(_ count: Int) -> String {
        Duration.minutesShort(count).filter { !$0.isWhitespace }
    }
}

struct MeetingLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let meeting: MeetingStore.Meeting

    private var itemSize: CGFloat { vm.closedItemSize }

    var body: some View {
        HStack {
            Image(systemName: meeting.link == nil ? "calendar" : "video.fill")
                .font(.notchSymbol(size: 12))
                .foregroundStyle(Color(nsColor: meeting.calendarColor))
                .frame(width: itemSize, height: itemSize)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            MeetingCountdownText(start: meeting.start)
                .frame(width: itemSize + 6, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(meeting.title), ") + Text(meeting.start, style: .relative))
    }
}

struct MeetingExpandedView: View {
    /// Compact mode's narrow panel has room for the meeting alone.
    var showsOthers = true

    var body: some View {
        MeetingRow(meeting: MeetingStore.shared.featured, overlapping: showsOthers ? MeetingStore.shared.overlapping : [])
    }
}

/// The meeting, and beside it any others at the same time; empty, a line saying so.
struct MeetingRow: View {
    let meeting: MeetingStore.Meeting?
    let overlapping: [MeetingStore.Meeting]
    private var store: MeetingStore { .shared }

    var body: some View {
        Group {
            if let meeting {
                row(meeting)
            } else {
                Label(String(localized: "No meetings coming up"), systemImage: "calendar")
                    .font(.notchBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: NotchMetrics.tabHeight, alignment: .top)
    }

    private func row(_ meeting: MeetingStore.Meeting) -> some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: meeting.calendarColor))
                    .frame(width: 4, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.notchTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    TimelineView(.everyMinute) { _ in
                        Text(meeting.start, style: .time) + Text(" – ") + Text(meeting.end, style: .time)
                            + Text(" · \(RelativeTimeText.string(for: meeting.start, now: .now))")
                    }
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Text(meeting.calendarTitle).font(.notchCaption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                joinButton(meeting)
            }
            if !overlapping.isEmpty {
                Divider().overlay(.white.opacity(0.15))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(overlapping.prefix(3)) { other in
                        HStack(spacing: 6) {
                            Circle().fill(Color(nsColor: other.calendarColor)).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(other.title).lineLimit(1)
                            Spacer()
                            Text(other.start, style: .time).foregroundStyle(.secondary)
                            if other.link != nil {
                                NotchTextButton(title: String(localized: "Join"),
                                                help: String(localized: "Join \(other.title)")) { store.join(other) }
                            }
                        }
                        .font(.notchCaption)
                        .accessibilityElement(children: .combine)
                    }
                }
                // Up to 260; less in compact mode's narrow panel, so the meeting keeps its room.
                .frame(maxWidth: 260)
            }
        }
    }

    @ViewBuilder private func joinButton(_ meeting: MeetingStore.Meeting) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let link = meeting.link {
                Button {
                    store.join(meeting)
                } label: {
                    Label(String(localized: "Join"), systemImage: "video.fill")
                }
                .buttonStyle(NotchProminentStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(String(localized: "Join on \(link.provider.displayName)"))
                Text(link.provider.displayName).font(.notchCaption).foregroundStyle(.secondary)
            } else {
                Text(String(localized: "No video link")).font(.notchCaption).foregroundStyle(.secondary)
            }
            NotchTextButton(title: String(localized: "Hide"), help: String(localized: "Hide this meeting")) { store.dismiss(meeting) }
        }
    }
}
