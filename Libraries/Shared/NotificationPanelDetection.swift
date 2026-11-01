//
//  NotificationPanelDetection.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation

enum NotificationPanelDetection {
    /// The app's name in a banner's description, before the first comma:
    /// "Messages, …" in English, "\u{200F}الرسائل، …" in Arabic.
    static func appName(inDescription description: String) -> String? {
        description.split(maxSplits: 1, whereSeparator: { $0 == "," || $0 == "،" }).first.map { cleanedAppName(String($0)) }
    }

    /// A name without the invisible direction marks around it (WhatsApp's `localizedName`
    /// is literally "\u{200E}WhatsApp"; Arabic banners add RLM) and surrounding space.
    static func cleanedAppName(_ name: String) -> String {
        name.filter { !$0.unicodeScalars.allSatisfy(bidiMarks.contains) }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedAppName(_ name: String) -> String { cleanedAppName(name).lowercased() }

    /// LRM, RLM, ALM, the isolates and the embeddings/overrides.
    private static let bidiMarks: CharacterSet = {
        var set = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{061C}")
        set.insert(charactersIn: "\u{2066}"..."\u{2069}")
        set.insert(charactersIn: "\u{202A}"..."\u{202E}")
        return set
    }()
    static let panelListIdentifier = "AXNotificationListItems"
    static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterAlert",
        "AXNotificationCenterNotification",
        "AXNotificationCenterBannerWindow",
        "AXNotificationCenterAlertStack"
    ]

    static func isPanel(
        subrole: String?,
        identifier: String?,
        stackingIdentifier: String? = nil,
        insideNotificationList: Bool = false
    ) -> Bool {
        subrole == "AXNotificationCenterPanel"
            || identifier == "widget-editor-button"
            || (insideNotificationList
                && subrole == "AXButton"
                && stackingIdentifier?.hasPrefix("stack-") == true)
    }

    static func isDesktopWidget(identifier: String?) -> Bool {
        identifier?.hasPrefix("widget-local:") == true
    }

    static func isBanner(subrole: String?) -> Bool {
        bannerSubroles.contains(subrole ?? "")
    }
}

enum NotificationObservationPolicy {
    static let structuralNotifications: Set<String> = [
        "AXWindowCreated",
        "AXCreated",
        "AXUIElementDestroyed",
        "AXChildrenChanged",
        "AXLayoutChanged"
    ]

    static func shouldObserveElement(subrole: String?, identifier: String?) -> Bool {
        !NotificationPanelDetection.isPanel(subrole: subrole, identifier: identifier)
            && !NotificationPanelDetection.isDesktopWidget(identifier: identifier)
    }

    static func shouldScan(
        notification: String,
        subrole: String? = nil,
        identifier: String? = nil
    ) -> Bool {
        guard structuralNotifications.contains(notification) else { return false }
        if notification == "AXWindowCreated" { return true }
        return shouldObserveElement(subrole: subrole, identifier: identifier)
    }
}
