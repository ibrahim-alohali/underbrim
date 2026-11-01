//
//  ClaudeAppAnswer.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import OSLog

/// The Claude app offers no way for another app to answer its questions, so their buttons are
/// pressed in its window through Accessibility, only in the asking session's own chat (its page's
/// address ends in the session's id) and only where the words and buttons match the ones asked.
/// Claude stays where it is: a chat it isn't showing is switched to and back in its sidebar while
/// another app is in front, and otherwise left to the user. Never a click with the pointer.
enum ClaudeAppAnswer {
    enum Question: Equatable, Sendable {
        case nextStep(AgentNextStep)
        case offer(AgentOffer)

        /// The buttons as the island names them, in its order.
        var choices: [String] {
            switch self {
            case .nextStep(let step): step.choices.map(\.title)
            case .offer: [String(localized: "New Session"), String(localized: "Do It Here")]
            }
        }
    }

    enum Result { case pressed, alreadyAnswered, notShown, notTaken, notAllowed, notRunning }

    private static let log = Logger(subsystem: bundleIdentifier, category: "agents")

    /// macOS's own prompt to allow Underbrim in Accessibility, else that list in System Settings.
    @MainActor static func askForAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { SystemSettings.open(.accessibility) }
    }

    /// `retrying` runs before a second press, when Claude let the first one go by.
    @MainActor static func press(_ question: Question, choice index: Int, session: AgentSession,
                                 retrying: () -> Void = {}) async -> Result {
        guard AXIsProcessTrusted() else { return .notAllowed }
        let bundleID = AgentProvider.claude.defaultHostBundleID
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return .notRunning }
        guard let chat = session.desktopSessionID else { return .notShown }
        let pid = app.processIdentifier
        let target = Target(question: question, index: index, chat: chat, title: session.title)
        var shown = await locate(pid: pid, target)
        // The window may build its accessibility only now that it's asked to.
        for _ in 0..<2 where shown == .missing {
            try? await Task.sleep(for: .milliseconds(250))
            shown = await locate(pid: pid, target)
        }
        var away: String?
        if shown == .missing {
            // In front, Claude would be seen changing chats: the user opens it instead.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID else { return .notShown }
            away = await detached { switchTo(pid: pid, chat: chat, title: session.title) }
            guard away != nil else {
                log.notice("Claude app question: its chat couldn't be shown")
                return .notShown
            }
            for _ in 0..<12 where shown == .missing {
                try? await Task.sleep(for: .milliseconds(250))
                shown = await locate(pid: pid, target)
            }
        }
        let result: Result
        switch shown {
        case .answered:
            result = .alreadyAnswered
        case .missing:
            log.notice("Claude app question: its buttons weren't found")
            result = .notShown
        case .buttons(let button):
            var pressed = AXUIElementPerformAction(button.element, kAXPressAction as CFString)
            var taken = await answered(pid: pid, target, session: session)
            // Claude now and then lets a press go by: once more while its buttons are still there.
            if !taken, case .buttons(let again) = await locate(pid: pid, target) {
                log.notice("Claude app question: the first press (\(pressed.rawValue, privacy: .public)) didn't take, pressing again")
                retrying()
                pressed = AXUIElementPerformAction(again.element, kAXPressAction as CFString)
                taken = await answered(pid: pid, target, session: session)
            }
            if taken {
                log.notice("Claude app question: answered through Accessibility")
                result = .pressed
            } else {
                log.notice("Claude app question: the press (\(pressed.rawValue, privacy: .public)) didn't take")
                result = .notTaken
            }
        }
        if let away {
            let back = await detached { switchBack(pid: pid, to: away) }
            if !back { log.notice("Claude app question: its window didn't go back to the chat it showed") }
        }
        return result
    }

    private static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// Claude took the answer within about two seconds: the question shows without its buttons,
    /// or its session's files moved on. A question that can't be read isn't taken as answered.
    @MainActor private static func answered(pid: pid_t, _ target: Target, session: AgentSession) async -> Bool {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            if let current = AgentSessionStore.shared.sessions.first(where: { $0.id == session.id }) {
                switch target.question {
                case .nextStep(let step): if current.details.nextStep != step { return true }
                case .offer(let offer): if current.details.offer != offer { return true }
                }
            }
            if await locate(pid: pid, target) == .answered { return true }
        }
        return false
    }

    /// What is looked for: the question, the button wanted, and the chat it's in (the Claude app's
    /// own session id, and its title for chats side by side).
    private struct Target: Sendable {
        let question: Question
        let index: Int
        let chat: String
        let title: String?
    }

    private struct Found: @unchecked Sendable, Equatable {
        let element: AXUIElement
        static func == (a: Found, b: Found) -> Bool { CFEqual(a.element, b.element) }
    }

    /// The question as the session's chat shows it: its buttons, answered (its words without them), or
    /// not there (another chat on screen, other buttons, or unreadable just now).
    private enum Shown: Sendable, Equatable {
        case buttons(Found)
        case answered
        case missing
    }

    private static func locate(pid: pid_t, _ target: Target) async -> Shown {
        await detached { () -> Shown in
            let root = application(pid)
            var budget = 8000
            for chat in chats(in: root, id: target.chat, title: target.title, budget: &budget) {
                let shown = switch target.question {
                case .nextStep(let step): findNextStep(step, index: target.index, in: chat, budget: &budget)
                case .offer(let offer): findOffer(offer, index: target.index, in: chat, budget: &budget)
                }
                if shown != .missing { return shown }
            }
            return .missing
        }
    }

    nonisolated static func application(_ pid: pid_t) -> AXUIElement {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 1)
        // An Electron app builds its accessibility tree for clients that ask for it.
        root.set("AXManualAccessibility", true)
        return root
    }

    // MARK: The session's chat

    /// The pages of Claude's windows that show sessions: their address ends in the one in front's id.
    nonisolated private static func pages(in root: AXUIElement, budget: inout Int) -> [AXUIElement] {
        var found: [AXUIElement] = []
        for window in root.elements(kAXWindowsAttribute) {
            collect(in: window, depth: 0, maxDepth: 14, budget: &budget, into: &found) { element in
                element.string(kAXRoleAttribute) == "AXWebArea" && chatID(of: element) != nil
            }
        }
        return found
    }

    /// "https://claude.ai/epitaxy/local_…" → "local_…".
    nonisolated private static func chatID(of page: AXUIElement) -> String? {
        guard let url = page["AXURL"] as? URL, url.pathComponents.contains("epitaxy") else { return nil }
        let id = url.lastPathComponent
        return id.hasPrefix("local_") ? id : nil
    }

    /// The page of Claude's window that shows sessions, also while it shows none (its start page).
    nonisolated private static func sessionsPage(in root: AXUIElement, budget: inout Int) -> AXUIElement? {
        var found: [AXUIElement] = []
        for window in root.elements(kAXWindowsAttribute) where found.isEmpty {
            collect(in: window, depth: 0, maxDepth: 14, budget: &budget, into: &found, stopAtMatch: true) { element in
                element.string(kAXRoleAttribute) == "AXWebArea" && (element["AXURL"] as? URL)?.pathComponents.contains("epitaxy") == true
            }
        }
        return found.first
    }

    /// The chat the page shows, or "" on its start page.
    nonisolated private static func showing(_ page: AXUIElement) -> String { chatID(of: page) ?? "" }

    /// Where the session's chat is on screen: its page's one chat when that page is the session's, or with
    /// chats side by side, the one titled as the session (when no other is).
    nonisolated static func chats(in root: AXUIElement, id: String, title: String?, budget: inout Int) -> [AXUIElement] {
        var chats: [AXUIElement] = []
        for page in pages(in: root, budget: &budget) {
            var panels: [AXUIElement] = []
            collect(in: page, depth: 0, maxDepth: 40, budget: &budget, into: &panels, stopAtMatch: true) { element in
                (element["AXDOMClassList"] as? [String])?.contains("epitaxy-chat-panel") == true
            }
            if panels.count == 1, chatID(of: page) == id {
                chats.append(panels[0])
            } else if panels.count > 1, let title {
                let titled = panels.filter { panelTitle($0, budget: &budget) == title }
                if titled.count == 1 { chats += titled }
            }
        }
        return chats
    }

    /// The title in a chat's own title bar.
    nonisolated private static func panelTitle(_ panel: AXUIElement, budget: inout Int) -> String? {
        var headings: [AXUIElement] = []
        collect(in: panel, depth: 0, maxDepth: 8, budget: &budget, into: &headings, stopAtMatch: true) { element in
            element.string(kAXRoleAttribute) == kAXHeadingRole && element.string(kAXDescriptionAttribute)?.isEmpty == false
        }
        return headings.first?.string(kAXDescriptionAttribute)
    }

    /// The question under a finished turn: its text, the newest one in the chat, and its own buttons in
    /// the group after the line holding it (gone once it's answered).
    nonisolated private static func findNextStep(_ step: AgentNextStep, index: Int, in chat: AXUIElement, budget: inout Int) -> Shown {
        let wanted = normalized(step.ask)
        guard let text = findLast(in: chat, depth: 0, budget: &budget, where: { element in
            element.string(kAXRoleAttribute) == kAXStaticTextRole && matches(normalized(element.string(kAXValueAttribute) ?? ""), wanted)
        }), let line = text.parent, let box = line.parent else { return .missing }
        let siblings = box.childElements
        guard let at = siblings.firstIndex(where: { CFEqual($0, line) }) else { return .missing }
        let buttons = siblings[(at + 1)...].lazy.map { group in
            group.childElements.filter { $0.string(kAXRoleAttribute) == kAXButtonRole }
        }.first { !$0.isEmpty }
        guard let buttons else { return .answered }
        guard buttons.count == step.choices.count else { return .missing }
        for (button, choice) in zip(buttons, step.choices) {
            guard let label = choice.label else { continue }
            guard normalized(title(of: button)) == normalized(label) else { return .missing }
        }
        return .buttons(Found(element: buttons[index]))
    }

    /// The offer card: a group holding the offer's title and its two buttons, Do it here then New session
    /// (the island's order is New Session, Do It Here).
    nonisolated private static func findOffer(_ offer: AgentOffer, index: Int, in chat: AXUIElement, budget: inout Int) -> Shown {
        let wanted = normalized(offer.title)
        guard let text = findLast(in: chat, depth: 0, budget: &budget, where: { element in
            element.string(kAXRoleAttribute) == kAXStaticTextRole && matches(normalized(element.string(kAXValueAttribute) ?? ""), wanted)
                && element.parent?.string(kAXSubroleAttribute) == "AXApplicationGroup"
        }), let card = text.parent else { return .missing }
        let buttons = card.childElements.filter { $0.string(kAXRoleAttribute) == kAXButtonRole }
        guard !buttons.isEmpty else { return .answered }
        let english = ["New session", "Do it here"]
        if let named = buttons.first(where: { title(of: $0) == english[index] }) { return .buttons(Found(element: named)) }
        // Claude in another language: its two buttons in their order.
        guard buttons.count == 2, !buttons.contains(where: { english.contains(title(of: $0)) }) else { return .missing }
        return .buttons(Found(element: buttons[1 - index]))
    }

    /// An Electron app's elements can have an empty title beside the description.
    nonisolated private static func title(of element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute].lazy.compactMap { element.string($0) }.first { !$0.isEmpty } ?? ""
    }

    // MARK: Switching chats unseen

    /// Shows the chat `id` in Claude's window by pressing its line in the sidebar, which doesn't bring
    /// Claude forward; the chat it showed before ("" for its start page), or nil if it couldn't.
    nonisolated static func switchTo(pid: pid_t, chat id: String, title: String?) -> String? {
        let root = application(pid)
        var budget = 8000
        guard let page = sessionsPage(in: root, budget: &budget) else { return nil }
        let before = showing(page)
        if before == id { return nil }
        for row in rows(in: page, chat: id, title: title, budget: &budget).prefix(3) {
            AXUIElementPerformAction(row, kAXPressAction as CFString)
            if waitFor(page, chat: id) { return before }
            // Another chat with that title: back to where it was, then the next.
            if showing(page) != before { _ = switchBack(pid: pid, to: before) }
        }
        return nil
    }

    /// Back to the chat `id` it showed ("" for its start page): the sidebar's Back, else that chat's own line.
    nonisolated static func switchBack(pid: pid_t, to id: String) -> Bool {
        let root = application(pid)
        var budget = 8000
        guard let page = sessionsPage(in: root, budget: &budget) else { return false }
        if showing(page) == id { return true }
        if let back = page.first(where: { $0.string(kAXRoleAttribute) == kAXButtonRole && $0.string(kAXDescriptionAttribute) == "Back" }) {
            AXUIElementPerformAction(back, kAXPressAction as CFString)
            if waitFor(page, chat: id) { return true }
        }
        guard !id.isEmpty else { return false }
        for row in rows(in: page, chat: id, title: nil, budget: &budget).prefix(1) {
            AXUIElementPerformAction(row, kAXPressAction as CFString)
            if waitFor(page, chat: id) { return true }
        }
        return false
    }

    nonisolated private static func waitFor(_ page: AXUIElement, chat id: String) -> Bool {
        for _ in 0..<30 {
            if showing(page) == id { return true }
            usleep(100_000)
        }
        return false
    }

    /// The sidebar's lines that may open the chat `id`: one holding that id, then those titled as it.
    nonisolated private static func rows(in page: AXUIElement, chat id: String, title name: String?, budget: inout Int) -> [AXUIElement] {
        var rows: [AXUIElement] = []
        collect(in: page, depth: 0, maxDepth: 40, budget: &budget, into: &rows, stopAtMatch: true) { element in
            element.string(kAXRoleAttribute) == kAXButtonRole
                && (element["AXDOMClassList"] as? [String])?.contains("text-start") == true
                && element.parent.map { ($0["AXDOMClassList"] as? [String])?.contains("hit-row") == true } == true
        }
        let holding = rows.filter { row in
            row.first { $0.string("AXDOMIdentifier")?.hasSuffix(id) == true } != nil
        }
        guard let name else { return holding }
        let named = rows.filter { title(of: $0) == name } + rows.filter { title(of: $0).hasPrefix(name + " ") }
        return holding + named.filter { row in !holding.contains { CFEqual($0, row) } }
    }

    // MARK: Walking the tree

    nonisolated static func collect(in element: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int,
                                            into found: inout [AXUIElement], stopAtMatch: Bool = false,
                                            where test: (AXUIElement) -> Bool) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1
        if test(element) {
            found.append(element)
            if stopAtMatch { return }
        }
        for child in element.childElements {
            collect(in: child, depth: depth + 1, maxDepth: maxDepth, budget: &budget, into: &found, stopAtMatch: stopAtMatch, where: test)
        }
    }

    nonisolated private static func findLast(in element: AXUIElement, depth: Int, budget: inout Int,
                                             where test: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 90, budget > 0 else { return nil }
        budget -= 1
        for child in element.childElements.reversed() {
            if let hit = findLast(in: child, depth: depth + 1, budget: &budget, where: test) { return hit }
        }
        return test(element) ? element : nil
    }

    /// Whitespace runs as one space; a question cut short here ("…") matches the start of the full one.
    nonisolated static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated static func matches(_ shown: String, _ asked: String) -> Bool {
        guard !asked.isEmpty else { return false }
        if shown == asked { return true }
        return asked.hasSuffix("…") && asked.count > 40 && shown.hasPrefix(String(asked.dropLast()))
    }
}
