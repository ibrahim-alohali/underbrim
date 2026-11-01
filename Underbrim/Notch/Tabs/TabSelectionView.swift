//
//  TabSelectionView.swift
//  Underbrim
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Equatable {
    let label: String
    let icon: String
    let view: NotchViews
}

extension EnvironmentValues {
    /// Pages with no tab of their own, in the tab bar while their activity is live.
    @Entry var liveTabs: [TabModel] = []
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = NotchViewCoordinator.shared
    @Environment(\.liveTabs) private var liveTabs
    @Default(.tabOrder) private var tabOrder
    /// Bumped when a tab is turned on or off, so the bar redraws.
    @State private var switches = 0

    private var tabs: [TabModel] {
        let _ = switches
        return NotchViews.orderedTabs(tabOrder).filter(\.isOn).map { TabModel(label: $0.title, icon: $0.symbol, view: $0) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs + liveTabs, id: \.view) { tab in
                TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                    // A wider tab widens the notch on its own spring.
                    withAnimation(StandardAnimations.open) {
                        coordinator.selectTab(tab.view)
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: liveTabs)
        .task {
            for await _ in Defaults.updates(NotchViews.tabs.compactMap(\.enabledKey), initial: false) { switches += 1 }
        }
    }
}

extension NotchViews {
    /// The saved tab order, cleaned: only tabs, no repeats, missing ones last.
    static func orderedTabs(_ saved: [NotchViews]) -> [NotchViews] { cleanedOrder(saved, within: tabs) }

    /// The switch that turns the tab on or off, on its feature's page and in Settings › Widgets; nil for one that's always on.
    var enabledKey: Defaults.Key<Bool>? {
        switch self {
        case .shelf: .shelfEnabled
        case .clipboard: .clipboardHistoryEnabled
        case .agents: .showAgentActivity
        case .sound: .soundPageEnabled
        case .home, .downloads, .meeting, .phoneActivities, .prayer, .welcome: nil
        }
    }

    var isOn: Bool {
        guard enabledKey.map({ Defaults[$0] }) ?? true else { return false }
        return self != .sound || SoundMixer.isAvailable
    }

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .shelf: String(localized: "Shelf")
        case .clipboard: String(localized: "Clipboard")
        case .agents: String(localized: "Agents")
        case .sound: String(localized: "Sound")
        case .downloads: String(localized: "Downloads")
        case .meeting: String(localized: "Meeting")
        case .phoneActivities: String(localized: "Live Activities")
        case .prayer: String(localized: "Prayer Times")
        case .welcome: String(localized: "Welcome to Underbrim")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .shelf: "tray.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .agents: "terminal.fill"
        case .sound: "slider.horizontal.3"
        case .downloads: "arrow.down.circle.fill"
        case .meeting: "calendar"
        case .phoneActivities: "dot.radiowaves.left.and.right"
        case .prayer: "moon.stars.fill"
        case .welcome: "hand.wave"
        }
    }
}

#Preview {
    TabSelectionView().padding().background(.black)
}
