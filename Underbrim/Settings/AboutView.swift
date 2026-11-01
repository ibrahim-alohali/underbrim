//
//  AboutView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI

struct AboutView: View {
    static let repository = URL(string: "https://github.com/ibrahim-alohali/underbrim")!
    static let author = "Ibrahim Alohali"
    static let notices = repository.appending(path: "blob/main/NOTICE")

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.releaseVersionNumber ?? "unknown")
                    .settingsItem("Version")
                Button(String(localized: "Show Welcome Tour")) { NotchViewCoordinator.shared.startFirstRun() }
                    .settingsItem("Show Welcome Tour")
            } header: {
                hero
            }

            Section {
                Link(destination: Self.repository) {
                    Label {
                        Text("Underbrim on GitHub")
                    } icon: {
                        Image("Github").resizable().scaledToFit().frame(width: 16, height: 16)
                    }
                }
                .settingsItem("Underbrim on GitHub")
                Link(destination: Self.notices) {
                    Label("Open-Source Notices", systemImage: "doc.text")
                }
                .settingsItem("Open-Source Notices")
            } header: {
                Text("Source")
            }

            // GPL-3.0 section 0: an interactive program shows its notices.
            Section {
                Text("Underbrim © 2026 \(Self.author) and contributors.")
                Text("Underbrim is free software: you can share and change it under the GNU General Public License, version 3. It comes with no warranty.")
                    .foregroundStyle(.secondary)
                Link("GNU General Public License, version 3", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                    .settingsItem("GNU General Public License, version 3")
            } header: {
                Text("License")
            }

            // Quit is in the sidebar, on every page.
            Section {
                HStack {
                    Button(String(localized: "Restart Underbrim")) { ApplicationRelauncher.restart() }
                    Spacer()
                }
                .settingsItem("Restart Underbrim")
            }
        }
        .navigationTitle("About")
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Underbrim")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Made by \(Self.author)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(SettingsTab.about.info.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }
}
