//
//  TabButton.swift
//  Underbrim
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .closeIslandPopovers, object: nil)
            onClick()
        } label: {
            Image(systemName: icon)
                .font(.notchSymbol())
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        // Dim enough when not selected that a grey accent (Graphite) still stands out.
        .foregroundStyle(selected ? Color.notchAccent : Color.white.opacity(hovering ? 0.7 : 0.35))
        .onHover { hovering = $0 }
        .modifier(HoverName(name: label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        Log.general.debug("Tapped")
    }
}
