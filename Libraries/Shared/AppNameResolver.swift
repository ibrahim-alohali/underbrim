//
//  AppNameResolver.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  An app's bundle ID from the name its banners show, for the notification
//  reader (the helper) and for the app when the reader found none.
//

import AppKit

/// The app a helper process belongs to: Safari for its WebKit and Safari
/// processes, and "com.google.Chrome" for "com.google.Chrome.helper.Renderer".
func normalizeBundleIdentifier(_ bundleID: String) -> String {
    let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = bundleID.lowercased()

    if lower.hasPrefix("com.apple.safaritechnologypreview.") {
        return "com.apple.SafariTechnologyPreview"
    }
    if lower.hasPrefix("com.apple.webkit.") || lower.hasPrefix("com.apple.safari.") {
        return "com.apple.Safari"
    }
    let components = bundleID.components(separatedBy: ".")
    if let helperIndex = components.firstIndex(where: { $0.lowercased() == "helper" }) {
        return components[0..<helperIndex].joined(separator: ".")
    }
    return bundleID
}

/// Looks for the app, cheapest first:
///   1. running applications, matched on their name (regular apps first)
///   2. "<name>.app" and "<name without spaces>.app" in the applications folders
///   3. one listing of those folders, matched on the file name, the name
///      Finder shows (translated, as banners show it), and the bundle's names
/// The result is the app's own bundle ID (`normalizeBundleIdentifier`). Hits
/// and misses are remembered, so a chatty app never reads the disk again.
final class AppNameResolver: @unchecked Sendable {
    static let shared = AppNameResolver()

    /// Held only around the cache, never during a scan: two lookups at once
    /// can both scan, and write the same answer.
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    /// /Applications, the user's own ~/Applications, then /System/Applications.
    /// The home folder comes from the account, not `$HOME`.
    private static let searchDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
            .appendingPathComponent("Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications")
    ]

    func bundleID(forAppNamed name: String) -> String? {
        let target = NotificationPanelDetection.normalizedAppName(name)
        guard !target.isEmpty else { return nil }

        lock.lock()
        let cached = cache[target]
        lock.unlock()
        if let cached { return cached }

        let resolved = resolve(target: target, name: name).map(normalizeBundleIdentifier)

        lock.lock()
        cache[target] = resolved
        lock.unlock()
        return resolved
    }

    private func resolve(target: String, name: String) -> String? {
        let running = NSWorkspace.shared.runningApplications
            .filter {
                guard let localizedName = $0.localizedName else { return false }
                return NotificationPanelDetection.normalizedAppName(localizedName) == target
            }
            .sorted(by: Self.preferRegularApplication)
            .compactMap(\.bundleIdentifier)
            .first
        if let running { return running }

        let displayName = NotificationPanelDetection.cleanedAppName(name)
        let withoutSpaces = displayName.replacingOccurrences(of: " ", with: "")
        let candidates = withoutSpaces == displayName ? [displayName] : [displayName, withoutSpaces]
        for directory in Self.searchDirectories {
            for candidate in candidates where !candidate.isEmpty {
                let url = directory.appendingPathComponent(candidate).appendingPathExtension("app")
                if FileManager.default.fileExists(atPath: url.path), let bundleID = Bundle(url: url)?.bundleIdentifier {
                    return bundleID
                }
            }
        }

        // One listing per folder, without going into subfolders.
        for directory in Self.searchDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                guard let bundle = Bundle(url: entry), let bundleID = bundle.bundleIdentifier else { continue }
                let names = [
                    entry.deletingPathExtension().lastPathComponent,
                    FileManager.default.displayName(atPath: entry.path),
                    bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                    bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ]
                if names.contains(where: { $0.map { NotificationPanelDetection.normalizedAppName($0) == target } ?? false }) {
                    return bundleID
                }
            }
        }
        return nil
    }

    /// Regular apps before background ones, then the oldest process.
    static func preferRegularApplication(_ lhs: NSRunningApplication, _ rhs: NSRunningApplication) -> Bool {
        if lhs.activationPolicy == .regular, rhs.activationPolicy != .regular { return true }
        if rhs.activationPolicy == .regular, lhs.activationPolicy != .regular { return false }
        return lhs.processIdentifier < rhs.processIdentifier
    }
}
