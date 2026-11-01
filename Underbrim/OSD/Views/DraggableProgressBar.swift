//
//  DraggableProgressBarView.swift
//  Underbrim
//
//  Created by Alexander on 2026-02-07.
//

import AppKit
import Defaults
import SwiftUI

/// The HUD's level: a capsule filled to it, to drag, and with `scrolls` to scroll with two
/// fingers or a mouse wheel. A thick one carries the symbol in its low end.
struct DraggableProgressBar: View {
    @Binding var value: CGFloat
    var onChange: ((CGFloat) -> Void)?
    var accentColor: Color?
    var height: CGFloat = 6
    /// Drawn in the low end, dark where the level covers it.
    var symbol: String?
    var scrolls = false
    /// What VoiceOver calls it ("Volume", "Brightness"…).
    var name: String
    var dragging: (Bool) -> Void = { _ in }

    @GestureState private var pressed = false
    /// The level under the pointer while it drags, so a device reporting a moment late can't pull it back.
    @State private var dragged: CGFloat?
    @State private var width: CGFloat = 0

    private var level: CGFloat {
        let level = dragged ?? value
        return level.isFinite ? min(max(level, 0), 1) : 0
    }

    /// A HUD level's colour: the event's accent, else the notch's accent, or white with it off.
    static func tint(_ accent: Color?) -> Color {
        accent ?? (Defaults[.systemEventIndicatorUseAccent] ? .notchAccent : .white)
    }

    private var tint: Color { Self.tint(accentColor) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18))
                Rectangle().fill(tint).frame(width: geo.size.width * level)
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, pressed, _ in pressed = true }
                    .onChanged { drag in
                        let level = min(max(drag.location.x / max(geo.size.width, 1), 0), 1)
                        dragged = level
                        set(level)
                    }
            )
        }
        .frame(height: height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The same in every language, as the HUD around it: drawn and measured from the left (a
        // click's location doesn't mirror, though `.leading` would).
        .environment(\.layoutDirection, .leftToRight)
        .overlay(alignment: .leading) {
            if let symbol {
                let inset = (height - 14) / 2
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(width * level > inset + 7 ? Color.black : .white.opacity(0.7))
                    .padding(.leading, inset)
                    .allowsHitTesting(false)
            }
        }
        .background { if scrolls { ScrollWheel(scrolled: scrolled) } }
        .onChange(of: pressed) { _, pressed in
            if !pressed { dragged = nil }
            dragging(pressed)
        }
        // Gone mid-drag, its gesture may end without a word.
        .onDisappear { dragging(false) }
        // A drag on shapes is nothing to VoiceOver: a slider stands in for it, stepping by a twentieth.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(level) }, set: { set(CGFloat($0)) }), in: 0...1, step: 0.05)
        }
        .accessibilityLabel(name)
        .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }

    private func set(_ level: CGFloat) {
        let level = min(max(level, 0), 1)
        guard level != value else { return }
        value = level
        onChange?(level)
    }

    /// Fingers (or the wheel) up, or toward the full end: more. A trackpad moves it as far as a drag of
    /// the same length; a wheel's notch is a key press's step. The glide after the fingers lift doesn't count.
    private func scrolled(_ event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let natural: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let up = event.scrollingDeltaY * natural
        let toward = -event.scrollingDeltaX * natural
        let amount = abs(up) >= abs(toward) ? up : toward
        guard amount != 0 else { return }
        set(value + (event.hasPreciseScrollingDeltas ? amount / max(width, 1) : amount / 16))
    }
}

private struct ScrollWheel: NSViewRepresentable {
    let scrolled: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.scrolled = scrolled }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    func makeCoordinator() -> Coordinator { Coordinator(scrolled: scrolled) }

    @MainActor final class Coordinator {
        var scrolled: (NSEvent) -> Void
        private var monitor: Any?

        init(scrolled: @escaping (NSEvent) -> Void) { self.scrolled = scrolled }

        func start(in view: NSView) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                MainActor.assumeIsolated {
                    if let view, event.window != nil, event.window === view.window { self?.scrolled(event) }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
