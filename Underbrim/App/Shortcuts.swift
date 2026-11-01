//
//  Shortcuts.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The global keyboard shortcuts: the sneak peek, opening the notch, the Scratchpad and Quick Launch.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

extension AppDelegate {
    func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) {
            if Defaults[.sneakPeekStyles] == .inline {
                // The inline peek is the closed pill's own (a key-up handler added per press would pile up).
                HUDPresenter.shared.toggleExpandingView(status: !HUDPresenter.shared.expandingView.show, type: .music)
            } else {
                HUDPresenter.shared.toggleSneakPeek(
                    status: !HUDPresenter.shared.isAnySneakPeekShowing,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { @MainActor [weak self] in self?.toggleNotchFromKeyboard() }
        }

        // The Scratchpad shortcut: straight into the note, on Home; pressed again while typing, away.
        KeyboardShortcuts.onKeyDown(for: .openScratchpad) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pad = Scratchpad.shared
                if let island = pad.editingIsland, island.notchState == .open {
                    self.windowManager.endKeyboardSession()
                    island.closeDeliberately()
                    return
                }
                let viewModel = self.windowManager.viewModelUnderPointer()
                let wasClosed = viewModel.notchState == .closed
                if wasClosed {
                    self.windowManager.openWithKeyboard(viewModel)
                    self.coordinator.selectTab(.home)
                } else {
                    // Open on another page: the island changes to Home on its spring, as for a tab.
                    withAnimation(StandardAnimations.open) { self.coordinator.selectTab(.home) }
                }
                pad.jump(to: viewModel, closesWhenDone: wasClosed)
            }
        }
        // Only while the Scratchpad is on Home: otherwise its keys stay with other apps.
        let scratchpadKey: @MainActor () -> Void = {
            if Defaults[.showScratchpadWidget] && !Defaults[.compactMode] {
                KeyboardShortcuts.enable(.openScratchpad)
            } else {
                KeyboardShortcuts.disable(.openScratchpad)
            }
        }
        scratchpadKey()
        Defaults.whenChanged([.showScratchpadWidget, .compactMode], perform: scratchpadKey)

        for (index, name) in KeyboardShortcuts.Name.quickLaunchSpots.enumerated() {
            KeyboardShortcuts.onKeyDown(for: name) {
                MainActor.assumeIsolated { QuickLaunch.shared.clickSpot(index + 1) }
            }
        }
        let quickLaunchKeys: @MainActor () -> Void = {
            if Defaults[.quickLaunchHotkeys] && Defaults[.showQuickLaunch] {
                KeyboardShortcuts.enable(KeyboardShortcuts.Name.quickLaunchSpots)
            } else {
                KeyboardShortcuts.disable(KeyboardShortcuts.Name.quickLaunchSpots)
            }
        }
        quickLaunchKeys()
        Defaults.whenChanged([.quickLaunchHotkeys, .showQuickLaunch], perform: quickLaunchKeys)
    }

    /// The shortcut that opens the notch. A keyboard-opened notch takes key focus and stays open until Escape,
    /// the shortcut or a focus change. A question the island opened by itself gets the keyboard first, so
    /// its options can be picked from it; pressed again, it closes.
    func toggleNotchFromKeyboard() {
        let viewModel = windowManager.viewModelUnderPointer()
        switch viewModel.notchState {
        case .closed:
            windowManager.openWithKeyboard(viewModel)
        case .open:
            if viewModel.shownAsk != nil, !windowManager.hasKeyboard(viewModel) {
                windowManager.takeKeyboard(viewModel)
            } else {
                windowManager.endKeyboardSession()
                viewModel.closeDeliberately()
            }
        }
    }

    /// The menu bar icon's Open Underbrim (beside Apple's island): opens as the shortcut does.
    func openFromMenu() {
        let viewModel = windowManager.viewModelUnderPointer()
        if viewModel.notchState == .closed { windowManager.openWithKeyboard(viewModel) }
    }
}
