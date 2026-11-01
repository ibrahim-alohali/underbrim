//
//  PageSwipe.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Two fingers sideways over the open island change page in the tab bar's order (compact mode:
//  widgets). A row that can still scroll that way, or a slider, takes the swipe. Two fingers up
//  set a question aside, where the island offers that; other vertical scrolls, a mouse wheel and
//  the glide after the fingers lift are left alone.
//

import AppKit
import Defaults
import os
import SwiftUI

enum SwipePage: Hashable {
    case view(NotchViews)
    case widget(HomeWidget)
    case ask(String)
}

@MainActor @Observable
final class PageSwipe {
    static let shared = PageSwipe()

    /// How far the open page is pulled, in points on screen (right is positive).
    private(set) var pull: CGFloat = 0
    /// How far it's raised by two fingers going up, in points.
    private(set) var raise: CGFloat = 0
    /// The side of the screen a page brought by a swipe comes in from: 1 the right, -1 the left, 0 none.
    private(set) var entering: CGFloat = 0

    /// Set by the open notch: its window, its pages in the tab bar's order (none when it can't change
    /// page), the one on show, whether a window point (top-left origin) is on the island, and how to show another.
    @ObservationIgnored private(set) weak var window: NSWindow?
    @ObservationIgnored private var pages: () -> [SwipePage] = { [] }
    @ObservationIgnored private var current: () -> SwipePage = { .view(.home) }
    @ObservationIgnored private var onIsland: (CGPoint) -> Bool = { _ in false }
    @ObservationIgnored private var show: (SwipePage) -> Void = { _ in }
    /// What two fingers up do on the island now, if anything; it says whether the island stayed open.
    @ObservationIgnored private var lift: () -> (() -> Bool)? = { nil }

    /// Controls that keep the swipes over them (window coordinates, top-left origin), and what
    /// they do with one: how far the fingers have moved (right is positive), and whether they lifted.
    private struct Keeper {
        var frame: CGRect
        var swiped: ((CGFloat, Bool) -> Void)?
    }
    @ObservationIgnored private var keepers: [UUID: Keeper] = [:]

    /// Rows that scroll sideways (window coordinates, top-left origin), and which ways they still can.
    struct Room: Equatable {
        /// Toward the start (the left, or the right in Arabic), and toward the end.
        var back = false, ahead = false
    }
    private struct Row {
        var frame: CGRect?
        var room = Room()
    }
    @ObservationIgnored private var rows: [UUID: Row] = [:]
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var swipe: Swipe?
    /// The last swipe was the page's: the glide after it isn't for a row underneath.
    @ObservationIgnored private var pageGlides = false
    /// A swipe whose end never came (the pointer left the window): let go of it.
    @ObservationIgnored private var stall: DispatchWorkItem?
    @ObservationIgnored private let log = Logger(subsystem: bundleIdentifier, category: "swipe")

    private struct Swipe {
        enum Owner: Equatable { case undecided, page, lift, keeper(UUID), other }
        var owner = Owner.undecided
        var travel: CGFloat = 0
        var speed: CGFloat = 0
        var last: TimeInterval
    }

    /// This far, or flicked faster than `flick` points a second, and a swipe changes the page.
    static let distance: CGFloat = 50
    static let flick: CGFloat = 700

    func start(window: NSWindow, pages: @escaping () -> [SwipePage], current: @escaping () -> SwipePage,
               onIsland: @escaping (CGPoint) -> Bool, lift: @escaping () -> (() -> Bool)?,
               show: @escaping (SwipePage) -> Void) {
        // Kept from a lift that closed the island (see stop): the new page starts level, not sliding down
        // on the opening's spring.
        if raise != 0 {
            var level = Transaction()
            level.disablesAnimations = true
            withTransaction(level) { raise = 0 }
        }
        self.window = window
        self.pages = pages
        self.current = current
        self.onIsland = onIsland
        self.lift = lift
        self.show = show
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    /// The notch closed (only the one that started it stops it). A raised page stays raised while it
    /// fades out, rather than dropping back against the fingers; the next open levels it.
    func stop(window: NSWindow?) {
        guard window === self.window else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        swipe = nil
        stall?.cancel()
        if pull != 0 { pull = 0 }
        entering = 0
    }

    func keep(_ id: UUID, frame: CGRect?, swiped: ((CGFloat, Bool) -> Void)? = nil) {
        keepers[id] = frame.map { Keeper(frame: $0, swiped: swiped) }
    }

    func row(_ id: UUID, frame: CGRect?) { rows[id, default: Row()].frame = frame }
    func row(_ id: UUID, room: Room) { rows[id, default: Row()].room = room }
    func forget(row id: UUID) { rows[id] = nil }

    // MARK: Events

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        if !event.momentumPhase.isEmpty { return pageGlides ? nil : event }
        if event.phase.contains(.began) {
            swipe = Swipe(last: event.timestamp)
            pageGlides = false
        }
        guard var swipe else { return event }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            end(swipe, cancelled: event.phase.contains(.cancelled))
            return swipe.owner == .other || swipe.owner == .undecided ? event : nil
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if swipe.owner == .undecided {
            guard dx != 0 || dy != 0 else { return event }
            swipe.owner = decide(event, dx: dx, dy: dy)
        }
        guard swipe.owner != .other else {
            self.swipe = swipe
            return event
        }
        // The fingers' own way, whatever the scrolling direction setting: right, or up for a lift, is positive.
        let fingers = swipe.owner == .lift ? Self.up(dy, event) : dx * (event.isDirectionInvertedFromDevice ? 1 : -1)
        let elapsed = max(event.timestamp - swipe.last, 0.004)
        swipe.speed = 0.6 * fingers / elapsed + 0.4 * swipe.speed
        swipe.travel += fingers
        swipe.last = event.timestamp
        self.swipe = swipe
        switch swipe.owner {
        case .page: pull = pulled(swipe.travel)
        case .lift: raise = Self.raised(swipe.travel)
        case .keeper(let id): keepers[id]?.swiped?(swipe.travel, false)
        default: break
        }
        stall?.cancel()
        let stall = DispatchWorkItem { [weak self] in
            guard let self, let swipe = self.swipe else { return }
            self.end(swipe, cancelled: true)
        }
        self.stall = stall
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: stall)
        return nil
    }

    /// Whose swipe it is, from its first move: up on the island, the lift's unless a scroll there can
    /// still move that way; sideways, a slider's if one is under the fingers, a row's if the one there
    /// can still scroll that way, else the page's.
    private func decide(_ event: NSEvent, dx: CGFloat, dy: CGFloat) -> Swipe.Owner {
        guard let content = window?.contentView else { return .other }
        let point = event.locationInWindow
        let top = CGPoint(x: point.x, y: content.bounds.height - point.y)
        guard onIsland(top) else { return .other }
        if abs(dy) >= abs(dx) {
            guard Self.up(dy, event) > 0, lift() != nil, !scrolls(at: point, in: content, vertically: dy) else { return .other }
            log.debug("swipe: a lift")
            return .lift
        }
        guard pages().count > 1 else { return .other }
        if let keeper = keepers.first(where: { $0.value.frame.contains(top) }) {
            log.debug("swipe: a slider's")
            return .keeper(keeper.key)
        }
        // A positive delta shows more of what's to the left: the start, or the end in Arabic.
        let leftward = dx > 0, rightToLeft = NSApp.userInterfaceLayoutDirection == .rightToLeft
        if rows.values.contains(where: { row in
            guard let frame = row.frame, frame.contains(top) else { return false }
            return leftward != rightToLeft ? row.room.back : row.room.ahead
        }) {
            log.debug("swipe: a row's")
            return .other
        }
        // A row AppKit draws. hitTest takes the point in the view's superview: the content view's own space is flipped.
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.frame.width > scroll.contentView.bounds.width + 0.5 {
                let visible = scroll.contentView.documentVisibleRect
                let more = leftward ? visible.minX > document.frame.minX + 0.5 : visible.maxX < document.frame.maxX - 0.5
                if more {
                    log.debug("swipe: a row's")
                    return .other
                }
            }
            view = current.superview
        }
        log.debug("swipe: the page's")
        return .page
    }

    /// A scroll view under the fingers that can still move the way they go (AppKit's, or SwiftUI's on top of one).
    private func scrolls(at point: CGPoint, in content: NSView, vertically dy: CGFloat) -> Bool {
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        while let current = view {
            if let scroll = current as? NSScrollView, let document = scroll.documentView,
               document.frame.height > scroll.contentView.bounds.height + 0.5 {
                let visible = scroll.contentView.documentVisibleRect
                // A negative delta brings up what's below.
                let towardEnd = dy < 0
                let lower = document.isFlipped ? visible.maxY < document.frame.maxY - 0.5 : visible.minY > document.frame.minY + 0.5
                let upper = document.isFlipped ? visible.minY > document.frame.minY + 0.5 : visible.maxY < document.frame.maxY - 0.5
                if towardEnd ? lower : upper { return true }
            }
            view = current.superview
        }
        return false
    }

    private func end(_ swipe: Swipe, cancelled: Bool) {
        self.swipe = nil
        stall?.cancel()
        switch swipe.owner {
        case .page:
            pageGlides = true
            finish(swipe, cancelled: cancelled)
        case .lift:
            pageGlides = true
            finishLift(swipe, cancelled: cancelled)
        case .keeper(let id):
            keepers[id]?.swiped?(swipe.travel, true)
        default: break
        }
    }

    // MARK: Moving

    /// The page to the fingers' side: they go left for the next one (right in Arabic).
    private func neighbour(for travel: CGFloat) -> SwipePage? {
        let pages = pages()
        guard travel != 0, let index = pages.firstIndex(of: current()) else { return nil }
        let rightToLeft = NSApp.userInterfaceLayoutDirection == .rightToLeft
        let target = index + ((travel < 0) != rightToLeft ? 1 : -1)
        return pages.indices.contains(target) ? pages[target] : nil
    }

    /// How far fingers went up in a scroll event, whatever the scrolling direction setting.
    private static func up(_ dy: CGFloat, _ event: NSEvent) -> CGFloat {
        dy * (event.isDirectionInvertedFromDevice ? -1 : 1)
    }

    /// The page follows the fingers up a little, and barely down.
    private static func raised(_ travel: CGFloat) -> CGFloat {
        let reach: CGFloat = travel > 0 ? 24 : 6
        return reach * tanh(travel / (reach * 2.5))
    }

    private func finishLift(_ swipe: Swipe, cancelled: Bool) {
        let flicked = swipe.speed > Self.flick && swipe.travel > 12
        guard !cancelled, swipe.travel >= Self.distance || flicked, let lift = lift() else {
            withAnimation(Self.springBack) { raise = 0 }
            return
        }
        log.debug("swipe: lifted")
        if Defaults[.enableHaptics] { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        DispatchQueue.main.async { [self] in
            // Held open, the page underneath comes in level; closed, the page fades out where the fingers left it.
            if lift() { withAnimation(StandardAnimations.close) { raise = 0 } }
        }
    }

    /// A page let go short of changing goes back with a slight settle; with Reduce Motion, straight back.
    private static var springBack: Animation {
        StandardAnimations.reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.15)
    }

    private func pulled(_ travel: CGFloat) -> CGFloat {
        let reach: CGFloat = neighbour(for: travel) == nil ? 14 : 56
        return reach * tanh(travel / (reach * 2.5))
    }

    private func finish(_ swipe: Swipe, cancelled: Bool) {
        let flicked = abs(swipe.speed) > Self.flick && abs(swipe.travel) > 12 && (swipe.speed < 0) == (swipe.travel < 0)
        guard !cancelled, abs(swipe.travel) >= Self.distance || flicked, let target = neighbour(for: swipe.travel) else {
            withAnimation(Self.springBack) { pull = 0 }
            return
        }
        log.debug("swipe: to \(String(describing: target), privacy: .public)")
        if Defaults[.enableHaptics] { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        // The new page comes from the side the fingers left, set a moment early so the old page leaves with it.
        entering = swipe.travel < 0 ? 1 : -1
        DispatchQueue.main.async { [self] in
            withAnimation(StandardAnimations.open) {
                pull = 0
                show(target)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                if self.swipe == nil { entering = 0 }
            }
        }
    }
}

extension View {
    /// For the open page: pulled along by two fingers; only this part of the notch updates as they move.
    func followsPageSwipe() -> some View {
        modifier(SwipePull())
    }

    func scrollsBeforePages() -> some View {
        modifier(SwipeRow())
    }

    /// For a slider: two fingers over it are its own; `swiped` gets how far they've moved and whether they lifted.
    func keepsSwipes(_ swiped: ((CGFloat, Bool) -> Void)? = nil) -> some View {
        modifier(SwipeKeeper(swiped: swiped))
    }
}

private struct SwipeKeeper: ViewModifier {
    let swiped: ((CGFloat, Bool) -> Void)?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                PageSwipe.shared.keep(id, frame: frame, swiped: swiped)
            }
            .onDisappear { PageSwipe.shared.keep(id, frame: nil) }
    }
}

private struct SwipePull: ViewModifier {
    func body(content: Content) -> some View {
        let swipe = PageSwipe.shared
        // Offsets mirror in Arabic; the pull is on screen.
        content.offset(x: NSApp.userInterfaceLayoutDirection == .rightToLeft ? -swipe.pull : swipe.pull, y: -swipe.raise)
    }
}

private struct SwipeRow: ViewModifier {
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: PageSwipe.Room.self) { geometry in
                    let visible = geometry.visibleRect
                    return .init(back: visible.minX > 0.5, ahead: visible.maxX < geometry.contentSize.width - 0.5)
                } action: { _, room in
                    PageSwipe.shared.row(id, room: room)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    PageSwipe.shared.row(id, frame: frame)
                }
                .onDisappear { PageSwipe.shared.forget(row: id) }
        } else {
            content
        }
    }
}
