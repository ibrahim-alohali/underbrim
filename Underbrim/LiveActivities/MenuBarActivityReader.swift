//
//  MenuBarActivityReader.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Reads the Live Activities macOS 27's MenuBarAgent draws in the menu bar, including those in the
//  overflow behind the notch. Only MenuBarAgent's and the Live Activity renderer's items are read;
//  other apps' items are skipped unread, and what is read stays in memory.
//  Wakes on liveactivitiesd's Darwin notifications and AX changes; while an activity exists, a look
//  every 15 s catches unannounced changes. Method adapted from Islet (MIT, © 2026 The Islet
//  contributors); see THIRD_PARTY_LICENSES.
//

import AppKit
import ApplicationServices
import notify

@MainActor
final class MenuBarActivityReader {
    nonisolated static let agentBundleID = "com.apple.MenuBarAgent"
    /// The processes that draw activity content for MenuBarAgent.
    nonisolated static let rendererBundleIDs: Set<String> = ["com.apple.chrono.WidgetRenderer-Activities", "com.apple.ScreenContinuity"]
    static let triggers = ["com.apple.liveactivitiesd.replicatorParticipant.record",
                           "com.apple.chronod.replicator.record", "com.apple.activitykit.daemonstartup"]

    /// Whether macOS is set to show the iPhone's Live Activities (Control Center's setting); nil when unknown.
    static var iPhoneActivitiesEnabled: Bool? {
        CFPreferencesCopyAppValue("RemoteLiveActivitiesEnabled" as CFString, "com.apple.controlcenter" as CFString) as? Bool
    }

    private let publish: ([PhoneActivity]) -> Void
    private var observer: AXObserver?
    private var agent: pid_t = 0
    private var watched: [String: AXUIElement] = [:]
    private var slots: [String: Slot] = [:]
    private var overflow: AXUIElement?
    private var last: [PhoneActivity] = []
    private var tokens: [Int32] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var safetyTimer: Timer?
    private var scanWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "\(bundleIdentifier).menubar-activities", qos: .utility)

    init(publish: @escaping ([PhoneActivity]) -> Void) {
        self.publish = publish
    }

    func start() {
        guard observer == nil else { return }
        attach()
        for name in Self.triggers {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Drawn out of process, so look again a moment later too.
                    self?.scheduleScan(after: 1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.scheduleScan(after: 0) }
                }
            }
            if status == UInt32(NOTIFY_STATUS_OK) { tokens.append(token) }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.agentBundleID else { return }
            MainActor.assumeIsolated {
                self?.attach()
                self?.scheduleScan(after: 1)
            }
        })
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleScan(after: 0.5) }
            })
        }
        scheduleScan(after: 0)
    }

    func stop() {
        detach()
        tokens.forEach { notify_cancel($0) }
        tokens = []
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        scanWork?.cancel()
        safetyTimer?.invalidate()
        safetyTimer = nil
    }

    /// Opens Apple's expanded view, or the app in iPhone Mirroring; one in the overflow is revealed first.
    /// A press macOS refuses (the item gone) beeps instead of doing nothing.
    func press(id: String) {
        guard let slot = slots[id] else { return NSSound.beep() }
        if slot.item.hidden, let overflow {
            guard Self.press(overflow) else { return NSSound.beep() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !Self.press(slot.element) { NSSound.beep() }
            }
            return
        }
        if !Self.press(slot.element) { NSSound.beep() }
    }

    /// "Cannot complete" is MenuBarAgent too busy showing what was pressed to answer.
    private static func press(_ element: AXUIElement) -> Bool {
        // On the main thread: a busy MenuBarAgent mustn't hold the notch for AX's default ~6 s.
        AXUIElementSetMessagingTimeout(element, 0.5)
        return [.success, .cannotComplete].contains(AXUIElementPerformAction(element, kAXPressAction as CFString))
    }

    // MARK: Observing

    private func attach() {
        detach()
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first?.processIdentifier else { return }
        agent = pid
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, name, refcon in
            guard let refcon else { return }
            let reader = Unmanaged<MenuBarActivityReader>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { reader.received(name as String, element: element) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        // Structure only: value changes arrive every second from the clock, so they're watched per activity.
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func detach() {
        if let observer {
            for element in watched.values { unwatch(element, observer) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        watched = [:]
        observer = nil
    }

    private static let elementNotifications = [kAXValueChangedNotification, kAXTitleChangedNotification,
                                                kAXUIElementDestroyedNotification, kAXResizedNotification, "AXDescriptionChanged"]

    private func watch(_ element: AXUIElement, _ observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.elementNotifications { AXObserverAddNotification(observer, element, name as CFString, refcon) }
    }

    private func unwatch(_ element: AXUIElement, _ observer: AXObserver) {
        for name in Self.elementNotifications { AXObserverRemoveNotification(observer, element, name as CFString) }
    }

    private func received(_ name: String, element: AXUIElement) {
        if [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification].contains(name) {
            // MenuBarAgent also hosts other apps' items; theirs don't matter.
            guard element.pid == agent || Self.isRenderer(element.pid) else { return }
        }
        scheduleScan(after: 0.3)
    }

    private func scheduleScan(after delay: TimeInterval) {
        scanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        scanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        guard observer != nil, agent != 0 else { return }
        let agent = agent
        queue.async {
            let found = Self.slots(agent: agent)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.apply(found) }
            }
        }
    }

    private func apply(_ scan: Scan) {
        guard let observer else { return }
        // Nothing at all means the menu bar couldn't be read yet (no window for this Space), not that all ended.
        guard !scan.slots.isEmpty || scan.read else { return }
        overflow = scan.overflow
        let labels = MenuBarLabels.system
        var found: [PhoneActivity] = []
        var kept: [String: Slot] = [:]
        for slot in scan.slots {
            guard let activity = PhoneActivityText.activity(from: slot.item, id: slot.id, labels: labels) else { continue }
            found.append(activity)
            kept[slot.id] = slot
        }
        slots = kept
        for (id, element) in watched where kept[id].map({ !CFEqual($0.element, element) }) ?? true {
            unwatch(element, observer)
            watched[id] = nil
        }
        for (id, slot) in kept where watched[id] == nil {
            watch(slot.element, observer)
            watched[id] = slot.element
        }
        if found.isEmpty {
            safetyTimer?.invalidate()
            safetyTimer = nil
        } else if safetyTimer == nil {
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scan() }
            }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            safetyTimer = timer
        }
        guard found != last else { return }
        last = found
        publish(found)
    }

    // MARK: Reading the menu bar

    struct Slot: @unchecked Sendable {
        let id: String
        let element: AXUIElement
        var item: MenuBarItem
        let frame: CGRect
    }

    struct Scan: @unchecked Sendable {
        var slots: [Slot] = []
        var overflow: AXUIElement?
        /// The menu bar window was found (an empty list is then real).
        var read = false
    }

    nonisolated static func slots(agent: pid_t) -> Scan {
        let app = AXUIElementCreateApplication(agent)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let windows = app.elements(kAXWindowsAttribute)
        guard let window = windows.first(where: { $0.frame.height > 0 && $0.frame.height <= 40 && $0.frame.origin == .zero })
        else { return Scan() }
        var scan = Scan(read: true)
        var chevron: CGRect?
        for slot in window.childElements {
            let slotFrame = slot.frame
            guard slotFrame.width > 0 else { continue }
            let role = slot.string(kAXRoleAttribute)
            if role == kAXButtonRole as String {
                scan.overflow = slot
                chevron = slotFrame.insetBy(dx: -2, dy: 0)
                continue
            }
            // An activity is the slot itself; MenuBarAgent's other items are a container with it inside.
            guard let content = role == "AXMenuBarItem" ? slot : slot.childElements.first else { continue }
            let renderer = content.pid != agent
            if renderer, !isRenderer(content.pid) { continue }
            let target = ([content] + content.childElements).first { $0.string(kAXRoleAttribute) == "AXMenuBarItem" } ?? content
            var item = MenuBarItem(identifier: target.string(kAXIdentifierAttribute), role: target.string(kAXRoleAttribute),
                                   subrole: target.string(kAXSubroleAttribute), description: target.string(kAXDescriptionAttribute),
                                   drawnByRenderer: renderer)
            // System items are known from their identifier alone; read more only when it could matter.
            if !(item.identifier ?? "").hasPrefix("com.apple.menuextra.") {
                item.title = target.string(kAXTitleAttribute)
                item.value = value(target)
                item.help = target.string(kAXHelpAttribute)
                item.actions = actions(target)
                var budget = 40
                collectTexts(target, agent: agent, depth: 0, budget: &budget, into: &item.texts)
            }
            // Keyed on the slot: every pill carries the same identifier, and its text changes as it runs.
            scan.slots.append(Slot(id: "el:" + String(CFHash(slot), radix: 36), element: target, item: item, frame: slotFrame))
        }
        if let chevron {
            for index in scan.slots.indices where scan.slots[index].frame.intersects(chevron) { scan.slots[index].item.hidden = true }
        }
        scan.slots.sort { $0.frame.minX < $1.frame.minX }
        return scan
    }

    private nonisolated static func isRenderer(_ pid: pid_t) -> Bool {
        rendererBundleIDs.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "")
    }

    private nonisolated static func collectTexts(_ element: AXUIElement, agent: pid_t, depth: Int, budget: inout Int, into out: inout [String]) {
        guard depth < 6, budget > 0 else { return }
        for child in element.childElements {
            budget -= 1
            guard budget > 0 else { return }
            guard child.pid == agent || isRenderer(child.pid) else { continue }
            if let text = text(child) { out.append(text) }
            collectTexts(child, agent: agent, depth: depth + 1, budget: &budget, into: &out)
        }
    }

    /// Menu command names ("End Live Activity"); read, never performed.
    private nonisolated static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return list.compactMap { raw in raw.hasPrefix("Name:") ? raw.dropFirst(5).split(separator: "\n").first.map(String.init) : nil }
    }

    /// What an element says: its value, description, attributed description (SwiftUI labels) or title.
    private nonisolated static func text(_ element: AXUIElement) -> String? {
        let attributed = element["AXAttributedDescription"]
        return [value(element), element.string(kAXDescriptionAttribute),
                (attributed as? NSAttributedString)?.string ?? attributed as? String, element.string(kAXTitleAttribute)]
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    private nonisolated static func value(_ element: AXUIElement) -> String? {
        let value = element[kAXValueAttribute]
        return value as? String ?? (value as? NSNumber)?.stringValue
    }
}
