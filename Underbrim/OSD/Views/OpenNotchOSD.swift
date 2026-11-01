//
//  OpenNotchOSD.swift
//  Underbrim
//
//  Created by Alexander on 2024-11-23.
//
//  Underbrim: volume, brightness and the keyboard light on the open island, as on the closed one;
//  nothing else in the island moves for it.
//

import Defaults
import SwiftUI

struct OpenHUDSymbol: View {
    @Binding var state: SneakPeekState

    var body: some View {
        OSDIconView(eventType: state.type, icon: state.icon, value: state.value, accent: state.accent)
            .font(.notchSymbol(size: 14))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

/// The slider the open HUD opens into, under the page: what it sets, then the level.
struct OpenHUDSlider: View {
    @Binding var state: SneakPeekState
    let screenUUID: String?
    var dragging: (Bool) -> Void = { _ in }
    @ObservedObject private var outputs = AudioRouteManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Text(NotchHUD.controlled(state.type, screenUUID: screenUUID))
                .font(.notchCaption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            DraggableProgressBar(value: $state.value, onChange: { NotchHUD.setLevel($0, for: state.type) },
                                 accentColor: state.accent, height: NotchHUD.sliderHeight, symbol: NotchHUD.lowSymbol(state.type),
                                 scrolls: true, name: state.type.levelName, dragging: dragging)
        }
        // As the closed HUD: the same in every language, the level filling from the left.
        .environment(\.layoutDirection, .leftToRight)
        .task(id: state.type) { if state.type == .volume { outputs.refreshDevices() } }
    }
}

#Preview {
    OpenHUDSlider(state: .constant(SneakPeekState(type: .volume, value: 0.5)), screenUUID: nil)
        .padding()
        .frame(width: 420)
        .background(.black)
}
