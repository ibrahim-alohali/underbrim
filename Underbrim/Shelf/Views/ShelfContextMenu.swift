//
//  ShelfContextMenu.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The AppKit menu for shelf items, built for the items selected when it
//  opens. ShelfMenuActionTarget carries out what's chosen in it.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

enum ContextMenuAction: String {
    case quickLook
    case open
    case share
    case rename
    case showInFinder
    case copyPath
    case copy
    case remove
    case removeBackground
    case convertImage
    case createPDF
    case compress
}

@MainActor
enum ShelfContextMenuBuilder {
static func present(
    item: ShelfItem, event: NSEvent, in view: NSView,
    onShare: @escaping (NSView?) -> Void, onQuickLook: @escaping ([URL]) -> Void
) {
    let selection = ShelfSelectionModel.shared
    if !selection.isSelected(item.id) { selection.selectSingle(item) }
    let menu = NSMenu()

    func addMenuItem(title: String, contextAction: ContextMenuAction? = nil) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let contextAction {
            mi.representedObject = contextAction.rawValue
        }
        menu.addItem(mi)
    }

    let selectedItems = selection.selectedItems(in: ShelfStateViewModel.shared.items)
    let selectedFileURLs = selectedItems.compactMap { $0.fileURL }
    let selectedLinkURLs: [URL] = selectedItems.compactMap { itm in
        if case .link(let url) = itm.kind { return url }
        return nil
    }
    let selectedFolderURLs = selectedFileURLs.filter { isDirectory($0) }
    // URLs valid for Open/Open With (exclude folders)
    let selectedOpenableURLs = selectedItems.compactMap { itm -> URL? in
        if let u = itm.fileURL { return isDirectory(u) ? nil : u }
        if case .link(let url) = itm.kind { return url }
        return nil
    }

    if !selectedOpenableURLs.isEmpty {
        addMenuItem(title: ShelfStrings.open, contextAction: .open)
    }

    if !selectedOpenableURLs.isEmpty {
        let openWith = NSMenuItem(title: ShelfStrings.openWith, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        // Choose a representative URL to compute apps (prefer current item if not a folder)
        let baseURLForApps: URL? = {
            if let u = item.fileURL, !isDirectory(u) { return u }
            if case .link(let u) = item.kind { return u }
            return selectedOpenableURLs.first
        }()

        let openWithApps: [URL] = {
            guard let u = baseURLForApps else { return [] }
            if u.isFileURL {
                var results = NSWorkspace.shared.urlsForApplications(toOpen: u)
                if results.isEmpty, let uti = try? u.resourceValues(forKeys: [.contentTypeKey]).contentType {
                    results = NSWorkspace.shared.urlsForApplications(toOpen: uti)
                }
                return Array(Set(results))
            } else {
                return Array(Set(NSWorkspace.shared.urlsForApplications(toOpen: u)))
            }
        }()
        let defaultApp = defaultAppURL(for: item)

        if openWithApps.isEmpty {
            let noApps = NSMenuItem(title: ShelfStrings.noCompatibleApps, action: nil, keyEquivalent: "")
            noApps.isEnabled = false
            submenu.addItem(noApps)
        } else {
            if let defaultApp = defaultApp {
                let appName = AppInfo.name(url: defaultApp)
                let def = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
                def.representedObject = defaultApp
                def.image = nsAppIcon(for: defaultApp, size: 16)

                let title = NSMutableAttributedString(string: appName, attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.labelColor
                ])
                let defaultPart = NSAttributedString(string: String(localized: " (default)"), attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
                title.append(defaultPart)
                def.attributedTitle = title
                submenu.addItem(def)

                if openWithApps.count > 1 || !openWithApps.contains(defaultApp) {
                    submenu.addItem(NSMenuItem.separator())
                }
            }
            for appURL in openWithApps where appURL != defaultApp {
                let mi = NSMenuItem(title: AppInfo.name(url: appURL), action: nil, keyEquivalent: "")
                mi.representedObject = appURL
                mi.image = nsAppIcon(for: appURL, size: 16)
                submenu.addItem(mi)
            }
        }

        submenu.addItem(NSMenuItem.separator())
        let other = NSMenuItem(title: ShelfStrings.other, action: nil, keyEquivalent: "")
        other.representedObject = "__OTHER__"
        submenu.addItem(other)

        openWith.submenu = submenu
        menu.addItem(openWith)
    }

    if !selectedFileURLs.isEmpty { addMenuItem(title: ShelfStrings.showInFinder, contextAction: .showInFinder) }
    // Allow Quick Look for files and link URLs
    if !selectedFileURLs.isEmpty || !selectedLinkURLs.isEmpty {
        // Add Quick Look menu item
        let quickLookItem = NSMenuItem(title: ShelfStrings.quickLook, action: nil, keyEquivalent: "")
        quickLookItem.representedObject = ContextMenuAction.quickLook.rawValue
        menu.addItem(quickLookItem)
    }

    menu.addItem(NSMenuItem.separator())
    addMenuItem(title: ShelfStrings.share, contextAction: .share)

    // Add image processing options for image files grouped under "Image Actions"
    let imageURLs = selectedFileURLs.filter { ImageProcessingService.shared.isImageFile($0) }
    if !imageURLs.isEmpty {
        menu.addItem(NSMenuItem.separator())

        let imageActions = NSMenuItem(title: ShelfStrings.imageActions, action: nil, keyEquivalent: "")
        let imageSubmenu = NSMenu()

        // Remove Background - only for single images
        if imageURLs.count == 1 {
            let removeBg = NSMenuItem(title: ShelfStrings.removeBackground, action: nil, keyEquivalent: "")
            removeBg.representedObject = ContextMenuAction.removeBackground.rawValue
            imageSubmenu.addItem(removeBg)
        }

        // Convert Image - only for single images
        if imageURLs.count == 1 {
            let convertItem = NSMenuItem(title: ShelfStrings.convertImage, action: nil, keyEquivalent: "")
            convertItem.representedObject = ContextMenuAction.convertImage.rawValue
            imageSubmenu.addItem(convertItem)
        }

        // Create PDF - for one or more images
        let createPDF = NSMenuItem(title: ShelfStrings.createPDF, action: nil, keyEquivalent: "")
        createPDF.representedObject = ContextMenuAction.createPDF.rawValue
        imageSubmenu.addItem(createPDF)

        imageActions.submenu = imageSubmenu
        menu.addItem(imageActions)
        menu.addItem(NSMenuItem.separator())
    }

    // Add compression option for files/folders (single or multiple)
    if !selectedFileURLs.isEmpty {
        let compressItem = NSMenuItem(title: ShelfStrings.compress, action: nil, keyEquivalent: "")
        compressItem.representedObject = ContextMenuAction.compress.rawValue
        menu.addItem(compressItem)
    }

    if selectedItems.count == 1, case .file = item.kind { addMenuItem(title: ShelfStrings.rename, contextAction: .rename) }

    // Always show "Copy" for all item types
    addMenuItem(title: ShelfStrings.copy, contextAction: .copy)
    // If there are file URLs, add "Copy Path" as an alternate menu item (Option key)
    if !selectedFileURLs.isEmpty {
        let copyPathItem = NSMenuItem(title: ShelfStrings.copyPath, action: nil, keyEquivalent: "")
        copyPathItem.representedObject = ContextMenuAction.copyPath.rawValue
        copyPathItem.isAlternate = true
        copyPathItem.keyEquivalentModifierMask = [.option]
        menu.addItem(copyPathItem)
    }

    menu.addItem(NSMenuItem.separator())
    addMenuItem(title: ShelfStrings.remove, contextAction: .remove)

    let actionTarget = ShelfMenuActionTarget(item: item, items: selectedItems, view: view, onShare: onShare, onQuickLook: onQuickLook)

    for menuItem in menu.items {
        if menuItem.isSeparatorItem { continue }
        menuItem.target = actionTarget
        menuItem.action = #selector(ShelfMenuActionTarget.handle(_:))

        if let submenu = menuItem.submenu {
            for subItem in submenu.items {
                if !subItem.isSeparatorItem {
                    subItem.target = actionTarget
                    subItem.action = #selector(ShelfMenuActionTarget.handle(_:))
                }
            }
        }
    }

    menu.retainActionTarget(actionTarget)

    NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

private func isDirectory(_ url: URL) -> Bool {
    url.accessSecurityScopedResource { scoped in
        (try? scoped.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

func nsAppIcon(for appURL: URL, size: CGFloat) -> NSImage? {
    let baseIcon = NSWorkspace.shared.icon(forFile: appURL.path)
    baseIcon.isTemplate = false

    let targetSize = NSSize(width: size, height: size)
    let rendered = NSImage(size: targetSize, flipped: false) { rect in
        NSGraphicsContext.current?.imageInterpolation = .high
        baseIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: [
            .interpolation: NSImageInterpolation.high.rawValue
        ])
        return true
    }

    rendered.size = targetSize
    return rendered
}

@MainActor
func defaultAppURL(for item: ShelfItem) -> URL? {
    if let fileURL = item.fileURL {
        return NSWorkspace.shared.urlForApplication(toOpen: fileURL)
    } else if case .link(let url) = item.kind {
        return NSWorkspace.shared.urlForApplication(toOpen: url)
    }
    return nil
}
