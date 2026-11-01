//
//  AgentAskIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import SwiftUI

struct AgentAskIsland: View {
    let ask: AgentAsks.Ask
    let position: AloneBand.Pages?
    let band: AloneBand
    /// For later, as two fingers up do: the questions wait in the tab bar and the island closes.
    let setAside: () -> Void
    @State private var trusted = AXIsProcessTrusted()
    /// The ask whose row offers answering Claude Code here from now on (after Answer here…).
    @State private var offeringFor: String?
    @State private var offerFailure: String?
    @Environment(\.layoutDirection) private var layoutDirection
    private var asks: AgentAsks { .shared }

    var body: some View {
        VStack(spacing: AloneFrame<EmptyView, EmptyView, EmptyView>.rowSpacing) {
            AroundCamera(gap: band.gap, spans: band.spans) {
                HStack(spacing: 6) {
                    AgentCreatureView(kind: AgentCreatureKind(provider: ask.provider),
                                      state: ask.creature,
                                      since: ask.arrived, height: 16)
                    if let position {
                        PageDots(pages: position) { offset in
                            let all = asks.all
                            guard all.indices.contains(position.index + offset) else { return }
                            withAnimation(StandardAnimations.open) { asks.show(all[position.index + offset].id) }
                        }
                    }
                }
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    NotchSymbolButton(symbol: "xmark", label: String(localized: "Close"), size: 10, box: 22) {
                        withAnimation(StandardAnimations.open) { asks.dismiss(ask) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: band.height)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Later"), setAside)
        .onExitCommand { withAnimation(StandardAnimations.open) { asks.dismiss(ask) } }
        // Allowed in System Settings while it waits: the buttons become the app's own. macOS says
        // when an app's Accessibility changes, a moment before it reads as changed.
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.apple.accessibility.api"))) { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                trusted = AXIsProcessTrusted()
            }
        }
        .onAppear {
            // Whether Claude Code's hook is on, for the offer to answer here from now on.
            switch ask {
            case .waiting, .question: AgentRoster.shared.refresh()
            case .request, .nextStep, .offer: break
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let outcome = asks.outcome, outcome.askID == ask.id {
            if let detail = outcome.detail {
                said(outcome, detail: detail)
            } else {
                Label(outcome.text, systemImage: outcome.failed ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .font(.notchTitle)
                    .foregroundStyle(outcome.failed ? Color.orange : Color.green)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .transition(.opacity)
            }
        } else if let questions = ask.questions {
            // The same card whether the hook or the session's record brings them, so it stays put when one
            // takes over from the other.
            QuestionCard(ask: ask, questions: questions,
                         maxHeight: maxOpenNotchHeight - band.height - AloneFrame<EmptyView, EmptyView, EmptyView>.rowSpacing - NotchMetrics.margin,
                         trusted: trusted)
                .frame(width: QuestionCard.width)
                // Gone before the line saying what was sent comes in: the two never show at once.
                .transition(StandardAnimations.pageChange)
        } else {
            switch ask {
            case .request(let request):
                Group {
                    switch request.body.payload {
                    case .permission(let action, let suggestions):
                        PermissionRequestCard(request: request, action: action, suggestions: suggestions, queue: nil,
                                              shownPermissions: asks.shownPermissions)
                    // Above, as a QuestionCard.
                    case .question: EmptyView()
                    case .plan(let plan): PlanRequestCard(request: request, plan: plan, queue: nil)
                    }
                }
                .frame(width: Self.requestWidth, height: NotchMetrics.tabHeight)
            case .nextStep(let session, let step):
                row(session: session, text: step.ask) { claudeButtons(session) }
            case .offer(let session, let offer):
                row(session: session, text: String(localized: "Start “\(offer.title)” in its own session?")) { claudeButtons(session) }
            case .question:
                EmptyView()
            case .waiting(let session):
                VStack(alignment: .leading, spacing: 10) {
                    row(session: session, text: AgentStatusStyle.of(session, quiet: false).text) { answerThere(session) }
                    if offeringFor == ask.id {
                        AnsweringOffer(hostName: hostName(session), failure: $offerFailure) {
                            withAnimation(StandardAnimations.open) { offeringFor = nil }
                        }
                        .frame(maxWidth: Self.offerWidth, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                    }
                }
            }
        }
    }

    /// Questions answered: the card folds to one line, what went and the answers.
    private func said(_ outcome: AgentAsks.Outcome, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: outcome.failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 20))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, outcome.failed ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.text)
                    .font(.notchTitle)
                    .foregroundStyle(.white)
                Text(verbatim: detail)
                    .font(.notchBody)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: Self.saidWidth, minHeight: 36, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .transition(StandardAnimations.pageChange)
    }

    /// The Claude app's own buttons for its question or offer, pressed there; without Accessibility, or
    /// once it couldn't be reached, a way to answer it in Claude.
    @ViewBuilder private func claudeButtons(_ session: AgentSession) -> some View {
        if !trusted {
            answerThere(session)
        } else if asks.unreachable[ask.id] != nil {
            Button(String(localized: "Open in \(session.provider.appName)")) { AgentOpener.open(session) }
                .buttonStyle(RequestButtonStyle(role: .primary, height: 24))
                .fixedSize()
        } else if let question = ask.claudeQuestion {
            ForEach(Array(question.choices.enumerated()), id: \.offset) { index, title in
                Button(title) { asks.answer(ask, choice: index) }
                    .buttonStyle(RequestButtonStyle(role: index == 0 ? .primary : .normal, height: 24))
                    .fixedSize()
                    .notchDisabled(asks.answering != nil)
            }
        }
    }

    /// Why the island couldn't answer it, under the question.
    private var unreachableNote: String? { asks.unreachable[ask.id]?.note }

    /// The session and what it asks; clicking anywhere on it (not its buttons) opens the chat that asked.
    private func row(session: AgentSession, text: String, @ViewBuilder answers: () -> some View) -> some View {
        HStack(spacing: 14) {
            Button {
                AgentOpener.open(session)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(layoutDirection.lineMark)\(session.provider.displayName) · \(session.displayTitle)")
                        .font(.notchCaption)
                        .foregroundStyle(.secondary)
                        // As on the session's line: titles read from the start, folder names differ at the end.
                        .truncationMode(session.hasTitle ? .tail : .middle)
                    Text(verbatim: text)
                        .font(.notchTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unreachableNote {
                        Text(unreachableNote)
                            .font(.notchCaption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if asks.pressingAgain == ask.id {
                        // The island's own doing, in its own words and grey: not the agent's.
                        Text("Claude didn't take the answer. Pressing it again…")
                            .font(.notchCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: Self.textWidth, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Go to this session"))
            .accessibilityElement(children: .combine)
            .accessibilityHint(AgentOpener.actionDescription(for: session))
            Spacer(minLength: 0)
            HStack(spacing: 8) { answers() }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    /// Without Accessibility, or with no hook to answer through: its own window, and a way to
    /// answer here from now on (Claude Code's hook offered in place, Codex's in Settings, where Codex
    /// is asked to trust it).
    @ViewBuilder private func answerThere(_ session: AgentSession) -> some View {
        if ask.claudeQuestion != nil {
            NotchTextButton(title: String(localized: "Answer here…"),
                            help: String(localized: "Lets Underbrim press Claude's button for you: allow it in Accessibility"),
                            action: { ClaudeAppAnswer.askForAccess() })
            .fixedSize()
        } else if session.provider == .claude, AgentRoster.shared.answering?.contains(.claude) == false {
            if offeringFor != ask.id {
                NotchTextButton(title: String(localized: "Answer here…"),
                                help: String(localized: "Offers to answer Claude Code in the notch from now on")) {
                    offerFailure = nil
                    withAnimation(StandardAnimations.open) { offeringFor = ask.id }
                }
                .fixedSize()
            }
        } else if session.provider == .codex, AgentRoster.shared.answering?.contains(.codex) == false {
            NotchTextButton(title: String(localized: "Answer here…"),
                            help: String(localized: "Turn on answering in the notch in Settings")) {
                SettingsWindowController.shared.showWindow(tab: .agents)
            }
            .fixedSize()
        }
        // While the offer asks, its Turn On is the one to press.
        Button(String(localized: "Answer in \(session.provider.appName)")) { AgentOpener.open(session) }
            .buttonStyle(RequestButtonStyle(role: offerAsks ? .normal : .primary, height: 24))
            .fixedSize()
    }

    private var offerAsks: Bool {
        offeringFor == ask.id && offerFailure == nil && AgentRoster.shared.answering?.contains(.claude) == false
    }

    /// The app a session asks in, by name.
    private func hostName(_ session: AgentSession) -> String {
        AppInfo.name(bundleID: session.hostBundleID ?? session.provider.defaultHostBundleID) ?? session.provider.appName
    }

    static let textWidth: CGFloat = 340
    static let offerWidth: CGFloat = 560
    static let requestWidth: CGFloat = 600
    static let saidWidth: CGFloat = 420
}
