//
//  DownloadSettingsView.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import SwiftUI

struct DownloadSettingsSection: View {
    @State private var chromeStatus = ChromeIntegration.status()
    @State private var message: String?
    private let store = DownloadsStore.shared
    private let relay = RelayListener.shared

    private static let chromeInfo: LocalizedStringKey = "A small extension reports each download's file, size and state (paused, cancelled, failed, or flagged by Chrome). In Chrome open chrome://extensions, turn on Developer mode, choose Load unpacked, and select the folder shown. It reads nothing else and never accepts a flagged download for you. Chrome keeps unpacked extensions on only while Developer mode is on."

    var body: some View {
        Section {
            Defaults.Toggle(key: .showDownloadActivity) { Text("Show downloads in the closed notch") }
                .settingsItem("Show downloads in the closed notch")
                .onAppear {
                    relay.check()
                    chromeStatus = ChromeIntegration.status()
                }
            Defaults.Toggle(key: .addFinishedDownloadsToShelf) {
                SettingsLabel("Add finished downloads to the Shelf", info: "The file stays in your Downloads folder; the Shelf just points to it.")
            }
            .settingsItem("Add finished downloads to the Shelf")
            chrome
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        } header: {
            Text("Downloads")
        }
    }

    @ViewBuilder private var chrome: some View {
        if !ChromeIntegration.chromeInstalled {
            Label("Google Chrome isn't installed.", systemImage: "info.circle").foregroundStyle(.secondary)
        }
        // The extension's messages go through the relay too.
        let relayProblem = relay.health?.problem
        if let relayProblem {
            Label(relayProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        switch chromeStatus {
        case .notInstalled:
            HStack {
                Button("Set Up Chrome Downloads") { installChrome() }.buttonStyle(.borderedProminent).tint(.accentUnderText)
                    .disabled(relayProblem != nil)
                SettingsInfo(Self.chromeInfo)
            }
            .settingsItem("Chrome")
        case .outdated:
            HStack {
                Button("Update Chrome Connection") { installChrome() }.buttonStyle(.borderedProminent).tint(.accentUnderText)
                SettingsInfo(Self.chromeInfo)
            }
            .settingsItem("Chrome")
        case .installed:
            if let seen = store.chromeExtensionSeen {
                Label {
                    TimelineView(.everyMinute) { _ in
                        Text("Extension connected \(RelativeTimeText.string(for: seen, now: .now))")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label("Connection ready — waiting for the extension (load it in Chrome, then start a download)",
                      systemImage: "puzzlepiece.extension")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Show Extension Folder & Open Chrome Extensions") { ChromeIntegration.revealExtension() }
                Button("Remove") {
                    ChromeIntegration.uninstall()
                    chromeStatus = ChromeIntegration.status()
                }
                SettingsInfo(Self.chromeInfo)
            }
            .settingsItem("Chrome")
        }
    }

    private func installChrome() {
        do {
            try ChromeIntegration.install()
            chromeStatus = ChromeIntegration.status()
            ChromeIntegration.revealExtension()
            message = String(localized: "Connection installed. Now load the extension in Chrome.")
        } catch {
            message = error.localizedDescription
        }
    }
}

struct DownloadAdvancedSettings: View {
    private let watcher = DownloadProgressWatcher.shared

    var body: some View {
        Section {
            Defaults.Toggle(key: .browserDownloadProgress) {
                SettingsLabel("Show progress that browsers report",
                              info: "Safari (and Chrome without the extension) publish download progress to macOS. A percentage appears only when the browser reports the file size.",
                              "Safari has no downloads API for extensions, so Safari shows only what it reports to macOS: no speed or time estimates.")
            }
            .settingsItem("Show progress that browsers report")
            LabeledContent("Downloads folder") {
                HStack {
                    Text(watcher.folder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { watcher.chooseFolder() }
                }
            }
            .settingsItem("Downloads folder")
        } header: {
            AdvancedHeader(area: .downloads)
        }
    }
}
