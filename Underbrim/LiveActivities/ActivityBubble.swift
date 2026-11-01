//
//  ActivityBubble.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Two at once, the iPhone way: the next activity sits in a round bubble beside the island. Pointing
//  at it says what it is, clicking opens its page, pulling it into the island swaps the two.
//

import AppKit
import SwiftUI

struct ActivityBubble: View {
    let item: LiveActivityItem
    /// The island's height: the bubble is as tall as the island, like the iPhone's.
    let size: CGFloat
    let open: () -> Void
    let swap: () -> Void
    /// A drag starts or ends (the island mustn't open under it).
    var dragging: (Bool) -> Void = { _ in }

    @State private var hovering = false
    @State private var pull: CGFloat = 0
    /// Held by a drag; back to false however the drag ends, a cancelled one included.
    @GestureState private var held = false
    @State private var swapped = false
    /// Its label only while it sits still: pulled, it's just the round bubble going in.
    private var labelled: Bool { hovering && !held && pull == 0 }
    @Environment(\.layoutDirection) private var layoutDirection
    private var glyphSize: CGFloat { max(0, size - 12) }
    /// Let go this far in (or flicked as far), it swaps.
    private var reach: CGFloat { size * 0.6 }

    var body: some View {
        HStack(spacing: 6) {
            glyph
                .frame(width: glyphSize, height: glyphSize)
            if labelled {
                label
                    .font(.notchCaption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.trailing, labelled ? 4 : 0)
        .frame(minWidth: size, minHeight: size, maxHeight: size)
        .background(Capsule().fill(.black))
        .contentShape(Capsule())
        .scaleEffect(1 - 0.2 * min(pull / reach, 1), anchor: .leading)
        .offset(x: -pull)
        .onHover { inside in withAnimation(.smooth(duration: 0.25)) { hovering = inside } }
        .onTapGesture(perform: open)
        .gesture(
            // On screen, not in the view: a local drag mirrors in Arabic.
            // Grabbed, its label goes at once rather than sliding over the island.
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .updating($held) { _, held, _ in held = true }
                .onChanged { value in pull = towardIsland(value.translation.width) }
                .onEnded { value in
                    dragging(false)
                    letGo(flicked: towardIsland(value.predictedEndTranslation.width))
                }
        )
        .onChange(of: held) { _, held in
            dragging(held)
            // Cancelled rather than let go: back where it was.
            if !held, !swapped, pull != 0 { withAnimation(.spring(duration: 0.3)) { pull = 0 } }
        }
        .background(TrackpadSwipe(active: hovering) { travel in
            pull = towardIsland(travel)
        } ended: {
            letGo(flicked: pull)
        })
        .contextMenu { Button(String(localized: "Show in Island"), action: swap) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.spokenText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: Text("Show in Island"), swap)
    }

    /// The part of a sideways move toward the island, on the bubble's leading side (the offset mirrors itself).
    private func towardIsland(_ dx: CGFloat) -> CGFloat {
        max(0, layoutDirection == .rightToLeft ? dx : -dx)
    }

    /// Far enough in and it swaps, shrinking into the island; otherwise it springs back.
    private func letGo(flicked: CGFloat) {
        if max(pull, flicked) >= reach {
            swapped = true
            swap()
        } else {
            withAnimation(.spring(duration: 0.3)) { pull = 0 }
        }
    }

    /// Its closed view's icon (a download's progress ring, a muted call's crossed-out mic).
    @ViewBuilder private var glyph: some View {
        switch item {
        case .agent(let summary):
            AppIconView(bundleID: summary.hostBundleID ?? summary.provider.defaultHostBundleID, size: glyphSize)
        case .call(let call):
            Image(systemName: CallActivity.shared.muted ? "mic.slash.fill" : call.symbol)
                .font(.notchSymbol(size: 12))
                .foregroundStyle(CallActivity.shared.muted ? .red : call.tint)
        case .timer:
            Image(systemName: TimerModel.shared.isFinished ? "checkmark.circle.fill"
                  : TimerModel.shared.mode == .stopwatch ? "stopwatch" : "timer")
                .font(.notchSymbol(size: 12))
                .foregroundStyle(TimerModel.shared.isFinished ? Color.white : Color.notchAccent)
        case .download(let summary):
            DownloadProgressRing(id: summary.id, state: summary.state)
        case .meeting(let meeting):
            Image(systemName: meeting.link == nil ? "calendar" : "video.fill")
                .font(.notchSymbol(size: 12))
                .foregroundStyle(Color(nsColor: meeting.calendarColor))
        case .phone(let activity):
            ActivityBadge(symbol: activity.symbol, tint: activity.tint, size: glyphSize)
        case .delivery(let order):
            ActivityBadge(symbol: order.look.symbol, tint: order.look.tint, size: glyphSize)
        case .notification(let notification):
            NotificationSourceIcon(bundleID: notification.bundleID, size: glyphSize)
        case .headphones(let device):
            Image(systemName: device.symbol)
                .font(.notchSymbol(size: 12))
                .foregroundStyle(.white)
        case .prayer(let moment):
            Image(systemName: moment.name.symbol)
                .font(.notchSymbol(size: 12))
                .foregroundStyle(Color.notchAccent)
        case .music:
            Image(nsImage: MusicManager.shared.albumArt)
                .resizable().scaledToFill()
                .clipShape(Circle())
        }
    }

    @ViewBuilder private var label: some View {
        switch item {
        case .call(let call):
            Text(verbatim: "\(AppInfo.name(bundleID: call.app) ?? call.app) · ") + Text(call.since, style: .timer)
        case .timer:
            TimerTicks { date in
                Text(TimerModel.shared.isFinished ? String(localized: "Done")
                     : TimerModel.format(TimerModel.shared.shownSeconds(at: date)))
            }
        default:
            item.spokenText
        }
    }
}

extension LiveActivityItem {
    /// One line on what it is and how it's going: the hover text and what VoiceOver reads.
    @MainActor var spokenText: Text {
        switch self {
        case .notification(let notification):
            if let app = notification.appName, let title = notification.title {
                // A format, so Arabic can run it right to left (a plain "WhatsApp: …" runs left to right).
                Text("\(app): \(title)")
            } else {
                Text(notification.appName ?? notification.title ?? "")
            }
        case .agent(let summary):
            Text(summary.accessibilityText)
        case .meeting(let meeting):
            Text("\(meeting.title), ") + Text(meeting.start, style: .relative)
        case .download(let summary):
            Text(summary.spokenText)
        case .headphones(let device):
            Text(device.accessibilityText)
        case .timer:
            Text(TimerModel.shared.spokenState)
        case .phone(let activity):
            Text(activity.spokenDescription)
        case .delivery(let order):
            Text(order.spokenDescription(at: .now))
        case .call(let call):
            Text(call.spokenText)
        case .prayer(let moment):
            Text(moment.spokenText(in: PrayerFormat.zone(PrayerTimesStore.shared.place)))
        case .music:
            Text([MusicManager.shared.songTitle, MusicManager.shared.artistName].filter { !$0.isEmpty }.joined(separator: " — "))
        }
    }
}

/// Two fingers sideways over the bubble: travel (right is positive, whatever the scroll setting), then the lift.
private struct TrackpadSwipe: NSViewRepresentable {
    let active: Bool
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.swipe = self }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    func makeCoordinator() -> Coordinator { Coordinator(swipe: self) }

    @MainActor final class Coordinator {
        var swipe: TrackpadSwipe
        private var monitor: Any?
        /// Set while a swipe that began on the bubble goes on.
        private var travel: CGFloat?

        init(swipe: TrackpadSwipe) { self.swipe = swipe }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            // The fingers only: not the glide after they lift, not a mouse wheel.
            guard event.momentumPhase.isEmpty, !event.phase.isEmpty else { return }
            if event.phase.contains(.began) { travel = swipe.active ? 0 : nil }
            guard var travel else { return }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                self.travel = nil
                swipe.ended()
                return
            }
            travel += event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
            self.travel = travel
            swipe.changed(travel)
        }
    }
}
