//
//  AppIcons.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 16/08/24.
//

import SwiftUI
import AppKit

private func applicationURL(for bundleID: String) -> URL? {
    let workspace = NSWorkspace.shared
    let normalizedID = normalizeBundleIdentifier(bundleID)

    if let appURL = workspace.urlForApplication(withBundleIdentifier: normalizedID) {
        return appURL
    }

    return workspace.runningApplications
        .filter {
            !$0.isTerminated
                && $0.bundleIdentifier.map(normalizeBundleIdentifier) == normalizedID
        }
        .sorted(by: AppNameResolver.preferRegularApplication)
        .first?.bundleURL
}

func appIcon(for bundleID: String) -> Image {
    let workspace = NSWorkspace.shared

    if let appURL = applicationURL(for: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        return Image(nsImage: appIcon)
    }

    return Image(nsImage: workspace.icon(for: .applicationBundle))
}

func appIconAsNSImage(for bundleID: String) -> NSImage? {
    let workspace = NSWorkspace.shared

    if let appURL = applicationURL(for: bundleID) {
        let appIcon = workspace.icon(forFile: appURL.path)
        appIcon.size = NSSize(width: 256, height: 256)
        return appIcon
    }
    return nil
}
