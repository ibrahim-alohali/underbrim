//
//  SettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import Observation
import SwiftUI
import SwiftUIIntrospect

enum SettingsTab: String, CaseIterable, Identifiable, Defaults.Serializable {
    case general
    case widgets
    case agents
    case activities
    case prayer
    case clipboard
    case appearance
    case media
    case sound
    case calendar
    case shelf
    case osd
    case notifications
    case permissions
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .widgets: String(localized: "Widgets")
        case .agents: String(localized: "Coding Agents")
        case .activities: String(localized: "Live Activities")
        case .prayer: String(localized: "Prayer Times")
        case .clipboard: String(localized: "Clipboard")
        case .appearance: String(localized: "Appearance")
        case .media: String(localized: "Media")
        case .calendar: String(localized: "Calendar")
        case .shelf: String(localized: "Shelf")
        case .osd: String(localized: "Volume & Brightness")
        case .sound: String(localized: "Sound")
        case .notifications: String(localized: "Notifications")
        case .permissions: String(localized: "Permissions")
        case .advanced: String(localized: "Advanced")
        case .about: String(localized: "About")
        }
    }
}

/// Lets other parts of the app open Settings on a particular page.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab = Defaults[.settingsLastTab] {
        didSet { Defaults[.settingsLastTab] = selectedTab }
    }
}

struct SettingsView: View {
    @Bindable private var navigation = SettingsNavigation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let search = SettingsSearch.shared
    @State private var revealing: Task<Void, Never>?

    let camera: CameraModel

    /// Where a page's title starts, under the title bar, with no room added.
    private static let titleTop: CGFloat = 58
    /// The island's page as shown: follows `islandPage` on the island's spring, whatever changed it
    /// (search updates come without animation).
    @State private var shown: SettingsTab?

    private static func room(under page: SettingsTab?) -> CGFloat {
        max(0, SettingsIsland.size(of: page).height + 22 - titleTop)
    }

    private var islandPage: SettingsTab? { search.isSearching ? nil : navigation.selectedTab }

    init(camera: CameraModel) {
        self.camera = camera
        let page = SettingsSearch.shared.isSearching ? nil : SettingsNavigation.shared.selectedTab
        _shown = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $navigation.selectedTab)
            SettingsPalette.hairline
                .frame(width: 1)
                .ignoresSafeArea()
            Group {
                if search.isSearching {
                    SettingsResultsView()
                } else {
                    ScrollViewReader { proxy in
                        page
                            .formStyle(.grouped)
                            .scrollContentBackground(.hidden)
                            .onChange(of: search.target, initial: true) { _, item in reveal(item, with: proxy) }
                    }
                }
            }
            // Room under the island, so a page's title starts 22 pt below it.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: Self.room(under: shown))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsPalette.page.ignoresSafeArea())
            .overlay(alignment: .top) {
                SettingsIsland(page: shown, camera: camera).ignoresSafeArea(edges: .top)
            }
            .onChange(of: islandPage) { _, page in
                withAnimation(StandardAnimations.open) { shown = page }
            }
        }
        // As wide as its design, as tall as you like: the hosting view gives the window these limits.
        .frame(width: 720)
        .frame(minHeight: 460)
        .tint(.accentText)
        .toggleStyle(SettingsToggleStyle())
    }

    /// A setting picked in the search: its page scrolls to it, then it's lit; while hidden (its feature
    /// off), the switch it shows with. A newer pick, a page change or a new search ends it.
    private func reveal(_ item: SettingsItem?, with proxy: ScrollViewProxy) {
        guard let item else { return }
        search.target = nil
        revealing?.cancel()
        revealing = Task {
            var page = navigation.selectedTab
            var stillThere: Bool { !Task.isCancelled && navigation.selectedTab == page && !search.isSearching }
            try? await Task.sleep(for: .milliseconds(120))  // the page has laid out
            for place in item.places where stillThere {
                if place.page != page {
                    page = place.page
                    navigation.selectedTab = page
                    try? await Task.sleep(for: .milliseconds(120))
                    guard stillThere else { return }
                }
                let near = search.isShown(place.mark)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(place.mark, anchor: .center) }
                if !near { try? await Task.sleep(for: .milliseconds(450)) }  // scrolled in, if it's on the page
                if stillThere, search.isShown(place.mark) {
                    search.light(place.mark)
                    AccessibilityNotification.Announcement(place.name).post()
                    return
                }
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch navigation.selectedTab {
        case .general:
            GeneralSettings()
        case .widgets:
            WidgetSettingsView(camera: camera)
        case .agents:
            AgentSettingsView()
        case .activities:
            LiveActivitySettingsView()
        case .prayer:
            PrayerSettingsView()
        case .clipboard:
            ClipboardSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .media:
            MediaSettingsView()
        case .notifications:
            NotificationSettingsView()
        case .calendar:
            CalendarSettings()
        case .osd:
            OSDSettings()
        case .sound:
            SoundSettingsView()
        case .shelf:
            ShelfSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .advanced:
            AdvancedSettingsView()
        case .about:
            AboutView()
        }
    }
}
