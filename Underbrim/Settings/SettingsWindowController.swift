//
//  SettingsWindowController.swift
//  Underbrim
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    static let identifier = "SettingsWindow"
    private var camera: CameraModel?

    private init() {
        // Tall enough for the whole sidebar, within the screen.
        let height = min(800, (NSScreen.main?.visibleFrame.height ?? 800) - 40)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCamera(_ camera: CameraModel) {
        self.camera = camera
        setupWindow()
    }

    private func setupWindow() {
        guard let window, let camera else { return }

        window.title = String(localized: "Underbrim Settings")
        // Light or dark as the Mac is; its pages and sidebar run up under the title bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        // Settings windows don't zoom. (Its size limits come from SettingsView.)
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // Make it behave like a regular app window with proper Spaces support
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]

        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false

        // Configure window to be a standard document-style window
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier(Self.identifier)

        // Create the SwiftUI content
        let settingsView = SettingsView(camera: camera)
        let hostingView = NSHostingView(rootView: settingsView)
        window.contentView = hostingView

        // Handle window closing
        window.delegate = self
    }

    func showWindow(tab: SettingsTab) {
        SettingsSearch.shared.query = ""  // a search left in the window would cover the page asked for
        SettingsNavigation.shared.selectedTab = tab
        showWindow()
    }

    func showWindow() {
        // Or one could stay up over the window.
        NotificationCenter.default.post(name: .closeIslandPopovers, object: nil)
        // Set app to regular mode first
        NSApp.setActivationPolicy(.regular)

        // If window is already visible, bring it to front properly
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            return
        }

        // Show the window with proper ordering
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.center()

        // Activate the app and ensure window gets focus
        NSApp.activate(ignoringOtherApps: true)

        // Force window to front after activation
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    override func close() {
        super.close()
        relinquishFocus()
    }

    private func relinquishFocus() {
        window?.orderOut(nil)

        // Set app back to accessory mode immediately
        NSApp.setActivationPolicy(.accessory)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        SettingsSearch.shared.query = ""  // the window is only hidden: it opens without the old search
        relinquishFocus()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure app is in regular mode when window becomes key
        NSApp.setActivationPolicy(.regular)
    }

    func windowDidResignKey(_ notification: Notification) {
    }
}
