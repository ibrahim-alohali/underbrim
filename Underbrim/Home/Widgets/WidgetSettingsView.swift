//
//  WidgetSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings → Widgets: what Home shows, in what order and size, Quick Launch's apps, the tabs, and the mirror.
//

import Defaults
import SwiftUI

struct WidgetSettingsView: View {
    let camera: CameraModel
    @Default(.homeWidgetOrder) private var order
    @Default(.tabOrder) private var tabOrder
    /// Bumped when Home's widgets change (a switch, the order or a size): whether the others still fit depends on it.
    @State private var switches = 0

    private var widgets: [HomeWidget] { HomeWidget.ordered(order) }

    var body: some View {
        Form {
            Section {
                let _ = switches
                let limit = HomeWidget.room
                ForEach(Array(widgets.enumerated()), id: \.element) { index, widget in
                    let others = widgets.filter { $0 != widget && Defaults[$0.enabledKey] }
                    WidgetRow(widget: widget, camera: widget != .mirror || camera.cameraAvailable,
                              fits: { size in HomeWidget.fit(others + [widget], within: limit, size: { $0 == widget ? size : $0.size }) }) {
                        MoveButtons(title: widget.title, index: index, count: widgets.count) { order = Self.moving(widgets, at: index, by: $0) }
                    }
                }
            } header: {
                SettingsPageHeader(tab: .widgets, section: "Home",
                                   info: ["Home grows sideways to fit them, up to nearly the width of the screen; when it's full, make a widget smaller or remove one to add another. The mirror shows while its camera is on. You can also edit Home in the notch: click the widgets button next to the gear, or right-click a widget."])
            }

            Section {
                QuickLaunchSettingsGrid()
                    .settingsItem("Quick Launch apps")
                Defaults.Toggle(key: .quickLaunchBadges) { Text("Unread badges") }
                    .settingsItem("Unread badges")
                Defaults.Toggle(key: .quickLaunchHotkeys) { Text("Open the apps with ⌃⌥1 to ⌃⌥9 from any app") }
                    .settingsItem("Open the apps with ⌃⌥1 to ⌃⌥9 from any app")
            } header: {
                SettingsLabel("Quick Launch", info: "Drag an app onto another to swap them, or onto an empty spot to move it; drag it out to remove it. Click an empty spot to add an app. Faded apps are suggestions from the apps you use most, counted on this Mac from the apps you switch to; click one to keep it in its spot. In the notch, click an app to open it or bring it forward, and click the one in front to minimize it. Small shows 2 apps a row, Medium 4, Large 6.")
            }

            Section {
                let tabs = NotchViews.orderedTabs(tabOrder)
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    HStack(spacing: 8) {
                        MoveButtons(title: tab.title, index: index, count: tabs.count) {
                            tabOrder = Self.moving(tabs, at: index, by: $0)
                        }
                        TabRow(tab: tab)
                    }
                    .settingsItem(index == 0 ? "Tabs" : "tab.\(tab.rawValue)")  // the search's "Tabs": the first row, which scrolls into view like any row
                }
            } header: {
                SettingsLabel("Tabs", info: "Each switch is the same as the one on its feature's page. Clipboard history records what you copy, encrypted on this Mac; its page has the details.")
            }

            MirrorSettingsSection(camera: camera)
        }
        .formStyle(.grouped)
        .navigationTitle("Widgets")
        .task {
            for await _ in Defaults.updates(HomeWidget.layoutKeys, initial: false) { switches += 1 }
        }
    }

    static func moving<T>(_ items: [T], at index: Int, by offset: Int) -> [T] {
        let target = min(max(index + offset, 0), items.count - 1)
        guard items.indices.contains(index), target != index else { return items }
        var items = items
        items.insert(items.remove(at: index), at: target)
        return items
    }
}

/// Up and down arrows for a row: a grouped Form can't drag rows, and arrows work from the keyboard too.
private struct MoveButtons: View {
    let title: String
    let index: Int
    let count: Int
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { move(-1) } label: { Image(systemName: "chevron.up").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .disabled(index == 0)
                .help(String(localized: "Move Up"))
                .accessibilityLabel(String(localized: "Move \(title) up"))
            Button { move(1) } label: { Image(systemName: "chevron.down").frame(width: 20, height: 20).contentShape(Rectangle()) }
                .disabled(index == count - 1)
                .help(String(localized: "Move Down"))
                .accessibilityLabel(String(localized: "Move \(title) down"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10, weight: .semibold))
    }
}

private struct WidgetRow<Move: View>: View {
    let widget: HomeWidget
    let camera: Bool
    let fits: (WidgetSize) -> Bool
    @ViewBuilder let move: Move
    @Default(.homeWidgetSizes) private var sizes

    private func smaller(_ size: WidgetSize) -> Bool {
        widget.width(size, height: MusicPlayerView.height) <= widget.width(widget.size, height: MusicPlayerView.height)
    }

    var body: some View {
        let on = Defaults[widget.enabledKey]
        let canTurnOn = on || (fits(widget.size) && camera)
        HStack(spacing: 8) {
            move
            Image(systemName: widget.symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(widget.title)
            Spacer()
            if !widget.sizes.isEmpty {
                Picker(String(localized: "\(widget.title) size"), selection: Binding(
                    get: { sizes[widget.rawValue] ?? .medium },
                    set: { sizes[widget.rawValue] = $0 }
                )) {
                    // On Home, only sizes that leave its row room, and smaller ones (an overflowing row can be cut down).
                    ForEach(widget.sizes.filter { !on || fits($0) || smaller($0) }, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Defaults.Toggle(key: widget.enabledKey) { Text(widget.title) }
                .labelsHidden()
                .disabled(!canTurnOn)
                .help(canTurnOn ? "" : camera ? HomeWidget.noRoom : String(localized: "No Camera"))  // the tooltip, and what VoiceOver says of the switch
                // In this row the switch offers VoiceOver no press of its own (a click works).
                .accessibilityAction { if canTurnOn { Defaults[widget.enabledKey].toggle() } }
        }
        .settingsItem(widget.settingsMark)
    }
}

private struct TabRow: View {
    let tab: NotchViews

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.symbol).frame(width: 20).foregroundStyle(.secondary)
            if let key = tab.enabledKey {
                Defaults.Toggle(key: key) { tab == .clipboard ? Text("Clipboard history") : Text(tab.title) }
            } else {
                Text(tab.title); Spacer(); Text("Always on").foregroundStyle(.secondary)
            }
        }
    }
}

struct QuickLaunchSettingsGrid: View {
    @Default(.homeWidgetSizes) private var sizes

    var body: some View {
        let _ = sizes
        SettingsStage(height: NotchMetrics.tabHeight + 52) {
            QuickLaunchWidget(columns: HomeWidget.quickLaunch.size.quickLaunchColumns, style: .settings)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: NotchMetrics.openBottomRadius,
                                                               bottomTrailingRadius: NotchMetrics.openBottomRadius, style: .continuous))
                .padding(.top, 22)
        }
        .overlayPreferenceValue(QuickLaunchFloatKey.self) { QuickLaunchFloatsView(floats: $0) }
    }
}
