//
//  ClaudeQuestionBox.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import OSLog

/// Claude's own box for its questions with options, answered through Accessibility when no hook asks:
/// only in the asking session's chat, a question at a time, each checked against the one asked (its
/// words, its options in order) before anything in it is pressed. Options are pressed only toward the
/// state wanted and every press is read back (pressed again only when it changed nothing); Other's words
/// are read back too. Claude's own button names aren't relied on, as it may show another language: the
/// box's parts are told apart by their places in it.
enum ClaudeQuestionBox {
    enum Result: Sendable {
        case sent, alreadyAnswered, notShown, notRunning, notAllowed, notTaken
        /// Claude's box asks something other than what the island shows.
        case different
    }

    private static let log = Logger(subsystem: bundleIdentifier, category: "agents")

    /// Fills in the box with `choices` (by their places in the agent's own list; a question without one is
    /// skipped) and sends it. A chat not on screen is shown for the moment it takes, Claude in front or
    /// not, then the one that was.
    @MainActor static func send(_ asked: AgentQuestion, choices: [RelayChoice], session: AgentSession) async -> Result {
        guard AXIsProcessTrusted() else { return .notAllowed }
        let bundleID = AgentProvider.claude.defaultHostBundleID
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return .notRunning }
        guard let chat = session.desktopSessionID else { return .notShown }
        let pid = app.processIdentifier
        let target = Target(questions: asked.questions.all, choices: choices, chat: chat, title: session.title)
        var seen = await look(pid: pid, target)
        // The window may build its accessibility only now that it's asked to.
        for _ in 0..<2 where seen == .missing {
            try? await Task.sleep(for: .milliseconds(250))
            seen = await look(pid: pid, target)
        }
        var away: String?
        if seen == .missing {
            away = await detached { ClaudeAppAnswer.switchTo(pid: pid, chat: chat, title: session.title) }
            guard away != nil else {
                log.notice("Claude app questions: their chat couldn't be shown")
                return .notShown
            }
            for _ in 0..<12 where seen == .missing {
                try? await Task.sleep(for: .milliseconds(250))
                seen = await look(pid: pid, target)
            }
        }
        let result: Result
        switch seen {
        case .missing:
            result = .notShown
        case .other:
            result = .different
        case .noBox:
            result = waiting(asked, session) ? .notShown : .alreadyAnswered
        case .box:
            switch await detached({ fill(pid: pid, target) }) {
            case .sent: result = await taken(asked, session: session, pid: pid, target) ? .sent : .notTaken
            case .different: result = .different
            case .stuck: result = .notTaken
            case .missing: result = .notShown
            }
        }
        if let away, await !detached({ ClaudeAppAnswer.switchBack(pid: pid, to: away) }) {
            log.notice("Claude app questions: its window didn't go back to the chat it showed")
        }
        log.notice("Claude app questions: \(String(describing: result), privacy: .public)")
        return result
    }

    private static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// The session's record still waits on these questions: the same call, however often it was read.
    @MainActor private static func waiting(_ asked: AgentQuestion, _ session: AgentSession) -> Bool {
        guard let now = AgentSessionStore.shared.sessions.first(where: { $0.id == session.id })?.details.question else { return false }
        return asked.id.map { $0 == now.id } ?? (now == asked)
    }

    /// Claude took the answers within about three seconds: its record has them, or the box went. Nothing
    /// is pressed again: a second press could answer what Claude asks next.
    @MainActor private static func taken(_ asked: AgentQuestion, session: AgentSession, pid: pid_t, _ target: Target) async -> Bool {
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(200))
            if !waiting(asked, session) { return true }
            if await look(pid: pid, target) == .noBox { return true }
        }
        return false
    }

    /// The questions, the answers to give, and the chat they're in (the Claude app's own session id, and
    /// its title for chats side by side).
    private struct Target: Sendable {
        let questions: [RelayQuestion]
        let choices: [RelayChoice]
        let chat: String
        let title: String?
    }

    /// The session's chat on screen with the box for these questions, with another box, with none, or not
    /// on screen (or not readable just now).
    private enum Seen: Sendable { case box, other, noBox, missing }

    private static func look(pid: pid_t, _ target: Target) async -> Seen {
        await detached {
            var budget = 8000
            let root = ClaudeAppAnswer.application(pid)
            guard let chat = ClaudeAppAnswer.chats(in: root, id: target.chat, title: target.title, budget: &budget).first
            else { return .missing }
            guard let card = card(in: chat, budget: &budget), let box = read(card) else { return .noBox }
            return target.questions.contains { box.shows($0) } ? .box : .other
        }
    }

    // MARK: Filling it in

    private enum Fill { case sent, different, stuck, missing }

    /// From the first question to the last: each checked, set as chosen and gone on from (or skipped), the
    /// last sent. Stops before pressing anything in a question that isn't the one asked.
    nonisolated private static func fill(pid: pid_t, _ target: Target) -> Fill {
        var budget = 8000
        let root = ClaudeAppAnswer.application(pid)
        guard let chat = ClaudeAppAnswer.chats(in: root, id: target.chat, title: target.title, budget: &budget).first,
              let card = card(in: chat, budget: &budget), var box = read(card) else { return .missing }
        let questions = target.questions
        // Every question the box asks is one here, in its order.
        guard questions.indices.elementsEqual(questions.map(\.sourceIndex)),
              questions.count == 1 ? (box.counter.max() ?? 1) == 1 : box.counter.max() == questions.count && box.arrows.count == 2
        else { return .different }
        // Back to the first: the box shows the question left showing in Claude.
        guard let showing = questions.firstIndex(where: { box.shows($0) }) else { return .different }
        for _ in 0..<showing {
            guard box.arrows.first.map(isEnabled) == true,
                  let moved = pressed({ $0.arrows.first }, in: card, from: box, until: anotherQuestion(than: box)) else { return .stuck }
            box = moved
        }
        for (place, question) in questions.enumerated() {
            guard box.shows(question) else { return .different }
            var button: (Box) -> AXUIElement? = { $0.skip }
            if let choice = target.choices.first(where: { $0.question == place }) {
                guard let set = set(choice, question, in: card, box), let goOn = set.goOn, isEnabled(goOn) else { return .stuck }
                box = set
                button = { $0.goOn }
            }
            if place == questions.count - 1 {
                // Sent once the box goes, or no longer asks this.
                let last = box
                let gone = press(button, in: card, from: box) { now in now.map { $0.goOn == nil || anotherQuestion(than: last)($0) } ?? true }
                return gone ? .sent : .stuck
            }
            guard let moved = pressed(button, in: card, from: box, until: anotherQuestion(than: box)) else { return .stuck }
            box = moved
        }
        return .stuck
    }

    /// One question's options and Other's words as chosen, pressing only what differs, each read back before
    /// the next, then all of it: the box as set, or nil when it didn't take.
    nonisolated private static func set(_ choice: RelayChoice, _ question: RelayQuestion, in card: AXUIElement, _ box: Box) -> Box? {
        var box = box
        let wanted = box.options.indices.map { choice.options.contains($0) }
        let words = choice.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let typing = !words.isEmpty
        let typed: (Box) -> Bool = { ClaudeAppAnswer.normalized($0.fieldText ?? "") == ClaudeAppAnswer.normalized(words) }
        // Other first: in a question with one answer, turning it on clears the options.
        if typing, box.other?.on == false {
            guard let on = pressed({ $0.other?.element }, in: card, from: box, until: { $0.other?.on == true && $0.field != nil })
            else { return nil }
            box = on
        }
        // With one answer, the one wanted; the others go off by themselves.
        for place in box.options.indices where box.options[place].on != wanted[place] && (question.multiSelect || wanted[place]) {
            guard let changed = pressed({ $0.options.indices.contains(place) ? $0.options[place].element : nil }, in: card, from: box,
                                        until: { $0.options.indices.contains(place) && $0.options[place].on == wanted[place] })
            else { return nil }
            box = changed
        }
        if !typing, box.other?.on == true {
            guard let off = pressed({ $0.other?.element }, in: card, from: box, until: { $0.other?.on != true }) else { return nil }
            box = off
        }
        for _ in 0..<2 where typing && !typed(box) {
            guard let field = box.field else { return nil }
            AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, words as CFString)
            if let set = settled(card, until: typed) { box = set }
        }
        // All of it, read once more.
        return settled(card, for: 3) { $0.options.map(\.on) == wanted && ($0.other?.on == true) == typing && (!typing || typed($0)) }
    }

    /// Presses what `pick` finds in the box, then reads the box until `done` (nil once it's gone): whether it
    /// was. Claude now and then lets a press go by with no sign of it, most often the first one in a box it
    /// has just shown, so a press that changes nothing within a second is made once more.
    nonisolated private static func press(_ pick: (Box) -> AXUIElement?, in card: AXUIElement, from box: Box,
                                          until done: (Box?) -> Bool) -> Bool {
        var current = box
        for tries in [10, 20] {
            guard let element = pick(current) else { return false }
            press(element)
            for _ in 0..<tries {
                usleep(100_000)
                let now = read(card)
                if done(now) { return true }
                if let now { current = now }
            }
            log.notice("Claude app questions: a press changed nothing")
        }
        return false
    }

    /// The same, for a press that leaves the box showing: the box once `done`.
    nonisolated private static func pressed(_ pick: (Box) -> AXUIElement?, in card: AXUIElement, from box: Box,
                                            until done: (Box) -> Bool) -> Box? {
        var after: Box?
        let taken = press(pick, in: card, from: box) { now in
            guard let now, done(now) else { return false }
            after = now
            return true
        }
        return taken ? after : nil
    }

    /// Another question showing than in `box`.
    nonisolated private static func anotherQuestion(than box: Box) -> (Box) -> Bool {
        { $0.text != box.text || $0.counter != box.counter }
    }

    /// The box once `done`, read every tenth of a second for up to `tries` times.
    nonisolated private static func settled(_ card: AXUIElement, for tries: Int = 15, until done: (Box) -> Bool) -> Box? {
        for _ in 0..<tries {
            usleep(100_000)
            if let box = read(card), done(box) { return box }
        }
        return nil
    }

    nonisolated private static func press(_ element: AXUIElement) {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result != .success { log.notice("Claude app questions: a press failed (\(result.rawValue, privacy: .public))") }
    }

    nonisolated private static func isEnabled(_ element: AXUIElement) -> Bool {
        element[kAXEnabledAttribute] as? Bool ?? true
    }

    // MARK: Reading it

    /// The box as it shows now.
    private struct Box {
        /// The question showing.
        let text: String
        /// The numbers in its "2 of 3"; none when it asks one question.
        let counter: [Int]
        /// Its arrows between questions: back, then forward.
        let arrows: [AXUIElement]
        let options: [Option]
        /// Other's own toggle, and its text area while it's on.
        let other: Option?
        let field: AXUIElement?
        /// Skip, then Next or Submit.
        let buttons: [AXUIElement]

        var skip: AXUIElement? { buttons.count >= 2 ? buttons.first : nil }
        var goOn: AXUIElement? { buttons.count >= 2 ? buttons.last : nil }
        var fieldText: String? { field?.string(kAXValueAttribute) }

        /// Shows `question`: its words, and every one of its options in their order.
        func shows(_ question: RelayQuestion) -> Bool {
            guard ClaudeQuestionBox.same(text, question.question), options.count == question.options.count else { return false }
            return question.options.enumerated().allSatisfy { place, option in
                option.sourceIndex == place && options[place].reads(option.label)
            }
        }
    }

    private struct Option {
        let element: AXUIElement
        /// Its label's words, and its whole title (the label, then the description).
        let label: String
        let title: String
        let on: Bool

        /// Its label reads as `asked`: drawn in parts (code, emphasis), the title starts with it.
        func reads(_ asked: String) -> Bool {
            if ClaudeQuestionBox.same(label, asked) { return true }
            let title = ClaudeQuestionBox.plain(title), asked = ClaudeQuestionBox.plain(asked)
            return !asked.isEmpty && (title == asked || title.hasPrefix(asked + " "))
        }
    }

    /// The box in the chat: a card with answers to pick (a tool's approval card has none).
    nonisolated private static func card(in chat: AXUIElement, budget: inout Int) -> AXUIElement? {
        var cards: [AXUIElement] = []
        ClaudeAppAnswer.collect(in: chat, depth: 0, maxDepth: 40, budget: &budget, into: &cards, stopAtMatch: true) { element in
            element.string(kAXSubroleAttribute) == "AXApplicationGroup" && classes(element).contains("epitaxy-approval-card")
        }
        return cards.last { card in read(card).map { !$0.options.isEmpty } ?? false }
    }

    nonisolated private static func read(_ card: AXUIElement) -> Box? {
        let children = card.childElements
        guard !children.isEmpty else { return nil }
        var text = card.string(kAXDescriptionAttribute) ?? ""
        if text.isEmpty, let first = children.first { text = texts(in: first).joined(separator: " ") }
        let counter = children.lazy.filter { $0.string(kAXRoleAttribute) == kAXStaticTextRole }
            .map { numbers(in: $0.string(kAXValueAttribute) ?? "") }.first { $0.count == 2 } ?? []
        var answers: [AXUIElement] = []
        var budget = 400
        ClaudeAppAnswer.collect(in: card, depth: 0, maxDepth: 6, budget: &budget, into: &answers, stopAtMatch: true) { element in
            classes(element).contains("epitaxy-answer-option")
        }
        var options: [Option] = [], other: Option?, field: AXUIElement?
        for answer in answers {
            if answer.string(kAXRoleAttribute) == kAXCheckBoxRole {
                // Its label's words: the first of its two lines (the description is the second).
                let lines = answer.childElements.first?.childElements ?? []
                options.append(Option(element: answer, label: lines.first.map { texts(in: $0).joined() } ?? "",
                                      title: answer.string(kAXTitleAttribute) ?? "", on: isOn(answer)))
                continue
            }
            // Other: its toggle, and its text area once on.
            for child in answer.childElements {
                switch child.string(kAXRoleAttribute) {
                case kAXCheckBoxRole: other = Option(element: child, label: "", title: "", on: isOn(child))
                case kAXTextAreaRole, kAXTextFieldRole: field = child
                default: break
                }
            }
        }
        // Skip and Next (or Submit): the buttons in the card's last group holding any.
        let footer = children.last { $0.string(kAXRoleAttribute) == kAXGroupRole && !buttons(in: $0).isEmpty }
        return Box(text: text, counter: counter, arrows: children.filter { $0.string(kAXRoleAttribute) == kAXButtonRole },
                   options: options, other: other, field: field, buttons: footer.map(buttons(in:)) ?? [])
    }

    nonisolated private static func buttons(in group: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var budget = 60
        ClaudeAppAnswer.collect(in: group, depth: 0, maxDepth: 3, budget: &budget, into: &found, stopAtMatch: true) { element in
            element.string(kAXRoleAttribute) == kAXButtonRole
        }
        return found
    }

    /// The words under an element, in order.
    nonisolated private static func texts(in element: AXUIElement) -> [String] {
        var found: [AXUIElement] = []
        var budget = 60
        ClaudeAppAnswer.collect(in: element, depth: 0, maxDepth: 5, budget: &budget, into: &found) { element in
            element.string(kAXRoleAttribute) == kAXStaticTextRole
        }
        return found.compactMap { $0.string(kAXValueAttribute) }.filter { !$0.isEmpty }
    }

    nonisolated private static func classes(_ element: AXUIElement) -> [String] {
        element["AXDOMClassList"] as? [String] ?? []
    }

    nonisolated private static func isOn(_ element: AXUIElement) -> Bool {
        (element[kAXValueAttribute] as? NSNumber)?.boolValue ?? false
    }

    /// "2 of 3" → [2, 3], in whatever digits Claude writes them.
    nonisolated static func numbers(in text: String) -> [Int] {
        var numbers: [Int] = [], current: Int?
        for character in text {
            if let digit = character.wholeNumberValue, character.isNumber {
                current = (current ?? 0) * 10 + digit
            } else if let number = current {
                numbers.append(number)
                current = nil
            }
        }
        if let current { numbers.append(current) }
        return numbers
    }

    /// The same words, as the box draws them: whitespace runs as one space, without markdown's marks,
    /// direction marks or a "(Recommended)" Claude may draw as a badge; a question or label cut short
    /// here matches the start of the whole one.
    nonisolated static func same(_ shown: String, _ asked: String) -> Bool {
        ClaudeAppAnswer.matches(plain(shown), plain(asked))
    }

    nonisolated static func plain(_ text: String) -> String {
        let marks = CharacterSet(charactersIn: "`*_\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        var words = ClaudeAppAnswer.normalized(String(String.UnicodeScalarView(text.unicodeScalars.filter { !marks.contains($0) })))
        let recommended = "(recommended)"
        if words.lowercased().hasSuffix(recommended), words.count > recommended.count {
            words = String(words.dropLast(recommended.count)).trimmingCharacters(in: .whitespaces)
        }
        return words
    }
}
