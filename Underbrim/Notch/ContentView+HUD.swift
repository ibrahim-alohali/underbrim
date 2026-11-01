//
//  ContentView+HUD.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The volume and brightness display: on the closed island with its ears, and open beside the
//  camera with its slider below.
//

import Defaults
import SwiftUI

extension ContentView {
    var peekFixesSize: Bool {
        guard vm.notchState == .closed, hud.shouldShowSneakPeek(on: vm.screenUUID) else { return false }
        return hud.sneakPeekState(for: vm.screenUUID).type != .music
            || !vm.hideOnClosed && showsMusicPeekRow
    }

    /// The standard song peek's row under the closed island: not on a display without a notch, where it
    /// would hang below the menu bar.
    var showsMusicPeekRow: Bool {
        vm.hasNotch && Defaults[.sneakPeekStyles] == .standard && hud.shouldShowSneakPeek(on: vm.screenUUID)
            && hud.sneakPeekState(for: vm.screenUUID).type == .music
    }

    /// A peek on the closed island, which pointing doesn't open over (not a song peek left out without a notch).
    var showsPeek: Bool {
        hud.shouldShowSneakPeek(on: vm.screenUUID) && (vm.hasNotch || hud.sneakPeekState(for: vm.screenUUID).type != .music)
    }

    /// The closed-notch HUD is what the island shows (not the padlock or an earlier notice; NotchLayout's order).
    var showsHUD: Bool {
        let type = hud.sneakPeekState(for: vm.screenUUID).type
        return vm.notchState == .closed && !steppingAside && !showsLockedPadlock && !shouldDisplayNowPlayingFallbackNotice && !showsBatteryNotice
            && hud.shouldShowSneakPeek(on: vm.screenUUID) && type != .music && type != .battery
    }

    var showsBatteryNotice: Bool {
        hud.expandingView.type == .battery && hud.expandingView.show
            && vm.notchState == .closed && !steppingAside && Defaults[.showPowerStatusNotifications]
    }

    /// The HUD's level along its brim (not with the slider, nudge or mic), not while hidden (the fade doesn't reach).
    @ViewBuilder var hudBrimLight: some View {
        let peek = hud.sneakPeekState(for: vm.screenUUID)
        if showsHUD, !hudExpanded, !hud.hudNudge, peek.type != .mic, !isNotchHeightZero {
            HUDBrimLight(level: peek.value, type: peek.type, accent: peek.accent, updated: peek.updated, lit: $hudLit, shape: currentNotchShape)
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.1))))
        } else if openHUD, !openHUDSlider, peek.type != .mic {
            HUDBrimLight(level: peek.value, type: peek.type, accent: peek.accent, updated: peek.updated, lit: $hudLit, shape: currentNotchShape)
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.1))))
        }
    }

    /// The pointer on the HUD, or a slider drag, keeps it up (NotchViewCoordinator.holdSneakPeek); open, so does its slider.
    var hudHeld: Bool { showsHUD && (isHovering || hudDragging) || openHUDSlider }

    /// Held, the HUD opens into its slider (not around the nudge's buttons).
    var hudExpanded: Bool {
        hudHeld && !hud.hudNudge && hud.sneakPeekState(for: vm.screenUUID).type != .mic
    }

    var openHUD: Bool { vm.notchState == .open && hud.showsOpenOSD(on: vm.screenUUID) }

    var openHUDSlider: Bool {
        openHUD && (openHUDExpanded || hudDragging) && hud.sneakPeekState(for: vm.screenUUID).type != .mic
    }

    /// Open with a HUD: the pointer at the lower edge or on the symbol beside the camera opens the slider;
    /// elsewhere it goes after a moment, so moving from the symbol down to it doesn't close it.
    func openHUDHover(_ phase: HoverPhase) {
        guard openHUD else { return }
        var reached = false
        if case .active(let point) = phase {
            let size = pointerWatch.islandFrame.size
            let edge = openHUDSlider ? NotchHUD.sliderHeight + NotchMetrics.margin + OpenNotchLayout.belowSpacing + 6 : NotchMetrics.margin + 6
            // Beside the housing, not on it: that's where the pointer rests once it has opened the island.
            let fromCentre = abs(point.x - size.width / 2)
            let symbol = point.y < bandHeight && fromCentre > cutoutGap / 2 && fromCentre < cutoutGap / 2 + OpenNotchLayout.besideGap + 26
            reached = point.y >= size.height - edge || symbol
        }
        openHUDCollapse?.cancel()
        openHUDCollapse = nil
        if reached { return expandOpenHUD(true) }
        guard openHUDExpanded, !hudDragging else { return }
        openHUDCollapse = Task { @MainActor in
            guard (try? await Task.sleep(for: .seconds(0.6))) != nil else { return }
            expandOpenHUD(false)
        }
    }

    private func expandOpenHUD(_ expand: Bool) {
        guard expand != openHUDExpanded, !expand || openHUD else { return }
        withAnimation(StandardAnimations.open) { openHUDExpanded = expand }
    }
}
