//
//  AdvancedSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings › Advanced: what you'd set once and rarely change, one section per area in the
//  sidebar's order, each kept with its feature's code and shown while that feature is in use.
//

import Defaults
import SwiftUI

enum AdvancedArea: String, CaseIterable {
    case notch, displays, media, prayer, shelf, clipboard, agents, battery, downloads, osd

    /// Its name's catalog key: the section's title, and the search's "Advanced › Media".
    var key: String {
        switch self {
        case .notch: "Notch"
        case .displays: "Displays"
        case .media: "Media"
        case .prayer: "Prayer Times"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .agents: "Coding Agents"
        case .battery: "Battery"
        case .downloads: "Downloads"
        case .osd: "Volume & Brightness"
        }
    }

    var title: String { String(localized: String.LocalizationValue(key)) }

    var glyph: Image {
        switch self {
        case .notch: Image("notch")
        case .displays: Image(systemName: "display")
        case .media: SettingsTab.media.info.glyph
        case .prayer: SettingsTab.prayer.info.glyph
        case .shelf: SettingsTab.shelf.info.glyph
        case .clipboard: SettingsTab.clipboard.info.glyph
        case .agents: SettingsTab.agents.info.glyph
        case .battery: Image(systemName: "battery.75percent")
        case .downloads: Image(systemName: "arrow.down.to.line")
        case .osd: SettingsTab.osd.info.glyph
        }
    }

    var anchor: String { "advanced.\(rawValue)" }

    var feature: (page: SettingsTab, mark: String)? {
        switch self {
        case .notch, .media, .clipboard: nil
        // Turned off, rather: its settings choose one display.
        case .displays: (.general, "Show on all displays")
        case .prayer: (.prayer, SettingsItem.pageSwitch)
        case .shelf: (.shelf, SettingsItem.pageSwitch)
        case .agents: (.agents, "Show coding sessions in the notch")
        case .battery: (.activities, "Show battery indicator")
        case .downloads: (.activities, "Show downloads in the closed notch")
        case .osd: (.osd, SettingsItem.pageSwitch)
        }
    }

    /// Whether its section shows: while its feature is in use. Clipboard's always does, so the
    /// history kept while it's off can still be deleted.
    var inUse: Bool {
        switch self {
        case .notch, .media, .clipboard: true
        case .displays: !Defaults[.showOnAllDisplays]
        case .prayer: Defaults[.prayerTimesEnabled]
        case .shelf: Defaults[.shelfEnabled]
        case .agents: Defaults[.showAgentActivity]
        // The icons and wattage show in the power notifications too.
        case .battery: Defaults[.showBatteryIndicator] || Defaults[.showPowerStatusNotifications]
        case .downloads: Defaults[.showDownloadActivity]
        case .osd: Defaults[.osdReplacement]
        }
    }

    /// The switches `inUse` reads.
    var switchKeys: [Defaults.Key<Bool>] {
        switch self {
        case .notch, .media, .clipboard: []
        case .displays: [.showOnAllDisplays]
        case .prayer: [.prayerTimesEnabled]
        case .shelf: [.shelfEnabled]
        case .agents: [.showAgentActivity]
        case .battery: [.showBatteryIndicator, .showPowerStatusNotifications]
        case .downloads: [.showDownloadActivity]
        case .osd: [.osdReplacement]
        }
    }

    /// Every area's switches: the page shows a section again when one flips.
    static let keys = allCases.flatMap(\.switchKeys)
}

struct AdvancedSettingsView: View {
    /// Bumped when an area's switch flips.
    @State private var changes = 0

    var body: some View {
        let _ = changes
        Form {
            ForEach(AdvancedArea.allCases.filter(\.inUse), id: \.self) { area in
                switch area {
                case .notch: NotchAdvancedSettings()
                case .displays: DisplayAdvancedSettings()
                case .media: MediaAdvancedSettings()
                case .prayer: PrayerAdvancedSettings()
                case .shelf: ShelfAdvancedSettings()
                case .clipboard: ClipboardAdvancedSettings()
                case .agents: AgentAdvancedSettings()
                case .battery: BatteryAdvancedSettings()
                case .downloads: DownloadAdvancedSettings()
                case .osd: OSDAdvancedSettings()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .task {
            for await _ in Defaults.updates(AdvancedArea.keys, initial: false) { changes += 1 }
        }
    }
}

struct AdvancedHeader: View {
    let area: AdvancedArea
    var info: [LocalizedStringKey] = []

    var body: some View {
        if area == AdvancedArea.allCases.first {
            SettingsPageHeader(tab: .advanced, section: LocalizedStringKey(area.key), info: info, sectionMark: area.anchor)
        } else {
            SettingsLabel(verbatim: area.title, info: info)
                .settingsItem(area.anchor)
        }
    }
}

struct MoreInAdvanced: View {
    let area: AdvancedArea

    init(_ area: AdvancedArea) { self.area = area }

    var body: some View {
        Section {} footer: {
            Button {
                SettingsNavigation.shared.selectedTab = .advanced
                SettingsSearch.shared.target = SettingsItem(area: area, key: area.key, anchor: area.anchor)
            } label: {
                HStack(spacing: 3) {
                    Text("More in Advanced")
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .flipsForRightToLeftLayoutDirection(true)
                }
                .foregroundStyle(Color.accentText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "More in Advanced"))
            .accessibilityHint(area.title)
        }
    }
}

struct SettingsLabel: View {
    let title: Text
    let info: [LocalizedStringKey]

    init(_ title: LocalizedStringKey, info: LocalizedStringKey...) {
        self.title = Text(title)
        self.info = info
    }

    init(_ title: LocalizedStringKey, info: [LocalizedStringKey]) {
        self.title = Text(title)
        self.info = info
    }

    init(verbatim title: String, info: [LocalizedStringKey] = []) {
        self.title = Text(verbatim: title)
        self.info = info
    }

    var body: some View {
        HStack(spacing: 5) {
            title
            if !info.isEmpty { SettingsInfo(info) }
        }
    }
}

/// What a setting or a section does, in a popover from an ⓘ. VoiceOver reads it as the button's hint.
struct SettingsInfo: View {
    let paragraphs: [LocalizedStringKey]
    @State private var shown = false

    init(_ paragraphs: [LocalizedStringKey]) { self.paragraphs = paragraphs }
    init(_ paragraphs: LocalizedStringKey...) { self.paragraphs = paragraphs }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(shown ? Color.accentText : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(String(localized: "More Info"))
        .accessibilityLabel(String(localized: "More Info"))
        .accessibilityHint(paragraphs.map { Text($0) }.reduce(Text(verbatim: "")) { $0 + $1 + Text(verbatim: " ") })
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paragraphs.indices, id: \.self) { Text(paragraphs[$0]) }
            }
            .font(.callout)
            .multilineTextAlignment(.leading)
            .frame(width: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
        }
    }
}
