//
//  ShelfSettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct ShelfSettingsView: View {
    @Default(.quickShareProvider) var quickShareProvider
    @Default(.shelfEnabled) private var shelfOn
    @StateObject private var quickShareService = QuickShareService.shared

    private var selectedProvider: QuickShareProvider? {
        quickShareService.availableProviders.first(where: { $0.id == quickShareProvider })
    }

    var body: some View {
        Form {
            Section {
                Picker("Quick Share Service", selection: $quickShareProvider) {
                    ForEach(quickShareService.availableProviders, id: \.id) { provider in
                        HStack {
                            Group {
                                if let icon = quickShareService.icon(for: provider.id, size: 16) {
                                    Image(nsImage: icon)
                                        .resizable().scaledToFit()
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                            }
                            .frame(width: 16, height: 16)
                            .foregroundStyle(Color.accentText)
                            Text(provider.title)
                        }
                        .tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .settingsItem("Quick Share Service")

                if let selectedProvider = selectedProvider {
                    HStack {
                        Group {
                            if let icon = quickShareService.icon(for: selectedProvider.id, size: 16) {
                                Image(nsImage: icon)
                                    .resizable().scaledToFit()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .frame(width: 16, height: 16)
                        .foregroundStyle(Color.accentText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Currently selected: \(selectedProvider.title)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Files dropped on this service's button in the Shelf are shared with it")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                SettingsPageHeader(tab: .shelf, isOn: $shelfOn, section: "Quick Share",
                                   info: ["Choose which service to use when sharing files from the Shelf. Click the service's button in the Shelf to select files, or drag files onto it to share immediately."])
            }

            if shelfOn {
                MoreInAdvanced(.shelf)
            }
        }
        .navigationTitle("Shelf")
    }
}

/// Advanced › Shelf: how it opens, takes drops and orders its items.
struct ShelfAdvancedSettings: View {
    @ObservedObject private var coordinator = NotchViewCoordinator.shared

    var body: some View {
        Section {
            Defaults.Toggle(key: .openShelfByDefault) {
                Text("Open the Shelf by default if items are present")
                if coordinator.openLastTabByDefault {
                    Text("Not used while Remember last tab is on.")
                }
            }
            .settingsItem("Open the Shelf by default if items are present")
            .disabled(coordinator.openLastTabByDefault)
            Defaults.Toggle(key: .expandedDragDetection) {
                Text("Expanded drag detection area")
            }
            .settingsItem("Expanded drag detection area")
            Defaults.Toggle(key: .copyOnDrag) {
                Text("Copy items on drag")
            }
            .settingsItem("Copy items on drag")
            Defaults.Toggle(key: .autoRemoveShelfItems) {
                Text("Remove from the Shelf after dragging")
            }
            .settingsItem("Remove from the Shelf after dragging")
            Defaults.Toggle(key: .reverseShelfOrdering) {
                Text("Keep newer Shelf items in front")
            }
            .settingsItem("Keep newer Shelf items in front")
        } header: {
            AdvancedHeader(area: .shelf)
        }
    }
}
