//
//  MeetingStore.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Upcoming-meeting countdown with a Join action. Refreshes when the calendar database changes or
//  the Mac wakes, otherwise sleeps until the next moment something changes; no polling.
//

import AppKit
import Defaults
import EventKit
import Observation

@MainActor
@Observable
final class MeetingStore {
    static let shared = MeetingStore()

    struct Meeting: Equatable, Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendarTitle: String
        let calendarColor: NSColor
        let link: MeetingLink?
    }

    enum Access: Equatable { case unknown, granted, denied }

    private(set) var featured: Meeting?
    private(set) var overlapping: [Meeting] = []
    private(set) var access: Access = .unknown

    /// EventKit fetches are thread-safe; the store only reads through it.
    @ObservationIgnored nonisolated(unsafe) private let service = CalendarService()
    /// The meetings fetched (Settings' Calendar island reads them too).
    private var upcoming: [Meeting] = []
    /// When `upcoming` was fetched (it covers the next 12 hours from then, and the rest of that day).
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var dismissedIDs: Set<String> = []

    nonisolated static let grace: TimeInterval = 5 * 60

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        Defaults.whenChanged([.meetingCountdown, .meetingLeadMinutes, .calendarSelectionState]) { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        // Read even while the countdown is off: Settings shows it.
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess {
            access = .granted
        } else {
            access = status == .notDetermined ? .unknown : .denied
            return clear()
        }
        guard Defaults[.meetingCountdown] else { return clear() }
        loadTask?.cancel()
        loadTask = Task {
            let now = Date()
            // To midnight at least, so Settings can tell when nothing else is on today.
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            var events: [EventModel] = []
            if let ids = CalendarManager.calendarIDs(for: Defaults[.calendarSelectionState]) {
                events = await service.events(from: now.addingTimeInterval(-3600), to: max(now.addingTimeInterval(12 * 3600), tomorrow),
                                              calendars: ids)
            }
            // A newer reload, or the feature being turned off, wins.
            guard !Task.isCancelled, Defaults[.meetingCountdown] else { return }
            loadedAt = now
            upcoming = Self.meetings(from: events, now: now)
            evaluate()
        }
    }

    /// Off, or no calendar access: nothing may come back from a timer or an old fetch.
    private func clear() {
        loadTask?.cancel()
        timer?.cancel()
        upcoming = []
        featured = nil
        overlapping = []
    }

    func requestAccess() async {
        _ = try? await service.requestAccess(to: .event)
        reload()
    }

    func dismiss(_ meeting: Meeting) {
        dismissedIDs.insert(meeting.id)
        evaluate()
    }

    /// Opens the join link; only links MeetingLinkDetector validated (known host, http/https).
    func join(_ meeting: Meeting) {
        guard let url = meeting.link?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Rules

    /// Timed events only: no all-day events, reminders, birthdays or declined meetings.
    nonisolated static func meetings(from events: [EventModel], now: Date) -> [Meeting] {
        events.compactMap { event in
            guard !event.isAllDay, event.end > now, case .event(let attendance) = event.type, attendance != .declined
            else { return nil }
            return Meeting(id: event.id, title: event.title, start: event.start, end: event.end,
                           calendarTitle: event.calendar.title, calendarColor: event.calendar.color, link: event.meetingLink)
        }
        .sorted { $0.start < $1.start }
    }

    nonisolated static func pick(_ meetings: [Meeting], now: Date, lead: TimeInterval, dismissed: Set<String>) -> (Meeting?, [Meeting]) {
        let candidates = meetings.filter { meeting in
            !dismissed.contains(meeting.id)
                && meeting.start.addingTimeInterval(-lead) <= now
                && now < min(meeting.end, meeting.start.addingTimeInterval(grace))
        }
        guard let first = candidates.first else { return (nil, []) }
        let overlaps = meetings.filter { $0.id != first.id && $0.start < first.end && first.start < $0.end && !dismissed.contains($0.id) }
        return (first, overlaps)
    }

    private var lead: TimeInterval { TimeInterval(Defaults[.meetingLeadMinutes]) * 60 }

    /// The next meeting today that isn't over, under way or not (Settings shows it).
    func next(at now: Date) -> Meeting? {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        return upcoming.first { $0.end > now && $0.start < tomorrow }
    }

    /// A meeting under way (declined ones aren't in the list): prayer alerts stay quiet.
    func inMeeting(at now: Date) -> Bool {
        Defaults[.meetingCountdown] && access == .granted && upcoming.contains { $0.start <= now && now < $0.end }
    }

    private func evaluate() {
        guard Defaults[.meetingCountdown], access == .granted else { return clear() }
        let now = Date()
        let (meeting, overlaps) = Self.pick(upcoming, now: now, lead: lead, dismissed: dismissedIDs)
        if meeting != featured { featured = meeting }
        if overlaps != overlapping { overlapping = overlaps }
        scheduleNext(after: now)
    }

    #if DEBUG
    /// Test builds: a made-up meeting with a Zoom link, starting in `minutes`.
    func debugMeeting(inMinutes minutes: Double) {
        let start = Date().addingTimeInterval(minutes * 60)
        access = .granted
        upcoming = [Meeting(id: "debug", title: "Design review", start: start, end: start.addingTimeInterval(1800),
                            calendarTitle: "Work", calendarColor: .systemBlue,
                            link: MeetingLink(url: URL(string: "https://zoom.us/j/123")!, provider: .zoom))]
        evaluate()
    }
    #endif

    /// Sleeps until the next countdown start, grace end or meeting end, or until it's time to look
    /// further ahead (a Mac that never sleeps would miss meetings past the 12 hours loaded).
    private func scheduleNext(after now: Date) {
        timer?.cancel()
        let moments = upcoming.flatMap { [$0.start.addingTimeInterval(-lead), $0.start.addingTimeInterval(Self.grace), $0.end] }
            .filter { $0 > now }
        let lookAhead = (loadedAt ?? now).addingTimeInterval(6 * 3600)
        let next = min(moments.min() ?? lookAhead, lookAhead)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled, let self else { return }
            if next == lookAhead { self.reload() } else { self.evaluate() }
        }
    }
}
