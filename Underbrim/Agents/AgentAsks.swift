//
//  AgentAsks.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What each session waits on, worked out in one place for the island, the tab, the closed
//  notch, Allow All and the sounds: a hook request, the Claude app's offer card or its
//  question under a finished turn, Claude's questions with options read from its session,
//  or a wait with no hook. Answering one here, or handing a
//  request back, ends it here; closing a request hands it back, so the agent asks in its own
//  window, and closing anything else hides it here only. Set aside (two fingers up or
//  sideways), they wait in the tab bar and on the closed notch instead.
//

import AppKit
import Defaults
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class AgentAsks {
    static let shared = AgentAsks()

    enum Ask: Identifiable, Equatable {
        /// From an agent's hook: answered here.
        case request(AgentRequest)
        /// The Claude app's question under a finished turn: answered by its own button.
        case nextStep(AgentSession, AgentNextStep)
        /// The Claude app's offer to start a session: answered by its card's own button.
        case offer(AgentSession, AgentOffer)
        /// Questions with options, read from the session with no hook request for them: answered in
        /// Claude's own box.
        case question(AgentSession, AgentQuestion)
        /// An agent waiting on the user with no hook to answer through: answered in its window.
        case waiting(AgentSession)

        /// The same for as long as the wait lasts.
        var id: String {
            func stamp(_ date: Date) -> String { String(Int(date.timeIntervalSince1970 * 1000)) }
            return switch self {
            case .request(let request): "request:\(request.id)"
            case .nextStep(let session, let step): "next:\(session.id):\(step.id ?? stamp(step.at))"
            case .offer(let session, let offer): "offer:\(session.id):\(offer.id ?? stamp(offer.at))"
            case .question(let session, let question): "question:\(session.id):\(question.id ?? stamp(question.at))"
            case .waiting(let session): "waiting:\(session.id):\(stamp(session.phaseSince))"
            }
        }

        /// Its page on the island. Questions keep theirs when the hook's request takes over from the
        /// session's record (both read the same call), so nothing moves and the picks stay.
        var page: String {
            switch self {
            case .question(let session, let question):
                return "questions:\(session.id):\(question.questions.hashValue)"
            case .request(let request):
                if case .question(let asked) = request.body.payload, let key = request.sessionKey {
                    return "questions:\(key):\(asked.hashValue)"
                }
                return id
            case .nextStep, .offer, .waiting:
                return id
            }
        }

        /// The questions with options it asks, whichever way they came.
        var questions: RelayQuestions? {
            switch self {
            case .question(_, let question): question.questions
            case .request(let request): if case .question(let asked) = request.body.payload { asked } else { nil }
            case .nextStep, .offer, .waiting: nil
            }
        }

        var provider: AgentProvider {
            switch self {
            case .request(let request): request.provider
            case .nextStep(let session, _), .offer(let session, _), .question(let session, _), .waiting(let session): session.provider
            }
        }

        var arrived: Date {
            switch self {
            case .request(let request): request.arrived
            case .nextStep(_, let step): step.at
            case .offer(_, let offer): offer.at
            case .question(_, let question): question.at
            case .waiting(let session): session.phaseSince
            }
        }

        @MainActor var session: AgentSession? {
            switch self {
            case .request(let request): request.sessionKey.flatMap { key in AgentSessionStore.shared.sessions.first { $0.id == key } }
            case .nextStep(let session, _), .offer(let session, _), .question(let session, _), .waiting(let session): session
            }
        }

        /// Its creature, wherever the ask shows (its page, the tab bar once set aside): asking a question,
        /// or for a go-ahead (a tool, a plan); a wait with no hook as its session shows it.
        var creature: AgentCreatureState {
            switch self {
            case .request(let request): AgentSession.Attention(request).creature
            case .nextStep, .offer, .question: .question
            case .waiting(let session): AgentCreatureState(session.phase)
            }
        }

        /// A question in the Claude app's window, answered by pressing one of its buttons there.
        var claudeQuestion: ClaudeAppAnswer.Question? {
            switch self {
            case .nextStep(_, let step): .nextStep(step)
            case .offer(_, let offer): .offer(offer)
            case .request, .question, .waiting: nil
            }
        }

        /// Blocks the agent until answered (a question under a finished turn doesn't).
        var blocks: Bool {
            if case .nextStep = self { false } else { true }
        }
    }

    /// An answer given here, said in words for a moment before the question goes.
    struct Outcome: Equatable {
        let askID: String
        let text: String
        /// Under it, for questions with options: the answers.
        var detail: String?
        let failed: Bool
    }

    /// Why a question here couldn't be answered from the island, until it's answered in Claude.
    enum Unreachable: Equatable {
        /// Claude's window shows another chat and couldn't switch to this one.
        case notShown
        case notRunning
        /// Pressed, but Claude didn't take it.
        case notTaken
        /// Claude's box asks something other than what the island shows.
        case different
        /// Underbrim may no longer use Accessibility.
        case notAllowed

        /// Why Claude's box couldn't take the answers; nil when it did, or they were answered there.
        init?(_ result: ClaudeQuestionBox.Result) {
            switch result {
            case .sent, .alreadyAnswered: return nil
            case .notShown: self = .notShown
            case .notRunning: self = .notRunning
            case .notTaken: self = .notTaken
            case .different: self = .different
            case .notAllowed: self = .notAllowed
            }
        }

        /// Said under the question.
        var note: String {
            switch self {
            case .notAllowed: String(localized: "To answer here, allow Underbrim in Accessibility.")
            case .notShown: String(localized: "Claude isn't showing this chat, so it can't be answered from here.")
            case .notRunning: String(localized: "Claude isn't open.")
            case .notTaken: String(localized: "Claude didn't take the answer. Answer it there.")
            case .different: String(localized: "Claude's box shows other questions. Answer them there.")
            }
        }
    }

    private(set) var outcome: Outcome?
    private(set) var answering: String?
    /// The question being answered, once Claude let the first press go by and it's pressed again.
    private(set) var pressingAgain: String?
    private(set) var unreachable: [String: Unreachable] = [:]
    /// Sessions whose request was handed back, and when: their wait is left to the agent's own
    /// window until they move on.
    private var handedBack: [String: Date] = [:]
    private var dismissed: [String] = Defaults[.dismissedAgentAsks]
    /// Set aside for later: they don't hold the island or open it until brought back.
    private var setAsideIDs: [String] = Defaults[.setAsideAgentAsks]
    /// The question shown while its outcome is said, after its session has moved on.
    private var held: Ask?

    private init() {}

    /// Every wait, one a session at most, oldest first, whether shown or set aside: a request, else the
    /// offer card, else a wait with no hook (unless its request was handed back), its questions with
    /// options when it waits on those, else the question under a turn that has ended.
    private var waiting: [Ask] {
        let requests = AgentRequestStore.shared.requests
        let asking = Set(requests.compactMap(\.sessionKey))
        var asks = requests.map(Ask.request)
        for session in AgentSessionStore.shared.visibleSessions where !session.hasEnded && !asking.contains(session.id) {
            if let offer = session.details.offer {
                asks.append(.offer(session, offer))
            } else if session.needsAttention {
                guard !handedBackWait(session) else { continue }
                if case .attention(.question) = session.phase, let question = session.details.question {
                    asks.append(.question(session, question))
                } else {
                    asks.append(.waiting(session))
                }
            } else if let step = session.details.nextStep, session.phase != .working {
                asks.append(.nextStep(session, step))
            }
        }
        return asks.filter { !dismissed.contains($0.id) }.sorted { $0.arrived < $1.arrived }
    }

    /// A request handed back (closed here, Answer in…, its agent's window in front, or timed out):
    /// its session's wait stays in that window.
    func handedBack(_ request: AgentRequest) {
        guard let key = request.sessionKey else { return }
        handedBack[key] = Date()
    }

    /// The session's wait is the one whose request was handed back: it began before then, or just after
    /// (a status file can say it's waiting a moment after its hook asked). A later one waits here again.
    private func handedBackWait(_ session: AgentSession) -> Bool {
        guard let since = handedBack[session.id] else { return false }
        return session.phaseSince <= since.addingTimeInterval(Self.handBackLag)
    }

    static let handBackLag: TimeInterval = 3

    /// After the sessions change: hand-backs whose session has moved on are let go.
    func sessionsChanged(_ sessions: [AgentSession]) {
        guard !handedBack.isEmpty || !unreachable.isEmpty else { return }
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = handedBack.filter { key, since in
            byID[key].map { $0.phaseSince <= since || ($0.needsAttention && handedBackWait($0)) } ?? false
        }
        if kept.count != handedBack.count { handedBack = kept }
        let waitingIDs = Set(waiting.map(\.id))
        if unreachable.keys.contains(where: { !waitingIDs.contains($0) }) {
            unreachable = unreachable.filter { waitingIDs.contains($0.key) }
        }
    }

    /// The permission requests the island shows, for its Allow All.
    var shownPermissions: [String] {
        all.compactMap { ask in
            if case .request(let request) = ask, request.kind == .permission { request.id } else { nil }
        }
    }

    /// The questions the island shows, one page each.
    var all: [Ask] {
        var asks = waiting.filter { !setAsideIDs.contains($0.id) }
        if let held, !setAsideIDs.contains(held.id), !asks.contains(where: { $0.id == held.id }) { asks.insert(held, at: 0) }
        return asks
    }

    /// The questions set aside, for the tab bar and the closed notch.
    var setAside: [Ask] { waiting.filter { setAsideIDs.contains($0.id) } }

    /// What waits on the closed notch rather than on the island: what was set aside, or everything while
    /// the island doesn't show questions (Settings).
    var onClosedNotch: [Ask] { Defaults[.openIslandForAgentRequests] ? setAside : waiting }

    func isSetAside(_ ask: Ask) -> Bool { setAsideIDs.contains(ask.id) }

    /// The sessions whose question under a reply still waits: their lines say so, as the closed notch does.
    var askingSessions: Set<String> {
        Set(waiting.compactMap { ask in if case .nextStep(let session, _) = ask { session.id } else { nil } })
    }

    var current: Ask? {
        let asks = all
        return asks.first { $0.id == shownID } ?? asks.first
    }

    var shownID: String?

    /// ✕ or Escape: a request goes back to its agent's own prompt; anything else is hidden here (a few
    /// hundred are remembered across restarts) and still waits in its window.
    func dismiss(_ ask: Ask) {
        if case .request(let request) = ask {
            if held?.id == ask.id { held = nil }
            return AgentRequestStore.shared.handBack(request.id)
        }
        guard !dismissed.contains(ask.id) else { return }
        dismissed = Array((dismissed + [ask.id]).suffix(Self.remembered))
        Defaults[.dismissedAgentAsks] = dismissed
        if held?.id == ask.id { held = nil }
        if outcome?.askID == ask.id { outcome = nil }
        unreachable[ask.id] = nil
        if case .nextStep = ask { AgentSessionStore.shared.scheduleHousekeeping() }
    }

    static let remembered = 200

    /// Two fingers up or sideways on a question: every one shown waits for later together.
    func setAsideAll() {
        let shown = all.map(\.id).filter { !setAsideIDs.contains($0) && $0 != answering }
        guard !shown.isEmpty else { return }
        setAsideIDs = Array((setAsideIDs + shown).suffix(Self.remembered))
        Defaults[.setAsideAgentAsks] = setAsideIDs
        shownID = nil
        AgentSessionStore.shared.refreshSummary()
    }

    /// Shows `id`, bringing back every question set aside if it's one of them.
    func show(_ id: String) {
        if setAsideIDs.contains(id) {
            let waitingIDs = Set(waiting.map(\.id))
            setAsideIDs.removeAll { waitingIDs.contains($0) }
            Defaults[.setAsideAgentAsks] = setAsideIDs
            AgentSessionStore.shared.refreshSummary()
        }
        shownID = id
    }

    func waits(_ session: AgentSession, _ step: AgentNextStep) -> Bool {
        !dismissed.contains(Ask.nextStep(session, step).id)
    }

    // MARK: Answering in the Claude app

    /// Presses the Claude app's button `index` for the question `ask` (Claude stays where it is); says
    /// how it went, then lets it go. One it can't reach stays, with a way to open it.
    func answer(_ ask: Ask, choice index: Int) {
        guard answering == nil, let session = ask.session, let question = ask.claudeQuestion,
              question.choices.indices.contains(index) else { return }
        answering = ask.id
        held = ask
        unreachable[ask.id] = nil
        let words = question.choices[index]
        Task {
            let result = await ClaudeAppAnswer.press(question, choice: index, session: session) {
                withAnimation(StandardAnimations.open) { pressingAgain = ask.id }
            }
            answering = nil
            pressingAgain = nil
            withAnimation(StandardAnimations.open) {
                switch result {
                case .pressed:
                    say(Outcome(askID: ask.id, text: String(localized: "Sent to Claude: \(words)"), failed: false), then: ask, after: 1.4)
                case .alreadyAnswered:
                    held = nil
                    dismiss(ask)
                case .notShown, .notRunning, .notTaken:
                    held = nil
                    unreachable[ask.id] = switch result {
                    case .notShown: .notShown
                    case .notRunning: .notRunning
                    default: .notTaken
                    }
                case .notAllowed:
                    held = nil
                }
            }
        }
    }

    /// Answers questions with options: a hook request goes back through the hook at once; questions read
    /// from a Claude app chat are filled in and sent in Claude's own box, which takes a few seconds. Says
    /// what was sent for a moment, then lets the question go; one Claude's box couldn't take stays, with
    /// why. No choices at all: every question was skipped.
    func answer(_ ask: Ask, choices: [RelayChoice], summary: String) {
        guard answering == nil else { return }
        let app = ask.provider.appName
        let sent = choices.isEmpty
            ? Outcome(askID: ask.id, text: String(localized: "Skipped"), detail: String(localized: "\(app) goes on without your answers."), failed: false)
            : Outcome(askID: ask.id, text: String(localized: "Sent to \(app)"), detail: summary, failed: false)
        switch ask {
        case .request(let request):
            held = ask
            AgentRequestStore.shared.answer(request.id, choices: choices)
            say(sent, then: ask, after: Self.saidFor)
        case .question(let session, let question):
            answering = ask.id
            held = ask
            unreachable[ask.id] = nil
            Task {
                let result = await ClaudeQuestionBox.send(question, choices: choices, session: session)
                answering = nil
                withAnimation(StandardAnimations.open) {
                    switch result {
                    case .sent:
                        say(sent, then: ask, after: Self.saidFor)
                    case .alreadyAnswered:
                        held = nil
                        dismiss(ask)
                    case .notShown, .notRunning, .notTaken, .different, .notAllowed:
                        held = nil
                        unreachable[ask.id] = Unreachable(result)
                    }
                }
            }
        case .nextStep, .offer, .waiting:
            return
        }
    }

    /// How long the line that says an answer went stays before the island folds.
    static let saidFor: Double = 1.6

    private func say(_ outcome: Outcome, then gone: Ask?, after seconds: Double) {
        self.outcome = outcome
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard self.outcome == outcome else { return }
            withAnimation(StandardAnimations.open) {
                self.outcome = nil
                held = nil
                if let gone { dismiss(gone) }
            }
        }
    }
}

extension AgentNextStep.Choice {
    var title: String {
        if let label { return label }
        return switch action {
        case "commit": String(localized: "Commit")
        case "create_pr": String(localized: "Create Pull Request")
        case "merge": String(localized: "Merge")
        case "fix_ci": String(localized: "Fix Checks")
        case "address_comments": String(localized: "Address Comments")
        case "resolve_conflicts": String(localized: "Resolve Conflicts")
        case "verify": String(localized: "Verify")
        case "archive": String(localized: "Archive")
        case "new_session": String(localized: "New Session")
        // One this build doesn't know, readable: "open_pr" → "Open pr".
        default: action.map { name in
            let words = name.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        } ?? ""
        }
    }
}
