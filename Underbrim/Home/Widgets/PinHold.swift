//
//  PinHold.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Holding a widget pins it as the island alone; holding it pinned unpins it. The first 0.2 s show
//  nothing, so a click stays a click; then a ring runs round the widget for 0.4 s. Let go or move
//  away before it closes and it all eases back.
//
//  The mouse is watched in the island's window before anything in it sees the press, so the
//  widgets' own buttons, drags and menus still work and the release that ends a hold is kept from
//  the button under it. Text that can be typed into is left to itself.
//

import AppKit
import SwiftUI

@MainActor @Observable
final class PinHold {
    static let quiet: TimeInterval = 0.2
    static let fill: TimeInterval = 0.4
    /// From the ring closing to the island changing: the flash and the click land first.
    static let settle: TimeInterval = 0.22
    static let ease: TimeInterval = 0.18
    /// The pointer may stray this far while holding.
    static let slop: CGFloat = 6

    private(set) var target: HomeWidget?
    private(set) var view: UUID?
    private(set) var unpinning = false
    private(set) var armed = false
    private(set) var pressedAt = Date.distantPast
    private(set) var committedAt: Date?
    private(set) var cancelled: (at: Date, progress: Double)?

    @ObservationIgnored var allowed: () -> Bool = { false }
    /// Each widget's frame in the island's window (SwiftUI's global space there), by the view
    /// showing it: Home's and the pinned one overlap while one hands over to the other.
    @ObservationIgnored var frames: [UUID: (widget: HomeWidget, frame: CGRect)] = [:]
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var steps: Task<Void, Never>?
    @ObservationIgnored private var start = CGPoint.zero
    @ObservationIgnored private var swallowing = false

    func progress(at date: Date) -> Double {
        if committedAt != nil { return 1 }
        if let cancelled { return cancelled.progress * max(0, 1 - date.timeIntervalSince(cancelled.at) / Self.ease) }
        return min(1, max(0, (date.timeIntervalSince(pressedAt) - Self.quiet) / Self.fill))
    }

    var showing: Bool { target != nil && (armed || committedAt != nil || cancelled != nil) }

    func watch(_ window: NSWindow?) {
        guard window !== self.window || monitor == nil else { return }
        self.window = window
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        switch event.type {
        case .leftMouseDown:
            guard target == nil, allowed(), let point = point(of: event, in: window), !overText(event, in: window),
                  let pressed = frames.first(where: { $0.value.frame.contains(point) }) else { return event }
            begin(pressed.value.widget, view: pressed.key, at: point)
            return event
        case .leftMouseDragged:
            if swallowing { return nil }
            if target != nil, committedAt == nil, cancelled == nil, let point = point(of: event, in: window),
               hypot(point.x - start.x, point.y - start.y) > Self.slop { cancel() }
            return event
        case .leftMouseUp:
            if swallowing {
                swallowing = false
                return nil
            }
            if target != nil, committedAt == nil, cancelled == nil { cancel() }
            return event
        default:
            return event
        }
    }

    private func begin(_ widget: HomeWidget, view: UUID, at point: CGPoint) {
        steps?.cancel()
        target = widget
        self.view = view
        unpinning = WidgetPin.shared.widget == widget
        start = point
        pressedAt = .now
        armed = false
        committedAt = nil
        cancelled = nil
        steps = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(Self.quiet))) != nil, let self else { return }
            // Let go where the release didn't reach the watch (a view tracking the mouse itself keeps it).
            guard Self.held else { return self.reset() }
            withAnimation(.easeOut(duration: Self.fill)) { self.armed = true }
            guard (try? await Task.sleep(for: .seconds(Self.fill))) != nil else { return }
            guard Self.held else { return self.cancel() }
            self.commit()
        }
    }

    private func commit() {
        guard let widget = target else { return }
        committedAt = .now
        swallowing = true
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        steps = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(Self.settle))) != nil, let self else { return }
            if self.unpinning { WidgetPin.shared.set(nil) } else { WidgetPin.shared.set(widget) }
            // The pressed view has gone with the change (the one that replaces it shows none of this).
            guard (try? await Task.sleep(for: .seconds(0.4))) != nil else { return }
            self.reset()
        }
    }

    private static var held: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    /// Let go, or moved, before the ring closed: before it showed, nothing happened; after, it eases back.
    private func cancel() {
        steps?.cancel()
        guard armed else { return reset() }
        cancelled = (.now, progress(at: .now))
        withAnimation(.easeOut(duration: Self.ease)) { armed = false }
        steps = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(Self.ease))) != nil else { return }
            self?.reset()
        }
    }

    private func reset() {
        steps?.cancel()
        steps = nil
        target = nil
        view = nil
        armed = false
        committedAt = nil
        cancelled = nil
        swallowing = false
    }

    private func point(of event: NSEvent, in window: NSWindow) -> CGPoint? {
        guard let content = window.contentView else { return nil }
        let local = content.convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
    }

    /// Pressed in text that can be typed into: a click there types and a hold selects.
    private func overText(_ event: NSEvent, in window: NSWindow) -> Bool {
        // hitTest takes the point in the view's superview: the content view's own space is flipped.
        guard let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        else { return false }
        return sequence(first: hit, next: \.superview).contains { view in
            (view as? NSTextView)?.isEditable ?? (view as? NSTextField)?.isEditable ?? false
        }
    }
}

extension View {
    func pinHoldTarget(_ widget: HomeWidget) -> some View { modifier(PinHoldTarget(widget: widget)) }
}

private struct PinHoldTarget: ViewModifier {
    let widget: HomeWidget
    @Environment(PinHold.self) private var hold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var id = UUID()

    private var dimmed: Double {
        guard let target = hold.target, target != widget, !hold.unpinning else { return 1 }
        return hold.committedAt != nil ? 0 : hold.armed ? 0.42 : 1
    }

    func body(content: Content) -> some View {
        let held = hold.view == id && hold.showing
        content
            .modifier(HoldLook(widget: widget, held: held, reduceMotion: reduceMotion))
            .opacity(dimmed)
            .animation(.easeOut(duration: hold.committedAt != nil ? 0.14 : 0.3), value: dimmed)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { hold.frames[id] = (widget, $0) }
            .onDisappear { hold.frames[id] = nil }
            .accessibilityAction(named: WidgetPin.shared.widget == widget ? String(localized: "Unpin \(widget.title)") : String(localized: "Pin Alone")) {
                WidgetPin.shared.toggle(widget)
            }
    }
}

private struct HoldLook: ViewModifier {
    let widget: HomeWidget
    let held: Bool
    let reduceMotion: Bool
    @Environment(PinHold.self) private var hold

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: !held)) { context in
            let look = Look(hold: hold, at: context.date, held: held, reduceMotion: reduceMotion)
            content
                .scaleEffect(look.scale)
                .overlay {
                    if held {
                        ZStack {
                            HoldRing().stroke(Color.notchAccent.opacity(0.16 * look.lit), lineWidth: 2)
                            HoldRing().trim(from: 0, to: look.ring).stroke(Color.notchAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .opacity(look.ringOpacity)
                                .brightness(look.flash)
                            HoldRing().stroke(Color.notchAccent.opacity(0.32 * look.lit), lineWidth: 6).blur(radius: 9)
                        }
                        .padding(-4)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if held, !hold.unpinning {
                        // Mostly over the widget: Home lets 6 pt past its row show while it scrolls.
                        HoldPin(look: look).offset(y: -6).allowsHitTesting(false)
                    }
                }
        }
    }

    struct Look {
        var scale: CGFloat = 1, ring: CGFloat = 0, lit: Double = 0, flash: Double = 0, ringOpacity: Double = 1
        var pin: CGFloat = 0, tilt: Double = -40, pinOpacity: Double = 0, tap: CGFloat = 1, ripple: Double = -1

        @MainActor init(hold: PinHold, at date: Date, held: Bool, reduceMotion: Bool) {
            guard held else { return }
            let u = hold.progress(at: date)
            let eased = 1 - pow(1 - u, 2)
            lit = eased
            ring = CGFloat(hold.unpinning ? 1 - u : (reduceMotion ? 1 : u))
            if reduceMotion { lit = u } else { scale = 1 - 0.03 * eased }
            // Draining (or, with Reduce Motion, whole from the start), the ring fades in and out instead.
            if reduceMotion || hold.unpinning { ringOpacity = hold.committedAt != nil ? 1 : lit }
            // The pin: grows in tilted, a little past full, upright as the ring closes.
            let s = Self.spring(u)
            pin = reduceMotion ? 1 : 0.2 + 0.8 * s
            tilt = reduceMotion ? 0 : -40 * (1 - s)
            pinOpacity = min(1, u * 4)
            if let committed = hold.committedAt {
                let t = date.timeIntervalSince(committed)
                flash = reduceMotion ? 0 : 0.6 * max(0, 1 - t / 0.26)
                tap = reduceMotion ? 1 : 1 + 0.22 * CGFloat(max(0, 1 - t / 0.2))
                ripple = reduceMotion ? -1 : min(1, t / 0.45)
            }
        }

        /// A spring's settle: over 1 a little before 1.
        static func spring(_ u: Double) -> CGFloat {
            CGFloat(1 - exp(-6 * u) * cos(7.5 * u))
        }
    }
}

private struct HoldPin: View {
    let look: HoldLook.Look

    var body: some View {
        ZStack {
            if look.ripple >= 0, look.ripple < 1 {
                Circle().stroke(Color.notchAccent, lineWidth: 2)
                    .scaleEffect(1 + 1.1 * look.ripple)
                    .opacity(0.9 * (1 - look.ripple))
            }
            Circle().fill(Color.notchAccent)
                .overlay {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .rotationEffect(.degrees(look.tilt))
                }
                .overlay(Circle().stroke(.black, lineWidth: 3))
        }
        .frame(width: 24, height: 24)
        .scaleEffect(look.pin * look.tap)
        .opacity(look.pinOpacity)
    }
}

struct HoldRing: Shape {
    var radius: CGFloat = NotchMetrics.innerRadius + 4

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Clockwise on screen in every language, from the top.
    var layoutDirectionBehavior: LayoutDirectionBehavior { .fixed }
}
