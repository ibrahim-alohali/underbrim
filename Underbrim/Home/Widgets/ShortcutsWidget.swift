//
//  ShortcutsWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The user's shortcuts as buttons, through macOS's `shortcuts` command: click to run, or drop a
//  file on one to run it with that file.
//

import AppKit
import SwiftUI

@MainActor
@Observable
final class ShortcutsModel {
    static let shared = ShortcutsModel()
    nonisolated static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    private(set) var names: [String] = []
    private(set) var loaded = false
    private(set) var running: String?
    private(set) var finished: (name: String, succeeded: Bool)?
    @ObservationIgnored private var loading = false

    /// Re-reads the list (when Home appears); keeps the old one meanwhile.
    func reload() {
        guard !loading else { return }
        loading = true
        Task {
            let output = await Self.run(["list"])
            loading = false
            loaded = true
            if let output { names = Self.names(fromList: output) }
        }
    }

    func run(_ name: String, input: URL? = nil) {
        guard running == nil else { return }
        running = name
        finished = nil
        // "--" so a name that starts with a dash is still a name.
        let arguments = ["run"] + (input.map { ["--input-path", $0.path] } ?? []) + ["--", name]
        Task {
            let succeeded = await Self.run(arguments) != nil
            running = nil
            finished = (name, succeeded)
            AccessibilityNotification.Announcement(succeeded ? String(localized: "\(name) finished") : String(localized: "\(name) failed")).post()
            try? await Task.sleep(for: .seconds(2))
            if finished?.name == name { finished = nil }
        }
    }

    nonisolated static func names(fromList output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private nonisolated static func run(_ arguments: [String]) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = Process.cleanEnvironment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }.value
    }
}

struct ShortcutsWidget: View {
    private let model = ShortcutsModel.shared
    var alone = false

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        Group {
            if alone {
                aloneLayout
            } else if model.loaded && model.names.isEmpty {
                VStack(spacing: 4) {
                    Text(String(localized: "No shortcuts yet")).font(.notchCaption).foregroundStyle(.secondary)
                    NotchTextButton(title: String(localized: "Open Shortcuts")) { AppInfo.activate("com.apple.shortcuts") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.names, id: \.self) { ShortcutRow(name: $0) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear { model.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Shortcuts"))
    }

    /// Alone: the shortcuts in one row under the band, scrolling sideways when there are more.
    private var aloneLayout: some View {
        AloneFrame(widget: .shortcuts) {
            AloneTitle(symbol: HomeWidget.shortcuts.symbol, title: HomeWidget.shortcuts.title)
        } trailing: {
            EmptyView()
        } row: {
            Group {
                if model.loaded && model.names.isEmpty {
                    HStack(spacing: 6) {
                        Text(String(localized: "No shortcuts yet")).font(.notchCaption).foregroundStyle(.secondary)
                        NotchTextButton(title: String(localized: "Open Shortcuts")) { AppInfo.activate("com.apple.shortcuts") }
                    }
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(model.names, id: \.self) { ShortcutRow(name: $0) }
                        }
                    }
                    .scrollIndicators(.never)
                    // Those past the edge: it fades there, as Home's row does.
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                }
            }
            .frame(minWidth: 0, idealWidth: HomeWidget.shortcuts.width(HomeWidget.shortcuts.size, height: 0), maxWidth: .infinity,
                   alignment: .leading)
            .frame(height: 20)
        }
    }
}

private struct ShortcutRow: View {
    let name: String
    private let model = ShortcutsModel.shared
    @State private var hovering = false
    @State private var targeted = false

    private var symbol: String {
        if model.running == name { return "hourglass" }
        if let finished = model.finished, finished.name == name { return finished.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill" }
        return "bolt.fill"
    }

    var body: some View {
        Button { model.run(name) } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.notchSymbol(size: 10))
                    .foregroundStyle(symbol == "xmark.octagon.fill" ? .red : symbol == "checkmark.circle.fill" ? .green : .orange)
                    .frame(width: 14)
                Text(name).font(.notchBody).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(.white.opacity(targeted ? 0.2 : hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One at a time: the others wait, dimmed, until it finishes.
        .disabled(model.running != nil)
        .notchDisabled(model.running.map { $0 != name } ?? false)
        .onHover { hovering = $0 }
        .help(String(localized: "Run \(name). Drop a file here to run it with that file."))
        .accessibilityLabel(String(localized: "Run \(name)"))
        // Refused while one runs, so the file goes back where it came from.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.running == nil, let url = urls.first, url.isFileURL else { return false }
            model.run(name, input: url)
            return true
        } isTargeted: { targeted = $0 && model.running == nil }
    }
}
