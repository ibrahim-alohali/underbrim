//
//  RimLights.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import SwiftUI

private struct RimLightEvent: Equatable {
    let kind: RimLight.Kind
    let start: Date
}

/// Rim lights for the charger going in (green) and out (white), low battery (red) and an adhan (glint).
/// Opening or closing mid-light fades it out for good.
struct RimLights: ViewModifier {
    let shape: IslandShape
    let open: Bool
    let bandHeight: CGFloat
    let pluggedIn: Bool
    let pluggedInAt: Date?
    let unpluggedAt: Date?
    let lowBatteryAt: Date?
    let adhanAt: Date?
    let padlock: Bool
    /// Closed, the island isn't drawn (a full-screen app, or no notch height).
    let hidden: Bool
    @State private var light: RimLightEvent?

    func body(content: Content) -> some View {
        content
            .overlay {
                if let light {
                    RimLight(kind: light.kind, shape: shape, start: light.start, top: open ? bandHeight : 0)
                        .id(light.start)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
            .onChange(of: pluggedInAt) { _, at in power(.charge, at) }
            .onChange(of: unpluggedAt) { _, at in power(.drain, at) }
            // Out again within the drain's 5 s limit: no new light, but no green filling up either.
            .onChange(of: pluggedIn) { _, now in if !now, light?.kind == .charge { light = nil } }
            .onChange(of: lowBatteryAt) { _, at in power(.alarm, at) }
            .onChange(of: adhanAt) { _, at in
                // With the adhan's pill: not round the lock screen's padlock, where there's none.
                guard at != nil, Defaults[.prayerAtTime], !open, !hidden, !padlock, !PrayerTimesStore.busy(at: .now) else { return }
                light = RimLightEvent(kind: .glint, start: .now.addingTimeInterval(0.3))
            }
            .onChange(of: open) { _, _ in light = nil }
    }

    /// With the power notice: closed, once its pill has widened; open or locked, at once.
    private func power(_ kind: RimLight.Kind, _ at: Date?) {
        guard let at, Defaults[.showPowerStatusNotifications], open || !hidden else { return }
        light = RimLightEvent(kind: kind, start: at.addingTimeInterval(!open && !padlock ? 0.3 : 0))
    }
}
