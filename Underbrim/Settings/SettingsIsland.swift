//
//  SettingsIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Each Settings page opens under an island hanging from the window's top edge, as the notch
//  hangs from the screen: it shows what that feature shows in the notch (never clipboard or
//  notification contents), and a click on it changes the page's main setting.
//

import AppKit
import SwiftUI

struct SettingsIsland: View {
    /// nil while searching. Changed on the island's spring by SettingsView.
    let page: SettingsTab?
    let camera: CameraModel

    static let flare: CGFloat = 10

    static func size(of page: SettingsTab?) -> CGSize { page?.info.islandSize ?? CGSize(width: 180, height: 34) }

    var body: some View {
        let size = Self.size(of: page)
        ZStack {
            if let page {
                IslandPage(page: page, camera: camera)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(page)
                    .transition(StandardAnimations.pageChange)
            } else {
                SearchIsland()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(StandardAnimations.pageChange)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: size.width, height: size.height)
        .clipped()
        .padding(.horizontal, Self.flare)
        // The volume along the lower edge; faded out on other pages, not removed, so it keeps to the outline.
        .overlay { VolumeBrim().opacity(page == .osd ? 1 : 0) }
        // Under what it shows: a click or drag on the rest of the island sets the volume.
        .background { if page == .osd { VolumeDrag() } }
        .background(.black, in: IslandShape(topRadius: Self.flare, bottomRadius: 18))
        .environment(\.colorScheme, .dark)
        // A click on it stays there, not on the page scrolled under it.
        .contentShape(IslandShape(topRadius: Self.flare, bottomRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page?.title ?? String(localized: "Search results"))
    }
}

private struct IslandPage: View {
    let page: SettingsTab
    let camera: CameraModel

    var body: some View {
        switch page {
        case .general: DisplayIsland()
        case .appearance: AppearanceIsland()
        case .permissions: PermissionsIsland()
        case .widgets: WidgetsIsland(camera: camera)
        case .media: MediaIsland()
        case .prayer: PrayerIsland()
        case .calendar: CalendarIsland()
        case .shelf: ShelfIsland()
        case .clipboard: ClipboardIsland()
        case .agents: AgentsIsland()
        case .activities: ActivityIsland()
        case .notifications: NotificationsIsland()
        case .osd: VolumeIsland()
        case .sound: SoundIsland()
        case .advanced: AnimationIsland()
        case .about: AboutIsland()
        }
    }
}

// MARK: - Search, Permissions and About

/// While searching: how many settings the list under it has.
private struct SearchIsland: View {
    private let search = SettingsSearch.shared

    var body: some View {
        let count = search.results.count
        IslandRow(symbol: "magnifyingglass", lit: count > 0, title: String(localized: "\(count) results"), dim: count == 0)
    }
}

/// The page's own count: it's shown over that page, which keeps it up to date.
private struct PermissionsIsland: View {
    private let states = PermissionStates.shared

    var body: some View {
        IslandRow(symbol: "hand.raised.fill", title: SettingsTab.permissions.title,
                  value: String(localized: "\(states.allowedCount) of \(states.all.count) allowed"))
    }
}

private struct AboutIsland: View {
    @State private var copied: Date?

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Underbrim \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text(verbatim: "Underbrim").islandText()
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(version, forType: .string)
                copied = .now
            } label: {
                Group {
                    if copied != nil {
                        Text("Copied").islandText(lit: true)
                    } else {
                        Text(verbatim: Bundle.main.releaseVersionNumber ?? "").islandText(lit: true).monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            .help(islandHelp(version, String(localized: "Copy the version")))
            .accessibilityLabel(String(localized: "Copy the version"))
            .accessibilityValue(copied != nil ? String(localized: "Copied") : version)
        }
        .task(id: copied) {
            guard copied != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            copied = nil
        }
    }
}
