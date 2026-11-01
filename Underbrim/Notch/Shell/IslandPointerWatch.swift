//
//  IslandPointerWatch.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Hover for the island. Where nothing is drawn, macOS sends mouse events to what's underneath (the
//  menu bar beside the notch), so onHover can miss the pointer leaving and coming back. This follows
//  the pointer itself (no permission needed), listening beyond the app only while it's on the island:
//  listening all the time costs ~4% of a core whenever the mouse moves.
//

import AppKit
import SwiftUI

@MainActor
final class IslandPointerWatch {
    /// Its closing stops the watch: the stored handlers hold the view that owns it, so nothing else would.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.window = nil }
                }
            }
            if window == nil { stop() }
        }
    }
    var islandFrame: CGRect = .zero {
        didSet {
            guard islandFrame != oldValue else { return }
            frameChangedAt = .now
            nearestWhileHeld = nil
        }
    }
    /// A menu item changed the island's page (Token History, Edit Widgets): it stays open as if the
    /// pointer were still on it, until the pointer is on the new page or heads away from it. The item
    /// lies outside the island, and the new page may be smaller, so the pointer is off it without having left.
    private(set) var heldAfterMenu = false
    private var heldSince = Date.distantPast
    /// How near the pointer has come to the island during the hold, since its frame last settled: the
    /// page growing or shrinking under a still pointer isn't the pointer moving.
    private var nearestWhileHeld: CGFloat?
    private var frameChangedAt = Date.distantPast
    /// The open island's last frame, and when the pointer leaving closed it: for a moment after,
    /// the outline still on screen counts, so coming straight back catches it as it closes.
    var openFrame: CGRect = .zero
    var openBottomRadius = NotchMetrics.openBottomRadius
    var leftOpenAt = Date.distantPast
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private(set) var inside: Bool?
    private var contains: ((CGPoint) -> Bool)?
    private var onChange: ((Bool) -> Void)?
    private var onHoldDropped: (() -> Void)?

    /// Calls `onChange` when the pointer crosses the outline `contains` tests (island frame coordinates),
    /// and `onHoldDropped` when it heads away during a menu's hold, instead of coming to the new page.
    func start(contains: @escaping (CGPoint) -> Bool, onChange: @escaping (Bool) -> Void,
               onHoldDropped: @escaping () -> Void = {}) {
        stop()
        self.contains = contains
        self.onChange = onChange
        self.onHoldDropped = onHoldDropped
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.update()
            return event
        }
        update()  // where the pointer is now, without reporting it
        // Not measured yet: still a baseline, so the first hover reports.
        if inside == nil { inside = false }
    }

    func stop() {
        for monitor in [localMonitor, globalMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
        globalMonitor = nil
        inside = nil
        contains = nil
        onChange = nil
        onHoldDropped = nil
        heldAfterMenu = false
    }

    func holdAfterMenu() {
        guard contains != nil else { return }
        heldAfterMenu = true
        heldSince = .now
        nearestWhileHeld = nil
        // The pointer is off the island, over other apps: follow it there to see which way it goes.
        followMovesElsewhere(true)
    }

    /// The island closed: a hold for its page goes with it.
    func releaseMenuHold() {
        heldAfterMenu = false
    }

    /// Reports a crossing from where the pointer is now; the only source of hover state, so just call it.
    func update() {
        guard let window, let contains, islandFrame.width > 0 else { return }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let now = Self.isOnIsland(point, windowSize: window.frame.size, islandFrame: islandFrame, contains: contains)
        // Measured once the island has stopped changing shape for the new page: on it, leaving closes it
        // again; heading away from it, the island closes as if the pointer had left.
        var dropped = false
        if heldAfterMenu, Date.now.timeIntervalSince(max(heldSince, frameChangedAt)) > Self.settle {
            let distance = Self.distance(of: point, windowSize: window.frame.size, islandFrame: islandFrame)
            if now {
                heldAfterMenu = false
            } else if let nearest = nearestWhileHeld, distance > nearest + Self.headingAway {
                heldAfterMenu = false
                dropped = true
            } else {
                nearestWhileHeld = min(nearestWhileHeld ?? distance, distance)
            }
        }
        if now != inside {
            let first = inside == nil
            inside = now
            if !first { onChange?(now) }
        }
        // Moves elsewhere go to other apps: follow them only while on the island, or held for it.
        followMovesElsewhere(now || heldAfterMenu)
        if dropped { onHoldDropped?() }
    }

    private func followMovesElsewhere(_ follow: Bool) {
        if follow, globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        } else if !follow, let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
}

extension EnvironmentValues {
    /// The island's pointer watch, for a menu item that changes the island's page (`holdAfterMenu()`);
    /// nil outside the island.
    @Entry var islandPointerWatch: IslandPointerWatch? = nil
}

extension IslandPointerWatch {
    /// How long the island's frame must stay put before the pointer on it counts as being on the new page:
    /// a page change lays out on the next update, then springs to its size.
    static let settle: TimeInterval = 0.15
    /// How much farther than its nearest the pointer goes before a menu's hold counts it as heading away:
    /// more than a hand's drift while reading the new page.
    static let headingAway: CGFloat = 40

    /// How far `point` (window coordinates) is from the island's frame; 0 on it.
    nonisolated static func distance(of point: CGPoint, windowSize: CGSize, islandFrame: CGRect) -> CGFloat {
        let x = point.x, y = windowSize.height - point.y
        let dx = max(islandFrame.minX - x, 0, x - islandFrame.maxX)
        let dy = max(islandFrame.minY - y, 0, y - islandFrame.maxY)
        return hypot(dx, dy)
    }

    /// `point` in window coordinates (bottom-left origin); `contains` takes the island frame's (top-left origin).
    nonisolated static func isOnIsland(_ point: CGPoint, windowSize: CGSize, islandFrame: CGRect,
                                       contains: (CGPoint) -> Bool) -> Bool {
        // Half a point down: the screen's top row converts to y == height, the outline's edge, where a flung pointer stops.
        contains(CGPoint(x: point.x - islandFrame.minX, y: windowSize.height - point.y - islandFrame.minY + 0.5))
    }
}

struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
