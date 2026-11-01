//
//  QuestionCard.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Claude's questions with options, whole: the chat that asks, where you are among its
//  questions, each question in full with its options as tiles, and your own words in Other.
//  Nothing is sent before Submit. The hook's requests are answered through the hook
//  (AgentAsks); a question read from a Claude app chat, in Claude's own box (ClaudeQuestionBox);
//  one from a terminal shows here and is answered where it was asked.
//

import SwiftUI

struct QuestionCard: View {
    let ask: AgentAsks.Ask
    let questions: RelayQuestions
    /// The tallest it may be: past this its options scroll.
    let maxHeight: CGFloat
    /// Several requests waiting in the Agents tab: where this one is, and a way to the others.
    var queue: RequestQueue?
    /// Underbrim may use Accessibility (the island follows it), which answering Claude's own box needs.
    var trusted = true
    @State private var model = QuestionCardModel()
    /// The ask this card offers answering Claude Code here from now on for (after Answer here…).
    @State private var offeringFor: String?
    @State private var offerFailure: String?
    @State private var keys = UUID()
    @FocusState private var typingFocused: Bool
    @Environment(\.layoutDirection) private var layoutDirection
    private var asks: AgentAsks { .shared }

    private var all: [RelayQuestion] { questions.all }
    private var index: Int { min(model.index, all.count - 1) }
    private var question: RelayQuestion { all[index] }
    private var isLast: Bool { index == all.count - 1 }
    private var request: AgentRequest? {
        if case .request(let request) = ask { request } else { nil }
    }
    private var session: AgentSession? { ask.session }

    /// The app the question is asked in, where it's answered if not here.
    private var hostBundleID: String {
        request?.hostBundleID ?? session?.hostBundleID ?? ask.provider.defaultHostBundleID
    }
    private var hostName: String { AppInfo.name(bundleID: hostBundleID) ?? ask.provider.appName }

    /// A question read from a chat in the Claude app: answered in Claude's own box, from here.
    private var inClaudeApp: Bool {
        guard case .question(let session, _) = ask else { return false }
        return session.provider == .claude && session.desktopSessionID != nil
    }

    /// Answered from here: through the hook, or in Claude's own box once Accessibility is allowed;
    /// otherwise shown, and answered where it was asked.
    private var answersHere: Bool { request != nil || (inClaudeApp && trusted) }
    /// This one is being answered in Claude's own box.
    private var sending: Bool { asks.answering == ask.id }
    /// One answer at a time: this question or another is being answered in Claude.
    private var busy: Bool { asks.answering != nil }
    /// A question from Claude Code in Terminal, which only its hook brings here (from the next one on).
    private var hookWouldAnswer: Bool {
        request == nil && !inClaudeApp && ask.provider == .claude && AgentRoster.shared.answering?.contains(.claude) == false
    }
    private var offering: Bool { offeringFor == ask.id }
    /// Why it can't be answered from here just now, or what would let it.
    private var hasNote: Bool { asks.unreachable[ask.id] != nil || (inClaudeApp && !trusted) || offering }
    private var chosen: Set<Int> { model.chosen(index, in: all) }
    /// A question with several answers needs one before Next, as in Claude's own box; Skip leaves it.
    private var canGoOn: Bool { !question.multiSelect || model.isAnswered(index, in: all) }

    var body: some View {
        CardStack(maxHeight: maxHeight) {
            context
            if all.count > 1 || question.header != nil {
                topics.cardSpacing(9)
            }
            // Each question its own: the one before goes first, then this one comes in once the island has
            // made room, so no words are seen moving, squeezed or over others.
            questionText
                .id(index)
                .transition(StandardAnimations.pageChange)
                .cardSpacing(all.count > 1 || question.header != nil ? 7 : 9)
            options
                .id(index)
                .transition(StandardAnimations.pageChange)
                .cardSpacing(11)
                .cardScrolls()
            if hasNote {
                note.cardSpacing(10)
            }
            footer.cardSpacing(11)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(ask.provider.displayName) asks: \(Self.plain(question.question))"))
        .task(id: ask.id) { QuestionKeys.register(keys, handleKey) }
        // The keys read what the card is now: answered here once Accessibility is allowed.
        .onChange(of: answersHere) { QuestionKeys.register(keys, handleKey) }
        .onDisappear { QuestionKeys.unregister(keys) }
    }

    // MARK: Parts

    /// The chat that asks (a click goes to it) and how long it has waited.
    private var context: some View {
        HStack(spacing: 6) {
            Button(action: openChat) {
                HStack(spacing: 6) {
                    AppIconView(bundleID: hostBundleID, size: 15)
                    // Cut at the end, so only the chat's name is.
                    Text(verbatim: layoutDirection.lineMark + [ask.provider.displayName, session?.displayTitle ?? request?.projectName]
                        .compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if request?.body.subagent == true {
                        Text("Subagent").foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Go to this session"))
            Spacer(minLength: 10)
            if let queue { RequestQueuePager(queue: queue) }
            ElapsedText(since: ask.arrived, spokenAs: String(localized: "Waiting"))
                .monospacedDigit()
                .foregroundStyle(.orange)
        }
        .font(.notchCaption)
        .foregroundStyle(.secondary)
        .frame(height: 16)
    }

    /// Several questions: their topics, the one showing filled and answered ones ticked, a click away
    /// each. One question: its topic.
    @ViewBuilder private var topics: some View {
        if all.count > 1 {
            ViewThatFits(in: .horizontal) {
                topicRow(named: true)
                topicRow(named: false)
            }
            .frame(height: 20)
        } else if let header = question.header {
            Text(verbatim: header.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
    }

    private func topicRow(named: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(all.indices, id: \.self) { k in
                let title = named ? all[k].header ?? String(localized: "Question \(k + 1)") : String(k + 1)
                TopicChip(title: title, current: k == index, done: model.isTicked(k, showing: index, in: all)) { go(to: k) }
                    .accessibilityLabel(String(localized: "Question \(k + 1) of \(all.count), \(all[k].header ?? Self.plain(all[k].question))"))
            }
            Spacer(minLength: 8)
            Text("\(index + 1) of \(all.count)")
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(index)))
                .font(.notchCaption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityHidden(true)
        }
    }

    private var questionText: some View {
        Text(Self.drawn(question.question))
            .font(.notchTitle)
            .foregroundStyle(.white)
            .lineLimit(Self.questionLines)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(question.question.count > Self.longQuestion ? Self.plain(question.question) : "")
            .accessibilityAddTraits(.isHeader)
    }

    /// Two to a row, the odd last one across; then Other. They scroll when the island has no more room.
    private var options: some View {
        ScrollView(.vertical) {
            VStack(spacing: Self.tileSpacing) {
                optionGrid
                if answersHere { other }
            }
            // Room for the keyboard's ring.
            .padding(Self.ringRoom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(-Self.ringRoom)
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .opacity(sending ? 0.5 : 1)
    }

    /// Everything the tiles show is read here, once: a row that read the question showing itself could be
    /// redrawn with its old place against the next question, before the grid drops it.
    private var optionGrid: some View {
        let options = Array(question.options.enumerated())
        let picks = answersHere ? chosen : []
        let multiSelect = question.multiSelect
        let focus = model.keyFocus
        let interactive = answersHere && !busy
        return Grid(horizontalSpacing: Self.tileSpacing, verticalSpacing: Self.tileSpacing) {
            ForEach(Array(stride(from: 0, to: options.count, by: 2)), id: \.self) { first in
                GridRow {
                    ForEach(options[first..<min(first + 2, options.count)], id: \.offset) { n, option in
                        let shown = Self.shownLabel(option.label)
                        OptionTile(label: shown.text, recommended: shown.recommended, detail: option.description,
                                   spoken: Self.spoken(option), selected: picks.contains(n), multiSelect: multiSelect,
                                   focused: focus == n, interactive: interactive) {
                            model.keyFocus = nil
                            pick(n)
                        }
                        .gridCellColumns(n == options.count - 1 && n % 2 == 0 && n > 0 ? 2 : 1)
                    }
                }
            }
        }
    }

    /// Your own words: a tile that turns into a text field where it is.
    @ViewBuilder private var other: some View {
        let words = model.typed[index] ?? ""
        let picked = model.typing || model.words(index) != nil
        if model.typing {
            HStack(alignment: .top, spacing: 9) {
                PickMark(selected: true, square: question.multiSelect)
                    .padding(.top, 1.5)
                TextField(String(localized: "Type your own answer"), text: Binding(get: { words }, set: { model.typed[index] = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .tint(Color.notchAccent)
                    .lineLimit(1...3)
                    .focused($typingFocused)
                    .onSubmit { finishTyping(goOn: true) }
                    .onExitCommand { finishTyping(goOn: false) }
                    .accessibilityLabel(String(localized: "Other"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8.5)
            .frame(maxWidth: .infinity, minHeight: Self.otherHeight, alignment: .topLeading)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous).strokeBorder(Color.notchAccent, lineWidth: 1.5))
            .background(NotchTextInputFocus(active: true))
            .onAppear { DispatchQueue.main.async { typingFocused = true } }
        } else {
            Button(action: startTyping) {
                HStack(spacing: 9) {
                    PickMark(selected: picked, square: question.multiSelect)
                    if picked {
                        Text(verbatim: words)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    } else {
                        Text("Other")
                            .font(.notchTitle)
                            .foregroundStyle(.white)
                        Text("Type your own answer")
                            .font(.notchBody)
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: Self.otherHeight, alignment: .leading)
                .background(picked ? Color.notchAccent.opacity(0.11) : .notchRowFill,
                            in: RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
                .overlay {
                    if picked {
                        RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous).strokeBorder(Color.notchAccent, lineWidth: 1.5)
                    }
                }
                .overlay { if model.keyFocus == question.options.count { FocusRing() } }
                .contentShape(RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel(picked ? String(localized: "Other: \(words)") : String(localized: "Other"))
            .accessibilityAddTraits(picked ? .isSelected : [])
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if sending, request == nil {
                // Claude's own box being filled in, which takes a few seconds.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Answering in \(hostName)…")
                        .lineLimit(1)
                }
                .font(.notchCaption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            } else if answersHere {
                NotchTextButton(title: String(localized: "Answer in \(hostName)"),
                                help: String(localized: "Leaves this request to \(hostName)'s own prompt"), action: answerThere)
                    .fixedSize()
            } else if hookWouldAnswer, !offering {
                NotchTextButton(title: String(localized: "Answer here…"),
                                help: String(localized: "Offers to answer Claude Code in the notch from now on")) {
                    offerFailure = nil
                    withAnimation(StandardAnimations.open) { offeringFor = ask.id }
                }
                .fixedSize()
            }
            Spacer(minLength: 8)
            if answersHere {
                if index > 0 {
                    Button(String(localized: "Back")) { go(to: index - 1) }
                        .buttonStyle(RequestButtonStyle(height: Self.buttonHeight))
                        .fixedSize()
                        // In with the question, once the buttons have moved to their place.
                        .transition(StandardAnimations.pageChange)
                }
                Button(String(localized: "Skip"), action: skip)
                    .buttonStyle(RequestButtonStyle(height: Self.buttonHeight))
                    .fixedSize()
                    .help(String(localized: "Leaves this question unanswered"))
                Button(isLast ? String(localized: "Submit") : String(localized: "Next"), action: goOn)
                    .buttonStyle(RequestButtonStyle(role: .primary, height: Self.buttonHeight))
                    .frame(minWidth: 64)
                    .fixedSize()
                    .disabled(!canGoOn)
            } else {
                // While the offer asks, its Turn On is the one to press.
                Button(String(localized: "Answer in \(hostName)"), action: answerThere)
                    .buttonStyle(RequestButtonStyle(role: offering && hookWouldAnswer && offerFailure == nil ? .normal : .primary,
                                                    height: Self.buttonHeight))
                    .fixedSize()
            }
        }
        .disabled(busy)
        .frame(height: Self.buttonHeight)
    }

    /// Why it can't be answered from here just now (Claude's box couldn't take it), or what would let it.
    @ViewBuilder private var note: some View {
        Group {
            if let reason = asks.unreachable[ask.id], reason != .notAllowed {
                Label(reason.note, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if offering {
                AnsweringOffer(hostName: hostName, failure: $offerFailure) {
                    withAnimation(StandardAnimations.open) { offeringFor = nil }
                }
            } else {
                HStack(spacing: 10) {
                    Label("To answer here, allow Underbrim in Accessibility.", systemImage: "accessibility")
                        .foregroundStyle(.secondary)
                    NotchTextButton(title: String(localized: "Allow…"),
                                    help: String(localized: "Lets Underbrim press Claude's button for you: allow it in Accessibility")) {
                        ClaudeAppAnswer.askForAccess()
                    }
                    .fixedSize()
                }
            }
        }
        .font(.notchCaption)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    // MARK: Picking and moving on

    private func pick(_ n: Int) {
        guard answersHere, !busy, question.options.indices.contains(n) else { return }
        if question.multiSelect {
            var picks = chosen
            if picks.contains(n) { picks.remove(n) } else { picks.insert(n) }
            model.picked[index] = picks
        } else {
            model.picked[index] = [n]
            model.typed[index] = nil
            model.typing = false
        }
    }

    private func startTyping() {
        guard answersHere, !busy else { return }
        if !question.multiSelect { model.picked[index] = [] }
        model.keyFocus = nil
        model.typing = true
    }

    private func finishTyping(goOn: Bool) {
        model.typing = false
        if goOn { self.goOn() }
    }

    /// Next, or Submit on the last question.
    private func goOn() {
        guard canGoOn else { return }
        if isLast { submit() } else { go(to: index + 1) }
    }

    private func skip() {
        model.picked[index] = []
        model.typed[index] = nil
        model.typing = false
        if isLast { submit() } else { go(to: index + 1) }
    }

    /// Another question, the island springing to its size.
    private func go(to k: Int) {
        guard all.indices.contains(k), k != index else { return }
        model.typing = false
        if model.keyFocus != nil { model.keyFocus = 0 }
        withAnimation(StandardAnimations.open) {
            model.index = k
            model.seen.insert(k)
        }
    }

    private func submit() {
        guard answersHere, !busy else { return }
        model.typing = false
        withAnimation(StandardAnimations.open) {
            asks.answer(ask, choices: model.choices(for: all), summary: model.summary(for: all))
        }
    }

    /// To the chat that asks, the question left there.
    private func answerThere() {
        openChat()
        withAnimation(StandardAnimations.open) {
            if let request { AgentRequestStore.shared.handBack(request.id) } else { asks.dismiss(ask) }
        }
    }

    private func openChat() {
        if let session { AgentOpener.open(session) } else { AppInfo.activate(hostBundleID) }
    }

    /// Keys while the island has the keyboard (its shortcut): arrows move the ring, Space picks, Return
    /// goes on, ⌘Return submits. A text field being typed in has its own.
    private func handleKey(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard answersHere, !busy, !model.typing else { return false }
        let last = question.options.count
        switch key {
        case 123, 124, 125, 126:
            let ahead = key == 125 || key == (layoutDirection == .rightToLeft ? 123 : 124)
            if let focus = model.keyFocus {
                model.keyFocus = min(max(focus + (ahead ? 1 : -1), 0), last)
            } else {
                model.keyFocus = chosen.min() ?? 0
            }
        case 49:
            guard let focus = model.keyFocus else {
                model.keyFocus = chosen.min() ?? 0
                return true
            }
            if focus < last { pick(focus) } else { startTyping() }
        case 36, 76:
            if modifiers.contains(.command) { submit() } else { goOn() }
        default:
            return false
        }
        return true
    }

    // MARK: Words

    /// An option's label as shown: Claude's "(Recommended)" becomes a badge. The answer always names
    /// the option by its place, so Claude gets its own label back.
    static func shownLabel(_ label: String) -> (text: String, recommended: Bool) {
        let marker = "(Recommended)"
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > marker.count, trimmed.lowercased().hasSuffix(marker.lowercased()) else { return (label, false) }
        return (String(trimmed.dropLast(marker.count)).trimmingCharacters(in: .whitespaces), true)
    }

    /// What VoiceOver says for an option: its label, recommended, and its whole description.
    private static func spoken(_ option: RelayOption) -> String {
        let shown = shownLabel(option.label)
        return [plain(shown.text), shown.recommended ? String(localized: "Recommended") : nil, option.description.map(plain)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// An agent's words as its own window draws them: inline Markdown (code, bold, italics) kept, links as
    /// plain words; the words as they are when they don't parse.
    static func drawn(_ text: String) -> AttributedString {
        guard var parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in parsed.runs where run.link != nil { parsed[run.range].link = nil }
        return parsed
    }

    /// The same words without their marks, for VoiceOver and the line that says what was sent.
    static func plain(_ text: String) -> String { String(drawn(text).characters) }

    nonisolated static let width: CGFloat = 640
    static let questionLines = 8
    static let longQuestion = 600
    static let tileSpacing: CGFloat = 6
    static let tileRadius: CGFloat = 12
    static let otherHeight: CGFloat = 34
    static let buttonHeight: CGFloat = 26
    static let ringRoom: CGFloat = 3
}

/// What a question card shows and what's picked, kept while its page shows (also when the hook's
/// request takes over from the session's record).
@MainActor
@Observable
final class QuestionCardModel {
    /// The question showing, by its place in the card.
    var index = 0
    /// Picked options by question, both by their places in the card. Unset, a question with one answer
    /// has its first option once shown, as Claude's own box starts; one never shown is skipped.
    var picked: [Int: Set<Int>] = [:]
    var typed: [Int: String] = [:]
    var typing = false
    /// The questions shown so far: only those are ticked once answered.
    var seen: Set<Int> = [0]
    /// The option under the keyboard's ring (the options' count is Other), once a key moved it.
    var keyFocus: Int?

    func chosen(_ q: Int, in questions: [RelayQuestion]) -> Set<Int> {
        guard questions.indices.contains(q) else { return [] }
        let question = questions[q]
        return picked[q] ?? (question.multiSelect || question.options.isEmpty || !seen.contains(q) ? [] : [0])
    }

    func words(_ q: Int) -> String? {
        let text = typed[q]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    func isAnswered(_ q: Int, in questions: [RelayQuestion]) -> Bool {
        !chosen(q, in: questions).isEmpty || words(q) != nil
    }

    func isTicked(_ q: Int, showing: Int, in questions: [RelayQuestion]) -> Bool {
        q != showing && seen.contains(q) && isAnswered(q, in: questions)
    }

    /// Each answered question's options and words, by their places in the agent's own list.
    func choices(for questions: [RelayQuestion]) -> [RelayChoice] {
        questions.indices.compactMap { q in
            guard isAnswered(q, in: questions) else { return nil }
            let options = questions[q].options
            let picks = chosen(q, in: questions).sorted().compactMap { options.indices.contains($0) ? options[$0].sourceIndex : nil }
            return RelayChoice(question: questions[q].sourceIndex, options: picks, text: words(q))
        }
    }

    /// The answers in words, for the line that says they were sent.
    func summary(for questions: [RelayQuestion]) -> String {
        questions.indices.compactMap { q -> String? in
            guard isAnswered(q, in: questions) else { return nil }
            let options = questions[q].options
            let labels = chosen(q, in: questions).sorted().compactMap { options.indices.contains($0) ? QuestionCard.plain(QuestionCard.shownLabel(options[$0].label).text) : nil }
            return (labels + [words(q)].compactMap { $0 }).joined(separator: ", ")
        }
        .joined(separator: " · ")
    }
}

/// The question card's keys while the island has the keyboard: the window's key monitor asks it before
/// Home's widgets. The card shown last has them; when it goes, the one before.
@MainActor
enum QuestionKeys {
    typealias Handler = @MainActor (_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool
    private static var cards: [(id: UUID, handle: Handler)] = []

    static func register(_ id: UUID, _ handle: @escaping Handler) {
        if let place = cards.firstIndex(where: { $0.id == id }) {
            cards[place].handle = handle
        } else {
            cards.append((id, handle))
        }
    }

    static func unregister(_ id: UUID) {
        cards.removeAll { $0.id == id }
    }

    static func handle(_ key: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        cards.last?.handle(key, modifiers) ?? false
    }
}

private struct OptionTile: View {
    let label: String
    let recommended: Bool
    let detail: String?
    /// What VoiceOver says for it: the label, recommended, the whole description.
    let spoken: String
    let selected: Bool
    let multiSelect: Bool
    let focused: Bool
    let interactive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if interactive {
            Button(action: action) { tile }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityHidden(true)
                .overlay {
                    OptionElement(label: spoken, selected: selected, multiSelect: multiSelect, press: action)
                        .allowsHitTesting(false)
                }
        } else {
            tile
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spoken))
        }
    }

    private var tile: some View {
        HStack(alignment: .top, spacing: 9) {
            if interactive || selected {
                PickMark(selected: selected, square: multiSelect)
                    .padding(.top, 1.5)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(QuestionCard.drawn(label))
                        .font(.notchTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if recommended {
                        Text("Recommended")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(.white.opacity(0.13), in: Capsule())
                            .fixedSize()
                    }
                }
                if let detail {
                    Text(QuestionCard.drawn(detail))
                        .font(.notchBody)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, interactive || selected ? 12 : 11)
        .padding(.trailing, 11)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: RoundedRectangle(cornerRadius: QuestionCard.tileRadius, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: QuestionCard.tileRadius, style: .continuous)
                    .strokeBorder(Color.notchAccent, lineWidth: 1.5)
            }
        }
        .overlay { if focused { FocusRing() } }
        .contentShape(RoundedRectangle(cornerRadius: QuestionCard.tileRadius, style: .continuous))
        // The whole description, when three lines cut it.
        .help(detail.map { $0.count > Self.cutAfter ? QuestionCard.plain($0) : "" } ?? "")
    }

    private var fill: Color {
        if selected { return Color.notchAccent.opacity(0.11) }
        if !interactive { return .white.opacity(0.05) }
        return hovering ? .notchRowHoverFill : .notchRowFill
    }

    /// About three lines of a description in a tile.
    static let cutAfter = 110
}

/// An option as VoiceOver and other assistive apps take it: a radio button for one answer, a checkbox for
/// several, the tile's own size, with its state. SwiftUI gives a view of its own no radio role.
private struct OptionElement: NSViewRepresentable {
    let label: String
    let selected: Bool
    let multiSelect: Bool
    let press: () -> Void

    func makeNSView(context: Context) -> Element { Element() }

    func updateNSView(_ element: Element, context: Context) {
        element.label = label
        element.multiSelect = multiSelect
        element.press = press
        element.selected = selected
    }

    final class Element: NSView {
        var label = ""
        var multiSelect = false
        var press: () -> Void = {}
        var selected = false {
            didSet { if selected != oldValue { NSAccessibility.post(element: self, notification: .valueChanged) } }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { multiSelect ? .checkBox : .radioButton }
        override func accessibilityLabel() -> String? { label }
        override func accessibilityValue() -> Any? { NSNumber(value: selected) }

        override func accessibilityPerformPress() -> Bool {
            press()
            return true
        }
    }
}

/// A round mark for one answer, a square one for several.
private struct PickMark: View {
    let selected: Bool
    let square: Bool

    var body: some View {
        ZStack {
            if square {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(0.38), lineWidth: 1.5)
                    .opacity(selected ? 0 : 1)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.notchAccent)
                    .opacity(selected ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.onNotchAccent)
                    .opacity(selected ? 1 : 0)
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.38), lineWidth: 1.5)
                    .opacity(selected ? 0 : 1)
                Circle()
                    .fill(Color.notchAccent)
                    .opacity(selected ? 1 : 0)
                Circle()
                    .fill(Color.onNotchAccent)
                    .frame(width: 5, height: 5)
                    .opacity(selected ? 1 : 0)
            }
        }
        .frame(width: 14, height: 14)
        .animation(.easeOut(duration: 0.12), value: selected)
        .accessibilityHidden(true)
    }
}

/// The keyboard's place: a white ring just outside the tile.
private struct FocusRing: View {
    var body: some View {
        RoundedRectangle(cornerRadius: QuestionCard.tileRadius + QuestionCard.ringRoom, style: .continuous)
            .strokeBorder(.white.opacity(0.85), lineWidth: 2)
            .padding(-QuestionCard.ringRoom)
            .allowsHitTesting(false)
    }
}

private struct TopicChip: View {
    let title: String
    let current: Bool
    let done: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(verbatim: title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(current ? .white : .white.opacity(done ? 0.8 : 0.55))
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(current ? .white.opacity(0.16) : .clear, in: Capsule())
            .overlay { if !current { Capsule().strokeBorder(.white.opacity(0.14)) } }
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityValue(done ? String(localized: "Answered") : "")
    }
}

/// The card's rows top to bottom, each its own height and spacing; the one marked to scroll gets what
/// room is left under `maxHeight`, so the card hugs its content until then.
private struct CardStack: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? QuestionCard.width
        return CGSize(width: width, height: heights(width: width, subviews: subviews).total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights.each) {
            y += subview[CardSpacing.self]
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }

    private func heights(width: CGFloat, subviews: Subviews) -> (each: [CGFloat], total: CGFloat) {
        let open = ProposedViewSize(width: width, height: nil)
        var each = subviews.map { $0[CardScrolls.self] ? 0 : $0.sizeThatFits(open).height }
        let spacing = subviews.map { $0[CardSpacing.self] }.reduce(0, +)
        if let flexible = subviews.firstIndex(where: { $0[CardScrolls.self] }) {
            let room = maxHeight - spacing - each.reduce(0, +)
            each[flexible] = min(subviews[flexible].sizeThatFits(open).height, max(room, Self.leastScroll))
        }
        return (each, spacing + each.reduce(0, +))
    }

    /// The options keep at least a tile's height, whatever is above them.
    static let leastScroll: CGFloat = 80
}

private struct CardSpacing: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

private struct CardScrolls: LayoutValueKey {
    static let defaultValue = false
}

private extension View {
    func cardSpacing(_ spacing: CGFloat) -> some View { layoutValue(key: CardSpacing.self, value: spacing) }
    func cardScrolls() -> some View { layoutValue(key: CardScrolls.self, value: true) }
}
