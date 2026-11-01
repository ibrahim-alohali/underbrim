//
//  HomeWidgets.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Home's widgets: which show, in what order, at what size.
//

import AppKit
import Defaults
import EventKit
import SwiftUI

enum HomeWidget: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying, calendar, mirror, quickLaunch, timer, shortcuts, scratchpad, system, reminders, unread, calls, prayer

    var id: Self { self }

    /// Its name in English, as the string catalog has it.
    var titleKey: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .calendar: "Calendar"
        case .mirror: "Mirror"
        case .quickLaunch: "Quick Launch"
        case .timer: "Timer"
        case .shortcuts: "Shortcuts"
        case .scratchpad: "Scratchpad"
        case .system: "System"
        case .reminders: "Reminders"
        case .unread: "Unread"
        case .calls: "Calls"
        case .prayer: "Prayer Times"
        }
    }

    var title: String { String(localized: String.LocalizationValue(titleKey)) }

    /// More words Settings' search finds it by, in English and Arabic.
    var searchWords: String {
        switch self {
        case .nowPlaying: "widget home music player أداة موسيقى مشغل"
        case .calendar: "widget home events أداة أحداث"
        case .mirror: "widget home camera show the mirror أداة كاميرا مرآة"
        case .quickLaunch: "widget home apps dock أداة تطبيقات"
        case .timer: "widget home stopwatch countdown أداة مؤقت"
        case .shortcuts: "widget home automation أداة اختصارات"
        case .scratchpad: "widget home notes note أداة ملاحظات"
        case .system: "widget home cpu memory أداة نظام"
        case .reminders: "widget home tasks todo أداة تذكيرات"
        case .unread: "widget home messages mail أداة غير مقروء"
        case .calls: "widget home phone أداة مكالمات"
        case .prayer: "widget home أداة"
        }
    }

    /// Its row's mark in Settings › Widgets, where the search lights it.
    var settingsMark: String { "widget.\(rawValue)" }

    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .calendar: "calendar"
        case .mirror: "web.camera"
        case .quickLaunch: "square.grid.3x2"
        case .timer: "timer"
        case .shortcuts: "bolt"
        case .scratchpad: "note.text"
        case .system: "cpu"
        case .reminders: "checklist"
        case .unread: "app.badge"
        case .calls: "mic"
        case .prayer: "moon.stars"
        }
    }

    /// The setting that turns it on; Calendar and Mirror reuse upstream's.
    var enabledKey: Defaults.Key<Bool> {
        switch self {
        case .nowPlaying: .showNowPlayingWidget
        case .calendar: .showCalendar
        case .mirror: .showMirror
        case .quickLaunch: .showQuickLaunch
        case .timer: .showTimerWidget
        case .shortcuts: .showShortcutsWidget
        case .scratchpad: .showScratchpadWidget
        case .system: .showSystemWidget
        case .reminders: .showRemindersWidget
        case .unread: .showUnreadWidget
        case .calls: .showCallsWidget
        case .prayer: .showPrayerWidget
        }
    }

    /// Every setting that changes which widgets Home shows, in what order or how wide: what lays out
    /// Home, or depends on whether a widget is on, watches these.
    static let layoutKeys: [Defaults._AnyKey] = allCases.map { $0.enabledKey as Defaults._AnyKey }
        + [Defaults.Keys.homeWidgetOrder, .homeWidgetSizes]

    /// Shown on the lock screen: only widgets that show nothing private. Now Playing and Timer
    /// control playback and the timer; the others show calendars, notes, reminders, badges or calls,
    /// run shortcuts or open apps.
    var showsWhileLocked: Bool {
        switch self {
        case .nowPlaying, .timer, .system, .prayer: true
        default: false
        }
    }

    var sizes: [WidgetSize] {
        switch self {
        case .calendar, .quickLaunch, .shortcuts, .scratchpad, .reminders: WidgetSize.allCases
        default: []
        }
    }

    /// The artwork and the mirror are square; Prayer is as wide as its words can be, so whatever
    /// it shows fits (`liveWidth` is the width it takes now).
    func width(_ size: WidgetSize, height: CGFloat) -> CGFloat {
        switch self {
        case .nowPlaying: height + NotchMetrics.margin + 260
        case .mirror: height
        case .calendar, .shortcuts, .scratchpad, .reminders: size == .small ? 180 : size == .medium ? 220 : 280
        case .quickLaunch: QuickLaunchWidget.width(columns: size.quickLaunchColumns) + QuickLaunchWidget.corner
        case .timer, .system: 150
        case .unread: QuickLaunchWidget.width(columns: 3)
        case .calls: 200
        case .prayer: PrayerSummary.widest
        }
    }

    /// Its width on Home now: Prayer as wide as what it shows, the others as their size.
    @MainActor func liveWidth(height: CGFloat) -> CGFloat {
        self == .prayer ? PrayerWidgetWidth.shared.width : width(size, height: height)
    }

    var size: WidgetSize {
        let saved = Defaults[.homeWidgetSizes][rawValue] ?? .medium
        return sizes.isEmpty || sizes.contains(saved) ? saved : sizes.last ?? .medium
    }

    /// The next of its own sizes that still lets Home's row fit within `limit`, round again after
    /// its largest. A smaller size is always allowed, so an overflowing row can be cut down.
    func nextSize(beside others: [HomeWidget], within limit: CGFloat) -> WidgetSize {
        guard let start = sizes.firstIndex(of: size) else { return size }
        for step in 1..<sizes.count {
            let candidate = sizes[(start + step) % sizes.count]
            if allows(candidate, beside: others, within: limit) { return candidate }
        }
        return size
    }

    private func allows(_ candidate: WidgetSize, beside others: [HomeWidget], within limit: CGFloat) -> Bool {
        width(candidate, height: MusicPlayerView.height) <= width(size, height: MusicPlayerView.height)
            || Self.fit(others + [self], within: limit, size: { $0 == self ? candidate : $0.size })
    }

    @MainActor static func canTurnOn(_ widget: HomeWidget) -> Bool {
        Defaults[widget.enabledKey] || fit(enabled + [widget], within: room)
    }

    static func fit(_ widgets: [HomeWidget], within limit: CGFloat, size: (HomeWidget) -> WidgetSize = \.size) -> Bool {
        NotchHomeView.contentWidth(widgets, size: size) <= limit
    }

    static let noRoom = String(localized: "No room on Home: make a widget smaller or remove one.")

    /// Room for Home's row: the notch's screen, or the narrowest when the notch shows on every display.
    @MainActor static var room: CGFloat {
        guard Defaults[.showOnAllDisplays] else {
            return NotchHomeView.maxContentWidth(screen: NotchViewCoordinator.shared.selectedScreenUUID)
        }
        return NSScreen.screens.map { NotchHomeView.maxContentWidth(screenWidth: $0.frame.width) }.min()
            ?? NotchHomeView.maxContentWidth(screenWidth: nil)
    }

    static func ordered(_ saved: [HomeWidget]) -> [HomeWidget] { cleanedOrder(saved, within: allCases) }

    static var enabled: [HomeWidget] { ordered(Defaults[.homeWidgetOrder]).filter { Defaults[$0.enabledKey] } }

    /// What compact mode's island can show: the widgets that are on, and Now Playing either way.
    static var compactChoices: [HomeWidget] {
        let on = enabled
        return on.contains(.nowPlaying) ? on : [.nowPlaying] + on
    }

    static var compactChosen: HomeWidget {
        let chosen = Defaults[.compactWidget]
        return compactChoices.contains(chosen) ? chosen : .nowPlaying
    }

    static func moving(_ widget: HomeWidget, to target: HomeWidget, in order: [HomeWidget]) -> [HomeWidget] {
        guard widget != target, let from = order.firstIndex(of: widget), let to = order.firstIndex(of: target) else { return order }
        var order = order
        order.insert(order.remove(at: from), at: to)
        return order
    }

    static func adding(_ widget: HomeWidget, to order: [HomeWidget], after on: Set<HomeWidget>) -> [HomeWidget] {
        var order = order.filter { $0 != widget }
        order.insert(widget, at: order.lastIndex(where: on.contains).map { $0 + 1 } ?? 0)
        return order
    }
}

enum WidgetSize: String, CaseIterable, Defaults.Serializable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }

    var quickLaunchColumns: Int { self == .small ? 2 : self == .medium ? 4 : 6 }
}

func cleanedOrder<T: Hashable>(_ saved: [T], within all: [T]) -> [T] {
    var seen = Set<T>()
    let kept = saved.filter { all.contains($0) && seen.insert($0).inserted }
    return kept + all.filter { !seen.contains($0) }
}

// MARK: - Calendar

struct CalendarWidget: View {
    var alone = false
    @ObservedObject private var manager = CalendarManager.shared

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        Group {
            if alone {
                aloneLayout
            } else {
                home
            }
        }
        .task { await manager.updateCurrentDate(.now) }
    }

    private var home: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { AppInfo.activate(Self.calendarApp) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Date.now, format: .dateTime.weekday(.abbreviated))
                        .font(.notchCaption.weight(.semibold))
                        .foregroundStyle(.red)
                        .textCase(.uppercase)
                    Text(Date.now, format: .dateTime.day())
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open Calendar"))
            .accessibilityLabel(Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()))
            .accessibilityHint(String(localized: "Opens Calendar"))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 2)
    }

    private var aloneLayout: some View {
        // Pinned, nothing else redraws it: the next event moves on by the minute.
        TimelineView(.everyMinute) { context in
            aloneFrame(now: context.date)
        }
    }

    private func aloneFrame(now: Date) -> some View {
        let status = EKEventStore.authorizationStatus(for: .event)
        let upcoming = status == .fullAccess ? MeetingStore.meetings(from: manager.events, now: now) : []
        return AloneFrame(widget: .calendar) {
            Button { AppInfo.activate(Self.calendarApp) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(now, format: .dateTime.weekday(.abbreviated))
                        .font(.notchCaption.weight(.semibold))
                        .foregroundStyle(.red)
                        .textCase(.uppercase)
                    Text(now, format: .dateTime.day())
                        .font(.notchTitle)
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open Calendar"))
            .accessibilityLabel(Text(now, format: .dateTime.weekday(.wide).month(.wide).day()))
            .accessibilityHint(String(localized: "Opens Calendar"))
        } trailing: {
            if upcoming.count > 1 {
                (Text(verbatim: "+") + Text(upcoming.count - 1, format: .number))
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } row: {
            Group {
                switch status {
                case .fullAccess:
                    if let next = upcoming.first {
                        row(next)
                    } else {
                        Text(String(localized: "Nothing else today")).font(.notchCaption).foregroundStyle(.secondary)
                    }
                case .notDetermined:
                    NotchTextButton(title: String(localized: "Allow Calendar Access…")) {
                        Task {
                            await manager.checkCalendarAuthorization()
                            MeetingStore.shared.reload()
                        }
                    }
                default:
                    HStack(spacing: 6) {
                        Text(String(localized: "Calendar access is off")).font(.notchCaption).foregroundStyle(.secondary)
                        NotchTextButton(title: String(localized: "Open Privacy Settings…")) {
                            SystemSettings.open(.calendars)
                        }
                    }
                }
            }
            .frame(minWidth: 0, idealWidth: HomeWidget.calendar.width(HomeWidget.calendar.size, height: 0), maxWidth: .infinity,
                   alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            // The meeting countdown's rules: timed, not over, not declined; soonest first.
            let upcoming = MeetingStore.meetings(from: manager.events, now: .now)
            if upcoming.isEmpty {
                Text(String(localized: "Nothing else today")).font(.notchCaption).foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                // Three 20 pt rows (each one a full-height target) fill 60 of the 88.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(upcoming.prefix(3)) { row($0) }
                }
            }
        case .notDetermined:
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "See today's events here")).font(.notchCaption).foregroundStyle(.secondary)
                NotchTextButton(title: String(localized: "Allow Calendar Access…")) {
                    Task {
                        await manager.checkCalendarAuthorization()
                        MeetingStore.shared.reload()
                    }
                }
            }
            .padding(.top, 2)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Calendar access is off")).font(.notchCaption).foregroundStyle(.secondary)
                NotchTextButton(title: String(localized: "Open Privacy Settings…")) {
                    SystemSettings.open(.calendars)
                }
            }
            .padding(.top, 2)
        }
    }

    private func row(_ meeting: MeetingStore.Meeting) -> some View {
        Button { open(meeting) } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: meeting.calendarColor))
                    .frame(width: 3, height: 14)
                // As wide as the widest time ("10:00 PM", or "22:00"), so the titles line up.
                ZStack(alignment: .leading) {
                    Text(Self.widestTime, format: .dateTime.hour().minute()).hidden()
                    Text(meeting.start, format: .dateTime.hour().minute())
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Text(meeting.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .font(.notchCaption)
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(meeting.title)
        .accessibilityLabel(Text(meeting.start, format: .dateTime.hour().minute()) + Text(", \(meeting.title), \(meeting.calendarTitle)"))
        .contextMenu {
            Button(String(localized: "Open in Calendar")) { openInCalendar(meeting) }
            if let link = meeting.link {
                Button(String(localized: "Join")) { MeetingStore.shared.join(meeting) }
                Button(String(localized: "Copy Meeting Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                }
            }
        }
    }

    private static let widestTime = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: .now) ?? .now
    private static let calendarApp = "com.apple.iCal"

    private func open(_ meeting: MeetingStore.Meeting) {
        if Defaults[.joinMeetingOnEventTap], meeting.link != nil {
            MeetingStore.shared.join(meeting)
        } else {
            openInCalendar(meeting)
        }
    }

    private func openInCalendar(_ meeting: MeetingStore.Meeting) {
        if let url = manager.events.first(where: { $0.id == meeting.id })?.calendarAppURL() {
            NSWorkspace.shared.open(url)
        } else {
            AppInfo.activate(Self.calendarApp)
        }
    }
}

extension View {
    @MainActor func homeRoom(for widget: HomeWidget) -> some View { modifier(HomeRoom(widget: widget)) }
}

/// Read on every redraw; Home's changes made elsewhere bring one.
private struct HomeRoom: ViewModifier {
    let widget: HomeWidget
    @State private var changes = 0

    func body(content: Content) -> some View {
        let _ = changes
        let room = HomeWidget.canTurnOn(widget)
        content
            .disabled(!room)
            .help(room ? "" : HomeWidget.noRoom)
            .task {
                for await _ in Defaults.updates(HomeWidget.layoutKeys, initial: false) { changes += 1 }
            }
    }
}
