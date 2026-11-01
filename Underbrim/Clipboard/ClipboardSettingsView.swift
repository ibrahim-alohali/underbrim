//
//  ClipboardSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import SwiftUI

struct ClipboardSettingsView: View {
    private let history = ClipboardHistory.shared
    private let screenshots = ScreenshotWatcher.shared
    @Default(.clipboardExcludedApps) private var excluded
    @Default(.clipboardHistoryEnabled) private var historyEnabled
    @State private var confirmDeleteEarlier = false

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .clipboardHistoryEnabled) {
                    SettingsLabel("Keep clipboard history", info: "Text, links and images you copy, kept on this Mac only and encrypted.")
                }
                .settingsItem("Keep clipboard history")
                Defaults.Toggle(key: .clipboardPaused) { Text("Pause history") }
                    .disabled(!historyEnabled)
                    .settingsItem("Pause history")
                stateRow
            } header: {
                SettingsPageHeader(tab: .clipboard, section: "History")
            } footer: {
                Text("Not kept: passwords and other items apps mark as private or temporary, copies from password managers and the apps below, and messages containing one-time codes. These filters can't recognise every secret, so pause history before copying something sensitive.")
            }

            if history.earlierKept { earlierSection }

            Section {
                ForEach(excluded.sorted(), id: \.self) { bundleID in
                    HStack {
                        AppIconView(bundleID: bundleID, size: 16)
                        Text(ClipboardHistory.appName(bundleID) ?? ClipboardPolicy.knownNames[bundleID] ?? bundleID)
                        Spacer()
                        Button(String(localized: "Remove")) { excluded.remove(bundleID) }
                            .buttonStyle(.borderless)
                    }
                }
                Menu(String(localized: "Add a Running App")) {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let id = app.bundleIdentifier { excluded.insert(id) }
                        }
                    }
                }
                .settingsItem("Never keep copies from")
            } header: {
                Text("Never keep copies from")
            }

            Section {
                Button(String(localized: "Clear Unpinned Items")) { history.confirmClear() }
                    .disabled(history.entries.isEmpty)
                    .settingsItem("Clear Unpinned Items")
            }

            Section {
                Defaults.Toggle(key: .screenshotShelfEnabled) {
                    SettingsLabel("Add new screenshots to the Shelf", info: "Only screenshots taken from now on; the files stay where macOS saved them.")
                }
                .settingsItem("Add new screenshots to the Shelf")
                LabeledContent("Folder") {
                    HStack {
                        Text(screenshots.folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button(String(localized: "Choose…")) { screenshots.chooseFolder() }
                    }
                }
                .settingsItem("Folder")
                if case .folderUnavailable(let path) = screenshots.state {
                    Label("Can't watch \(path). Choose the folder again to allow access.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Screenshots")
            }
            .onAppear { screenshots.followFolder() }

            MoreInAdvanced(.clipboard)
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
    }

    @ViewBuilder private var stateRow: some View {
        switch history.state {
        case .recording:
            Label("Keeping what you copy", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            if history.macOSWillAsk {
                Label("macOS is set to ask before this app reads the clipboard, so you'll see a prompt for each copy. Choose Allow in System Settings › Privacy & Security › Paste from Other Apps.",
                      systemImage: "exclamationmark.bubble").foregroundStyle(.orange)
            }
        case .paused: Label("Paused", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .locked: Label("Paused while the screen is locked", systemImage: "lock").foregroundStyle(.secondary)
        case .storageFull: Label("Storage full — unpin or delete items to resume", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
        case .accessDenied:
            Label("Blocked by macOS. Allow it in System Settings › Privacy & Security › Paste from Other Apps.", systemImage: "hand.raised")
                .foregroundStyle(.orange)
        case .opening:
            Label("Opening. If macOS asks about Underbrim's clipboard key, answer that dialog.", systemImage: "key")
                .foregroundStyle(.secondary)
        case .keyUnavailable:
            Label("The encryption key couldn't be read. Turn history off and on to try again, or delete all history to start over with a new key.",
                  systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
        case .storageFailed:
            Label("History couldn't be read or saved on this Mac, so it has stopped. Nothing was deleted. Turn history off and on to try again, or delete all history to start over.",
                  systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
        case .off: EmptyView()
        }
    }

    private var earlierSection: some View {
        Section {
            Text("Clipboard history from before this version is still sealed with a key in your Keychain. Bringing it back asks macOS for that key once, so it may ask for your login password.")
            HStack {
                Button("Bring It Back") { history.bringBackEarlier() }
                Button("Delete It…") { confirmDeleteEarlier = true }
                    .confirmationDialog(String(localized: "Delete the earlier clipboard history?"), isPresented: $confirmDeleteEarlier) {
                        Button(String(localized: "Delete"), role: .destructive) { history.deleteEarlier() }
                    } message: {
                        Text("Pinned items are deleted too. This can't be undone.")
                    }
            }
            .disabled(history.bringingBack)
            if history.bringBackFailed {
                Label("The earlier history couldn't be opened, so it's kept as it was.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("History from an earlier version")
        }
    }
}

/// Advanced › Clipboard. Shown with the history off too, as what it kept is still there.
struct ClipboardAdvancedSettings: View {
    private let history = ClipboardHistory.shared
    @Default(.clipboardRetentionDays) private var retentionDays
    @Default(.clipboardMaxEntries) private var maxEntries
    @State private var confirmErase = false

    var body: some View {
        Section {
            Picker("Keep unpinned items for", selection: $retentionDays) {
                ForEach([1, 3, 7, 30], id: \.self) { Text("\($0) days").tag($0) }
            }
            .settingsItem("Keep unpinned items for")
            Picker("Keep at most", selection: $maxEntries) {
                ForEach([50, 100, 200], id: \.self) { Text("\($0) items").tag($0) }
            }
            .onChange(of: maxEntries) { _, _ in history.applyLimits() }
            .onChange(of: retentionDays) { _, _ in history.applyLimits() }
            .settingsItem("Keep at most")
            LabeledContent("Storage used") {
                let used = Int64(history.totalBytes).formatted(.byteCount(style: .file, spellsOutZero: false))
                let budget = Int64(history.limits.budgetBytes).formatted(.byteCount(style: .file, spellsOutZero: false))
                Text("\(used) of \(budget)")
            }
            .settingsItem("Storage used")
        } header: {
            AdvancedHeader(area: .clipboard, info: ["Pinned items are never removed automatically, and they count toward the 100 MB limit. When the limit is reached, the oldest unpinned items go first; if pinned items alone fill it, recording pauses until you unpin or delete something."])
        }

        Section {
            Button(String(localized: "Delete All History and Its Key…"), role: .destructive) { confirmErase = true }
                .settingsItem("Delete All History and Its Key…")
                .confirmationDialog(String(localized: "Delete all clipboard history?"), isPresented: $confirmErase) {
                    Button(String(localized: "Delete Everything"), role: .destructive) { history.eraseAll() }
                } message: {
                    Text("Pinned items are deleted too. This can't be undone.")
                }
        } footer: {
            Text("Deleting everything also removes the encryption key, so nothing recorded so far can be read again.")
        }
    }
}
