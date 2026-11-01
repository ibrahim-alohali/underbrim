//
//  HomeWidgetAlone.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A Home widget as the island on its own: pinned (WidgetPin), or the one compact mode shows. What
//  it says first sits in the band either side of the camera, and one row goes under the band.
//

import SwiftUI

struct HomeWidgetAlone: View {
    let widget: HomeWidget
    let albumArtNamespace: Namespace.ID
    let band: AloneBand
    @EnvironmentObject private var vm: NotchViewModel
    @ObservedObject private var coordinator = NotchViewCoordinator.shared

    var body: some View {
        Group {
            switch widget {
            case .nowPlaying: CompactHomeView(albumArtNamespace: albumArtNamespace)
            case .calendar: CalendarWidget(alone: true)
            case .mirror: MirrorAlone()
            case .quickLaunch:
                // Its apps in one row under the band: nothing beside the camera but its pin.
                AloneFrame(widget: .quickLaunch, rowAlignment: .center) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                } row: {
                    QuickLaunchWidget(columns: widget.size.quickLaunchColumns, style: .pinned, namespace: albumArtNamespace)
                }
            case .timer: TimerWidget(alone: true)
            case .shortcuts: ShortcutsWidget(alone: true)
            case .scratchpad: ScratchpadWidget(alone: true)
            case .system: SystemWidget(alone: true)
            case .reminders: RemindersWidget(alone: true)
            case .unread: UnreadWidget(alone: true)
            case .calls: CallsWidget(alone: true)
            case .prayer: PrayerWidget(locked: coordinator.screenLocked, alone: true)
            }
        }
        .environment(\.aloneBand, band)
        .contextMenu { PinMenu(widget: widget) }
    }
}

/// Where a widget alone has the band: the camera housing's gap, its height, and whether something
/// else has it for now (volume, a call). In compact mode, which widget this is, after a swipe.
struct AloneBand: Equatable {
    var gap: CGFloat = 0
    var height: CGFloat = 0
    /// No camera between the sides (the floating island): they reach the island's edges.
    var spans = false
    var taken = false
    var pages: Pages?
    var showsPages = false

    struct Pages: Equatable {
        var index: Int
        var count: Int
    }
}

extension EnvironmentValues {
    @Entry var aloneBand = AloneBand()
}

/// A widget alone: `leading` and `trailing` either side of the camera (the pin beside the camera
/// when pinned), and `row` under the band. Holding the row unpins it.
struct AloneFrame<Leading: View, Trailing: View, Row: View>: View {
    let widget: HomeWidget
    var rowAlignment: Alignment = .leading
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var row: Row
    @Environment(\.aloneBand) private var band

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            AroundCamera(gap: band.gap, spans: band.spans) {
                // After a swipe in compact mode, the dots in the title's place for a moment (laid out
                // all along, so the island keeps its size).
                ZStack(alignment: .leading) {
                    HStack(spacing: 6) { leading }
                        .opacity(band.taken || band.showsPages ? 0 : 1)
                    if let pages = band.pages {
                        PageDots(pages: pages)
                            .opacity(band.showsPages && !band.taken ? 1 : 0)
                    }
                }
                HStack(spacing: 6) {
                    if WidgetPin.shared.widget == widget {
                        PinMark(widget: widget)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) { trailing }
                        .opacity(band.taken ? 0 : 1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: band.height)
            .animation(.easeOut(duration: 0.15), value: band.taken)
            .animation(.easeOut(duration: 0.2), value: band.showsPages)
            row
                .frame(maxWidth: .infinity, alignment: rowAlignment)
                .pinHoldTarget(widget)
        }
        .lineLimit(1)
    }

    static var rowSpacing: CGFloat { 2 }
}

struct PageDots: View {
    let pages: AloneBand.Pages
    /// Goes a page on (1) or back (−1): VoiceOver can then adjust them. Without it they only say where it is.
    var step: ((Int) -> Void)?

    var body: some View {
        let dots = HStack(spacing: 4) {
            ForEach(0..<pages.count, id: \.self) { index in
                Circle()
                    .fill(index == pages.index ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityElement()
        let position = String(localized: "\(pages.index + 1) of \(pages.count)")
        if let step {
            dots
                .accessibilityLabel(String(localized: "Page"))
                .accessibilityValue(position)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
        } else {
            dots.accessibilityLabel(position)
        }
    }
}

/// The band's two sides, each as wide as the wider one (up to `widest`), either side of the housing's gap;
/// when it `spans`, as wide as it's offered, so a title has the room a camera would take.
struct AroundCamera: Layout {
    let gap: CGFloat
    var spans = false
    static let widest: CGFloat = 180

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { side in
            let ideal = side.sizeThatFits(.unspecified)
            return ideal.width > Self.widest ? side.sizeThatFits(ProposedViewSize(width: Self.widest, height: nil)) : ideal
        }
        let half = sizes.map(\.width).max() ?? 0
        let offered = spans ? proposal.width ?? 0 : 0
        return CGSize(width: max(2 * half + gap, offered), height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let half = max(0, (bounds.width - gap) / 2)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: index == 0 ? bounds.minX : bounds.maxX, y: bounds.midY),
                          anchor: index == 0 ? .leading : .trailing,
                          proposal: ProposedViewSize(width: index == 0 ? min(half, Self.widest) : half, height: bounds.height))
        }
    }
}

/// The mirror alone: the camera under the band. It runs while the pointer is on the island (ContentView).
struct MirrorAlone: View {
    @EnvironmentObject private var vm: NotchViewModel

    var body: some View {
        AloneFrame(widget: .mirror, rowAlignment: .center) {
            AloneTitle(symbol: HomeWidget.mirror.symbol, title: HomeWidget.mirror.title)
        } trailing: {
            EmptyView()
        } row: {
            CameraPreviewView(camera: vm.camera, island: vm, side: MusicPlayerView.height)
        }
    }
}

struct AloneTitle: View {
    let symbol: String
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.notchSymbol(size: 12))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
        Text(title)
            .font(.notchTitle)
            .foregroundStyle(.white)
    }
}

struct PinMark: View {
    let widget: HomeWidget
    @Environment(PinHold.self) private var hold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Down: once the island has made room, it comes in tilted and small, as the held widget's pin did.
    @State private var landed = false

    private var lifting: Bool { hold.target == widget && hold.unpinning && (hold.armed || hold.committedAt != nil) }

    var body: some View {
        NotchSymbolButton(symbol: "pin.fill", label: String(localized: "Unpin \(widget.title)"), size: 12, box: 24, tint: .notchAccent) {
            WidgetPin.shared.set(nil)
        }
        .rotationEffect(.degrees(lifting && !reduceMotion ? 40 : 0))
        .offset(y: lifting && !reduceMotion ? -3 : 0)
        .opacity(lifting ? 0.25 : 1)
        .animation(.easeIn(duration: PinHold.fill), value: lifting)
        .modifier(Land(amount: landed ? 0 : 1, reduceMotion: reduceMotion))
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.55).delay(0.12)) {
                landed = true
            }
        }
        .transition(.opacity.animation(.easeOut(duration: 0.12)))
    }

    private struct Land: ViewModifier {
        let amount: Double
        let reduceMotion: Bool
        func body(content: Content) -> some View {
            if reduceMotion {
                content.opacity(1 - amount)
            } else {
                content.scaleEffect(1 - 0.7 * amount).rotationEffect(.degrees(-40 * amount)).opacity(1 - amount)
            }
        }
    }
}

struct PinMenu: View {
    let widget: HomeWidget
    @ObservedObject private var coordinator = NotchViewCoordinator.shared

    var body: some View {
        if !coordinator.screenLocked {
            Button(WidgetPin.shared.widget == widget ? String(localized: "Unpin \(widget.title)") : String(localized: "Pin Alone")) {
                WidgetPin.shared.toggle(widget)
            }
            EditWidgetsButton()
        }
    }
}

/// A menu's Edit Widgets…: the editor takes the island's page, and the item lies outside the island,
/// so it stays open for the editor.
struct EditWidgetsButton: View {
    @Environment(\.islandPointerWatch) private var islandPointer

    var body: some View {
        Button(String(localized: "Edit Widgets…")) {
            islandPointer?.holdAfterMenu()
            NotchViewCoordinator.shared.setEditingWidgets(true)
        }
    }
}
