//
//  LiveActivityStack.swift
//  Underbrim
//
//  A browsable stack of closed-notch live activities, in the spirit of the
//  Dynamic Island / Lock Screen activity stack: the newest activity takes
//  the front, older ones sit behind it, and the user can swipe between them.
//
//  Transient activities (a notification) auto-expire and reveal whatever was
//  underneath (music), so an incoming message interrupts the now-playing
//  display for a beat and then hands it back on its own.
//

import SwiftUI

/// One entry in the closed-notch stack.
///
/// Deliberately excludes the momentary HUDs — volume/brightness OSD and the
/// battery pill. Those are interrupts, not activities: they take over for
/// ~1.5s and aren't something you'd want to swipe back to, which is also how
/// iOS separates them from live activities.
enum LiveActivityItem: Identifiable, Equatable {
    case notification(SystemNotification)
    case agent(AgentClosedSummary)
    case meeting(MeetingStore.Meeting)
    case download(DownloadClosedSummary)
    case headphones(HeadphoneBatteryStore.Device)
    case timer
    case phone(PhoneActivity)
    case delivery(DeliveryTracker.Order)
    case call(CallActivity.Call)
    case prayer(PrayerMoment)
    case music

    /// One agent entry, whatever its state (so a request that's answered stays the same activity).
    static let agentID = "agent"

    var id: String {
        switch self {
        case .notification(let notification): "notification-\(notification.id)"
        case .agent: Self.agentID
        case .meeting(let meeting): "meeting-\(meeting.id)"
        case .download: "download"
        case .headphones(let device): "headphones-\(device.id)"
        case .timer: "timer"
        case .phone(let activity): "phone-\(activity.id)"
        case .delivery(let order): "delivery-\(order.app)"
        case .call: "call"
        case .prayer(let moment): "prayer-\(moment.name.rawValue)-\(Int(moment.at.timeIntervalSince1970))"
        case .music: "music"
        }
    }

    /// Which activity it is, whatever it shows.
    enum Kind: Hashable {
        case notification, agent, meeting, download, headphones, timer, phone, delivery, call, prayer, music

        /// What it adds on each side of the closed island, beyond the room every activity has.
        /// Music sizes itself (ContentView), for its inline song-change peek.
        var extraWidth: CGFloat {
            switch self {
            case .notification, .agent, .meeting, .download, .headphones, .music: 0
            case .timer, .call: TimerLiveActivity.extraWidth
            case .phone, .delivery: PhoneActivityLiveActivity.extraWidth
            case .prayer: PrayerLiveActivity.extraWidth
            }
        }
    }

    var kind: Kind {
        switch self {
        case .notification: .notification
        case .agent: .agent
        case .meeting: .meeting
        case .download: .download
        case .headphones: .headphones
        case .timer: .timer
        case .phone: .phone
        case .delivery: .delivery
        case .call: .call
        case .prayer: .prayer
        case .music: .music
        }
    }

    var page: NotchViews? {
        switch self {
        case .agent: .agents
        case .download: .downloads
        case .meeting: .meeting
        case .timer: .home
        case .call, .phone, .delivery: .phoneActivities
        case .prayer: .prayer
        case .notification, .headphones, .music: nil
        }
    }
}

/// Which activity has the island, by id (a position would point at another one as things start and
/// end). Something new comes to the front while it lasts; the user's pick stays until it ends.
struct ActivitySelection {
    private(set) var fronts: [String] = []
    private(set) var picked: String?
    /// What a pick moved off the island: the bubble shows it.
    private(set) var swappedOut: String?
    /// When each activity took the island; it opens on that page unless a tab was picked since.
    private(set) var since: [String: Date] = [:]

    /// The latest to come to the front, else the user's pick, else the most important.
    func top(of ids: [String]) -> String? {
        fronts.last(where: ids.contains) ?? picked.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }

    /// Beside the island: the pick while something else is in front, else what it swapped out, else the next.
    func bubble(of ids: [String]) -> String? {
        let top = top(of: ids)
        return [picked, swappedOut].compactMap { $0 }.first { $0 != top && ids.contains($0) } ?? ids.first { $0 != top }
    }

    mutating func bringForward(_ id: String) {
        fronts.removeAll { $0 == id }
        fronts.append(id)
        since[id] = Date()
    }

    mutating func pick(_ id: String, among ids: [String]) {
        let previous = top(of: ids)
        fronts = []
        picked = id
        swappedOut = previous == id ? swappedOut : previous
        since[id] = Date()
    }

    mutating func release(_ id: String) {
        fronts.removeAll { $0 == id }
    }

    /// Forgets ended activities and notes when the top one took the island (not on return after a notification).
    mutating func update(ids: [String]) {
        fronts.removeAll { !ids.contains($0) }
        if let picked, !ids.contains(picked) { self.picked = nil }
        if let swappedOut, !ids.contains(swappedOut) { self.swappedOut = nil }
        since = since.filter { ids.contains($0.key) }
        if let top = top(of: ids), since[top] == nil { since[top] = Date() }
    }
}

/// Renders the selected activity with the others hinted behind it, and
/// handles swiping between them.
///
/// Takes its content via a closure so callers keep ownership of how each
/// activity draws — `MusicLiveActivity` depends on ContentView's namespace
/// and gesture state, and dragging it out here would be a much larger,
/// riskier change than this feature needs.
struct LiveActivityStack<Content: View>: View {
    let items: [LiveActivityItem]
    let selected: LiveActivityItem?
    /// The user is swapping activities: they blur into each other instead of the new one dropping in.
    var swapping = false
    let pick: (LiveActivityItem) -> Void
    @ViewBuilder let content: (LiveActivityItem) -> Content

    @State private var dragOffset: CGFloat = 0
    @State private var lastMove = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        ZStack {
            // No "card behind the card" depth cue here. A full-width shape
            // drawn behind the content is bisected by the black rectangle
            // that masks the physical notch cutout, so it renders as two
            // disembodied lines flanking the notch rather than as a stack.
            // The closed pill has no room for a page-dot row either, so the
            // stack stays discoverable by swiping rather than by ornament.
            if let item = selected {
                content(item)
                    .id(item.id)
                    // A drag's translation doesn't mirror in Arabic; an offset does.
                    .offset(x: layoutDirection == .rightToLeft ? -dragOffset : dragOffset)
                    .transition(reduceMotion ? AnyTransition.opacity
                                : swapping ? AnyTransition(.blurReplace)
                                : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: selected?.id)
        .animation(.smooth(duration: 0.3), value: items.count)
        .contentShape(Rectangle())
        // minimumDistance keeps taps (open the notch) working: this only claims deliberate horizontal drags.
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    lastMove = value.time
                    guard items.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragOffset = value.translation.width * 0.3
                }
                .onEnded { value in
                    // Back from where it was, not in a frame (with Reduce Motion, at once).
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0)) { dragOffset = 0 }
                    // Far enough, or let go mid-flick. The reported speed lingers after the
                    // pointer stops, so let go standing still, only the distance counts.
                    let flicked = value.time.timeIntervalSince(lastMove) < 0.08 && abs(value.velocity.width) > 150
                    guard items.count > 1,
                          abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 24 || flicked
                    else { return }
                    // Left for the next one, right in Arabic, as page swipes go (the bubble's on that side).
                    let next = (value.translation.width < 0) != (layoutDirection == .rightToLeft)
                    move(by: next ? 1 : -1)
                }
        )
    }

    private func move(by delta: Int) {
        guard let index = items.firstIndex(where: { $0.id == selected?.id }), items.indices.contains(index + delta) else { return }
        pick(items[index + delta])
    }
}
