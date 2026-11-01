//
//  NotchHUD.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Volume, brightness and the keyboard light in the closed island: the symbol beside the camera,
//  the level along a brim below (HUDBrimLight); with the pointer on it, a slider below.
//

import Defaults
import SwiftUI

struct NotchHUD: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var hud = HUDPresenter.shared
    @ObservedObject private var outputs = AudioRouteManager.shared
    @Binding var state: SneakPeekState
    /// The pointer is on it, or a drag in the slider goes on: the slider shows.
    let expanded: Bool
    var dragging: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var type: SneakContentType { state.type }

    /// Either side of the camera housing, one bar tall: room for the symbol.
    static let earWidth: CGFloat = 44
    /// Below the camera housing while it shows: the level runs inside this edge, on black, so it
    /// reads over light windows and under the housing, which has no pixels (HUDBrimLight).
    static let brim: CGFloat = 5
    /// Opened, the ears widen to name what the slider sets, up to the upper bound.
    static let namedEarWidth: ClosedRange<CGFloat> = 72...140
    static let sliderHeight: CGFloat = 28
    /// Around the slider, which is concentric with the island's bottom corners.
    static let margin: CGFloat = 12

    /// Bottom corners: the closed notch's (nil) closed; open, concentric with the slider; less round for the nudge.
    static func bottomRadius(expanded: Bool, nudge: Bool) -> CGFloat? {
        if nudge { return 16 }
        return expanded ? sliderHeight / 2 + margin : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            EarsLayout(gap: vm.floating == nil ? vm.closedNotchSize.width : FloatingIsland.middle, ears: expanded ? Self.namedEarWidth : Self.earWidth...Self.earWidth) {
                OSDIconView(eventType: type, icon: state.icon, value: state.value, accent: state.accent)
                    .font(.system(size: 16, weight: .semibold))
                if expanded {
                    Text(controlled)
                        .font(.notchCaption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .help(controlled)
                        .transition(opened)
                }
            }
            .frame(height: vm.effectiveClosedNotchHeight)
            // The same in every language: the symbol on the left, the level filling from it.
            .environment(\.layoutDirection, .leftToRight)
            if expanded {
                DraggableProgressBar(value: $state.value, onChange: { Self.setLevel($0, for: type) },
                                     accentColor: state.accent, height: Self.sliderHeight, symbol: lowSymbol,
                                     scrolls: true, name: type.levelName, dragging: dragging)
                    .padding(.horizontal, Self.margin)
                    .padding(.top, 8)
                    .environment(\.layoutDirection, .leftToRight)
                    .transition(opened)
            }
            if hud.hudNudge { nudge.padding(.horizontal, 16).padding(.top, 2) }
        }
        // Floating, the level runs inside the capsule's own edge: no housing to keep it from.
        .padding(.bottom, expanded ? Self.margin : hud.hudNudge ? 10 : type == .mic || vm.floating != nil ? 0 : Self.brim)
        .foregroundStyle(.white)
        // Ready by the time the pointer gets there.
        .task(id: type) { if type == .volume { outputs.refreshDevices() } }
        .onChange(of: hud.hudNudge, initial: true) { _, asking in if asking { Defaults[.hudNudgeShown] = true } }
        .onDisappear { hud.hudNudge = false }
    }

    /// What only the opened HUD shows: in once the island has made room (so the outline doesn't cut it), out first.
    private var opened: AnyTransition {
        reduceMotion ? .opacity.animation(.easeOut(duration: 0.12))
            : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.15)),
                          removal: .opacity.animation(.easeOut(duration: 0.08)))
    }

    private var controlled: String { Self.controlled(type, screenUUID: vm.screenUUID) }

    private var lowSymbol: String { Self.lowSymbol(type) }

    static func controlled(_ type: SneakContentType, screenUUID: String?) -> String {
        switch type {
        case .volume: AudioRouteManager.shared.activeDevice?.name ?? type.levelName
        case .brightness: screenUUID.flatMap { NSScreen.screen(withUUID: $0) }?.localizedName ?? type.levelName
        default: type.levelName
        }
    }

    static func lowSymbol(_ type: SneakContentType) -> String {
        switch type {
        case .brightness: "sun.min.fill"
        case .backlight: "light.min"
        default: "speaker.fill"
        }
    }

    /// Asked once, the first time the volume changes while Underbrim can't take over the keys; with the
    /// replacement on, it's the missing permission, asked until "Not Now". Its row sets the island's width.
    private var nudge: some View {
        let on = Defaults[.osdReplacement]
        return HStack(spacing: 10) {
            // The pane's name as this macOS shows it (on macOS 27 it isn't "Accessibility").
            Text(on ? String(localized: "\(AccessibilityPermission.displayName) Required") : String(localized: "Use this instead of macOS's?"))
                .font(.notchCaption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Not Now") {
                if on { hud.hudNudgeDeclined = true }
                dismissNudge()
            }
                .buttonStyle(.plain).font(.notchCaption).foregroundStyle(.secondary)
            Button(on ? "Allow…" : "Turn On") {
                dismissNudge()
                Defaults[.osdReplacement] = true
                // macOS's prompt if it gives one, and the list at once; the keys are taken over when access arrives.
                if !AXIsProcessTrusted() {
                    XPCHelperClient.shared.requestAccessibilityAuthorization()
                    SystemSettings.open(.accessibility)
                }
            }
            .buttonStyle(.plain).font(.notchCaption.weight(.semibold))
        }
        .lineLimit(1)
    }

    private func dismissNudge() {
        // Hidden while the nudge counts: with the replacement off, a peek without it isn't let through.
        hud.toggleSneakPeek(status: false, type: type, targetScreenUUID: vm.screenUUID)
        hud.hudNudge = false
    }

    static func setLevel(_ level: CGFloat, for type: SneakContentType) {
        switch type {
        case .volume: VolumeManager.shared.setAbsolute(Float32(level))
        case .brightness: BrightnessManager.shared.setAbsolute(value: Float32(level))
        case .backlight: KeyboardBacklightManager.shared.setAbsolute(value: Float(level))
        default: break
        }
    }
}

/// The ears either side of the camera housing, equally wide so the island stays centred: as wide as
/// the wider one needs within `ears`, or a row below. The first view leads; the rest share the trailing ear.
private struct EarsLayout: Layout {
    let gap: CGFloat
    let ears: ClosedRange<CGFloat>

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let need = sizes.map(\.width).max() ?? 0
        let own = gap + 2 * min(max(need, ears.lowerBound), ears.upperBound)
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: max(own, offered), height: proposal.height ?? sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ear = max(0, (bounds.width - gap) / 2)
        for (index, subview) in subviews.enumerated() {
            let x = index == 0 ? bounds.minX + ear / 2 : bounds.maxX - ear / 2
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: ear, height: bounds.height))
        }
    }
}
