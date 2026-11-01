//
//  UnreadWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Unread counts of chat and mail apps: the number each running app puts on its Dock icon, read
//  from LaunchServices' private "StatusLabel" (no permission; where the call is missing, no numbers
//  show). WhatsApp and Messages badge their icons another way, so they aren't listed.
//

import AppKit
import SwiftUI

enum AppBadges {
    static let apps = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord",
        "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.microsoft.Outlook", "com.apple.mail",
        "org.whispersystems.signal-desktop", "com.readdle.SparkDesktop", "com.readdle.smartemail-Mac",
        "us.zoom.xos", "com.facebook.archon.developerID", "com.facebook.archon", "com.viber.osx",
        "jp.naver.line.mac", "com.skype.skype", "Mattermost.Desktop", "im.riot.app",
    ]

    private typealias CreateASN = @convention(c) (CFAllocator?, Int32) -> Unmanaged<CFTypeRef>?
    private typealias CopyItem = @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    private static let functions: (create: CreateASN, copy: CopyItem)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
              let create = dlsym(handle, "_LSASNCreateWithPid"),
              let copy = dlsym(handle, "_LSCopyApplicationInformationItem") else { return nil }
        return (unsafeBitCast(create, to: CreateASN.self), unsafeBitCast(copy, to: CopyItem.self))
    }()

    static func badge(pid: pid_t) -> String? {
        guard let functions, let asn = functions.create(kCFAllocatorDefault, pid)?.takeRetainedValue(),
              let value = functions.copy(-2, asn, "StatusLabel" as CFString)?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return label(from: value)
    }

    static func label(from value: [String: Any]) -> String? {
        guard let label = value["label"] as? String, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return label
    }

    @MainActor static func current() -> [(bundleID: String, badge: String?)] {
        let running = NSWorkspace.shared.runningApplications
        return apps.compactMap { id in
            running.first { $0.bundleIdentifier == id }.map { (id, badge(pid: $0.processIdentifier)) }
        }
    }
}

struct UnreadWidget: View {
    @State private var entries: [(bundleID: String, badge: String?)] = []
    private let columns = 3
    var alone = false

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        Group {
            if alone {
                aloneLayout
            } else if entries.isEmpty {
                Text(String(localized: "Open Slack, Teams, Discord or your mail app to see unread counts here"))
                    .font(.notchCaption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(QuickLaunchWidget.icon), spacing: QuickLaunchWidget.spacing), count: columns),
                          alignment: .leading, spacing: QuickLaunchWidget.spacing) {
                    ForEach(entries.prefix(2 * columns), id: \.bundleID) { entry in
                        BadgedAppButton(bundleID: entry.bundleID, badge: entry.badge)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .task {
            while !Task.isCancelled {
                entries = AppBadges.current()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Unread"))
    }

    private var aloneLayout: some View {
        AloneFrame(widget: .unread) {
            AloneTitle(symbol: HomeWidget.unread.symbol, title: HomeWidget.unread.title)
        } trailing: {
            if total > 0 {
                Text(total, format: .number).font(.notchTitle.monospacedDigit()).foregroundStyle(.white)
            }
        } row: {
            if entries.isEmpty {
                Text(String(localized: "Open Slack, Teams, Discord or your mail app to see unread counts here"))
                    .font(.notchCaption).foregroundStyle(.secondary)
            } else {
                // A few: each with its name, so the row says which; more: the icons and counts.
                HStack(spacing: entries.count > Self.namedUpTo ? 12 : 16) {
                    ForEach(entries, id: \.bundleID) { entry in
                        BadgedAppButton(bundleID: entry.bundleID, badge: entry.badge, size: Self.aloneIcon,
                                        named: entries.count <= Self.namedUpTo)
                    }
                }
                // Room for the counts over the icons' corners.
                .padding(.top, 4)
            }
        }
    }

    private static let namedUpTo = 3

    /// The counts that are numbers, added up ("•" says only that there's something).
    private var total: Int { entries.compactMap { $0.badge.flatMap { Int($0) } }.reduce(0, +) }

    private static let aloneIcon: CGFloat = 22
}

private struct BadgedAppButton: View {
    let bundleID: String
    let badge: String?
    var size = QuickLaunchWidget.icon
    var named = false

    private var name: String { AppInfo.name(bundleID: bundleID) ?? bundleID }

    var body: some View {
        Button { AppInfo.activate(bundleID) } label: {
            if named {
                HStack(spacing: 6) {
                    AppIconView(bundleID: bundleID, size: size)
                    Text(name).font(.notchBody).foregroundStyle(.white)
                    if let badge { count(badge) }
                }
                .contentShape(Rectangle())
            } else {
                AppIconView(bundleID: bundleID, size: size)
                    .overlay(alignment: .topTrailing) {
                        if let badge { count(badge).offset(x: 5, y: -4) }
                    }
            }
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(String(localized: "Open \(name)"))
        .accessibilityValue(badge.map { String(localized: "\($0) unread") } ?? String(localized: "Nothing unread"))
    }

    private func count(_ badge: String) -> some View {
        Text(badge)
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(.red, in: Capsule())
    }
}
