//
//  AgentAsksOpening.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI

/// A question has the island until it's answered or closed (AgentAsks); locked, it waits for the unlock.
struct AgentAsksOpening: ViewModifier {
    let current: String?
    let locked: Bool
    let open: () -> Void
    let close: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: current) { old, new in
                if new == nil { close() } else if new != old { open() }
            }
            .onChange(of: locked) { _, locked in if !locked { open() } }
    }
}
