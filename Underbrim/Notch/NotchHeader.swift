//
//  NotchHeader.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

/// The open notch's header in the menu-bar band beside the housing: tabs on the left, status and settings right.
enum NotchHeader {
    struct Leading: View {
        @ObservedObject var coordinator = NotchViewCoordinator.shared
        @ObservedObject var shelfState = ShelfStateViewModel.shared
        @Environment(\.liveTabs) private var liveTabs
        @Default(.openIslandForAgentRequests) private var showsAsks

        var body: some View {
            // None on the lock screen, where the island shows only Home.
            if !coordinator.screenLocked {
                HStack(spacing: 4) {
                    let setAside = AgentAsks.shared.setAside
                    if showsAsks, let first = setAside.first {
                        SetAsideAsksButton(first: first, count: setAside.count)
                    }
                    if showsTabs {
                        TabSelectionView()
                    }
                }
            }
        }

        /// Once there's more than Home to pick: any tab that's on, the Shelf only with something on it (or
        /// with tabs always shown), or a live activity's page.
        private var showsTabs: Bool {
            NotchViews.tabs.contains { tab in
                tab != .home && tab.isOn && (tab != .shelf || !shelfState.isEmpty || coordinator.alwaysShowTabs)
            } || !liveTabs.isEmpty
        }
    }

    /// What waits set aside (approvals, plans, questions): the first one's creature, at the start of the tab
    /// bar, brings them back.
    private struct SetAsideAsksButton: View {
        let first: AgentAsks.Ask
        let count: Int
        @State private var hovering = false

        var body: some View {
            let name = String(localized: "Needs you")
            Button {
                NotificationCenter.default.post(name: .closeIslandPopovers, object: nil)
                withAnimation(StandardAnimations.open) { AgentAsks.shared.show(first.id) }
            } label: {
                HStack(spacing: 3) {
                    AgentCreatureView(kind: AgentCreatureKind(provider: first.provider), state: first.creature,
                                      height: 14, movesOnlyWhileWorking: true)
                    Text(count, format: .number)
                        .font(.notchCaption)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundStyle(Color.white.opacity(hovering ? 0.9 : 0.6))
            .onHover { hovering = $0 }
            .modifier(HoverName(name: name))
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(count, format: .number))
            .transition(.opacity)
        }
    }

    struct Trailing: View {
        @EnvironmentObject var vm: NotchViewModel
        @ObservedObject var batteryModel = BatteryStatusViewModel.shared
        @ObservedObject var coordinator = NotchViewCoordinator.shared
        @Default(.clipboardHistoryEnabled) private var clipboardEnabled
        @Default(.settingsIconInNotch) private var settingsButton
        @Environment(ClipboardBrowse.self) private var browse

        var body: some View {
            // The Clipboard tab searches from here; both are laid out while the tab exists, so this half keeps
            // its width and the tabs on the other side don't move when the search swaps in.
            let onClipboard = coordinator.shownView == .clipboard
            let editing = coordinator.editingWidgets && coordinator.shownView == .home
            ZStack(alignment: .trailing) {
                status.occupying(shown: !onClipboard && !editing)
                if clipboardEnabled {
                    HStack(spacing: 8) { ClipboardSearchField(); clearHistory }.occupying(shown: onClipboard)
                }
                if editing {
                    Button(String(localized: "Done")) { coordinator.setEditingWidgets(false) }
                        .buttonStyle(NotchProminentStyle(height: 24))
                }
            }
            // The width it kept while volume and brightness showed here, so the header stays where it was.
            .frame(minWidth: Defaults[.osdReplacement] && Defaults[.showOpenNotchOSD] ? 140 : 0, alignment: .trailing)
        }

        private var status: some View {
            HStack(spacing: 8) {
                if Defaults[.showMirror] && vm.camera.cameraAvailable {
                    // On every tab (hidden off Home), so the row keeps its width.
                    NotchSymbolButton(symbol: "web.camera", label: String(localized: "Mirror"), nameEdge: .trailing) {
                        vm.toggleCameraPreview()
                    }
                    .accessibilityValue(vm.camera.isSessionRunning ? String(localized: "On") : String(localized: "Off"))
                    // Not on the lock screen: the camera would show whoever is at the Mac.
                    .occupying(shown: coordinator.currentView == .home && !coordinator.screenLocked)
                }
                if !Defaults[.compactMode] {
                    NotchSymbolButton(symbol: "square.grid.2x2", label: String(localized: "Edit Widgets"), nameEdge: .trailing) {
                        coordinator.setEditingWidgets(true)
                    }
                    .occupying(shown: coordinator.currentView == .home && !coordinator.screenLocked)
                }
                // After the Home-only buttons, so their empty places off Home never sit beside it.
                if settingsButton {
                    NotchSymbolButton(symbol: "gearshape", label: String(localized: "Settings"), nameEdge: .trailing) {
                        DispatchQueue.main.async {
                            SettingsWindowController.shared.showWindow()
                        }
                    }
                }
                HeadphoneBatteryIndicator()
                if Defaults[.showBatteryIndicator] {
                    NotchBatteryView(
                        batteryWidth: 26,
                        isCharging: batteryModel.isCharging,
                        isInLowPowerMode: batteryModel.isInLowPowerMode,
                        isPluggedIn: batteryModel.isPluggedIn,
                        levelBattery: batteryModel.levelBattery,
                        maxCapacity: batteryModel.maxCapacity,
                        timeToFullCharge: batteryModel.timeToFullCharge,
                        timeToDischarge: batteryModel.timeToDischarge,
                        maxAdapterWatts: batteryModel.maxAdapterWatts,
                        isForNotification: false
                    )
                }
            }
            .foregroundStyle(.secondary)
        }

        /// Clears the unpinned items, asking first: only with some to clear, not mid-search or on the lock
        /// screen. Hidden, its spot stays, so the search field never moves.
        private var clearHistory: some View {
            let history = ClipboardHistory.shared
            return NotchSymbolButton(symbol: "trash", label: String(localized: "Clear Unpinned Items"), tint: .red, nameEdge: .trailing) {
                history.confirmClear()
            }
            .occupying(shown: history.browsable && !browse.searching && history.entries.contains { !$0.pinned })
        }

    }
}

private extension View {
    /// Shown, or laid out for its width alone (not drawn, clickable, focusable or accessible).
    @ViewBuilder func occupying(shown: Bool) -> some View {
        if shown { self } else { hidden() }
    }
}

#Preview {
    HStack(spacing: 200) {
        NotchHeader.Leading()
        NotchHeader.Trailing()
    }
    .environmentObject(NotchViewModel(camera: CameraModel()))
    .environment(ClipboardBrowse())
}
