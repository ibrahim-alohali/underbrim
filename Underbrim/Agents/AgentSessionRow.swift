//
//  AgentSessionRow.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A session's line in the Agents tab, with its tasks, dev servers and actions.
//

import Defaults
import SwiftUI

/// A session's line: its creature and where it runs, its title, what it's doing (or the start of
/// its reply), its tasks and dev servers, and its time. The whole line is a button that opens the
/// session; its pieces lie over it and let clicks through, but for the dev-server menu and, on
/// hover, the actions that take the corner.
struct AgentSessionRow: View {
    let session: AgentSession
    let quiet: Bool
    /// Its question under a reply waits on the user: the line says so, as the closed notch does.
    var asking = false
    var canClear = false
    /// The pointer is on it, as the list's pointer watch tells (onHover misses moves on the island).
    var hovering = false
    @Default(.showSessionDetails) private var showDetails
    private let awake = AgentAwake.shared
    private let devServers = DevServerStore.shared

    private var servers: [DevServer] { devServers.servers[session.id] ?? [] }

    private func style(at now: Date) -> AgentStatusStyle {
        guard !asking else {
            let question = AgentSession.Attention.question
            return .init(symbol: question.symbol, tint: .orange, text: question.words)
        }
        return .of(session, quiet: quiet, details: showDetails, now: now)
    }

    /// Gone quiet, its minutes count on while the island stays open, on the session's own clock: they
    /// change at the minute since its last news, on the line and for VoiceOver alike.
    private var quietMinutes: PeriodicTimelineSchedule { .periodic(from: session.lastEventAt, by: 60) }

    /// The Mac is kept awake for this one (a cup in its corner).
    private var keepsAwake: Bool { awake.holding && session.phase == .working && !quiet }

    /// For a while after a turn ends, the start of the reply takes the state's place.
    private var reply: String? {
        guard showDetails, !asking, session.phase == .completed, let reply = session.details.reply,
              Date().timeIntervalSince(session.phaseSince) < AgentSessionStore.replyShown
        else { return nil }
        return reply
    }

    private var tasks: [AgentTask] {
        guard showDetails, session.phase == .working || session.needsAttention else { return [] }
        return session.details.tasks
    }

    private func spokenLabel(at now: Date) -> String {
        let head = "\(session.originText), \(session.displayTitle)", state = style(at: now).accessibilityText
        var label = "\(head): \(state)"
        if let reply {
            // A reply that starts by saying it's done ("Done, notes written") says so once.
            let repeats = reply.range(of: state, options: [.anchored, .caseInsensitive])
                .map { $0.upperBound == reply.endIndex || !reply[$0.upperBound].isLetter } ?? false
            label = repeats ? "\(head): \(reply)" : "\(label). \(reply)"
        }
        if !tasks.isEmpty { label += ". \(TaskProgressLine.spoken(tasks))" }
        if keepsAwake { label += ". " + String(localized: "Keeping your Mac awake") }
        for server in servers { label += ". " + String(localized: "Serving localhost:\(String(server.port))") }
        return label
    }

    private var helpText: String {
        var lines = [AgentOpener.actionDescription(for: session)]
        if reply != nil, let prompt = session.details.prompt { lines.append(String(localized: "You: \(prompt)")) }
        if let step = tasks.currentStep { lines.append(step) }
        if keepsAwake { lines.append(String(localized: "Keeping your Mac awake")) }
        return lines.joined(separator: "\n")
    }

    private var canStartHere: Bool {
        session.cwd != nil && session.provider.readsFiles && AgentOpener.hasApp(session.provider)
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                // With a question waiting it asks, as beside the camera; gone quiet, it rests, as the line sits
                // under Idle: nothing says it's still at work.
                AgentCreatureView(kind: AgentCreatureKind(provider: session.provider),
                                  state: asking ? .question : quiet && session.phase == .working ? .idle : AgentCreatureState(session.phase),
                                  since: session.phaseSince, height: 13, movesOnlyWhileWorking: true)
                // The host app's icon says where it runs (Desktop, Terminal, VS Code);
                // VoiceOver hears the full origin.
                AppIconView(bundleID: session.hostBundleID ?? session.provider.defaultHostBundleID, size: 14)
                Text(session.displayTitle)
                    .font(.notchBody.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    // Folder names differ at the end; titles read from the start.
                    .truncationMode(session.hasTitle ? .tail : .middle)
                    .layoutPriority(1)
                // As much say as the title: a long title shares the room instead of cutting what it's doing to
                // a stub, and a short state leaves the rest to the title.
                status
                    .frame(minWidth: 80, alignment: .leading)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if !tasks.isEmpty { TaskProgressLine(tasks: tasks, showsStep: false) }
            }
            .allowsHitTesting(false)
            if !servers.isEmpty { DevServerMenu(servers: servers) }
            // On hover the actions take the corner, in room kept for them so nothing moves.
            ZStack(alignment: .trailing) {
                trailing
                    .opacity(hovering ? 0 : 1)
                    .allowsHitTesting(false)
                HStack(spacing: 0) { actions(labelled: false) }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // The button below speaks for the line, its menu and its actions.
        .accessibilityHidden(true)
        .background {
            if countsQuietMinutes {
                TimelineView(quietMinutes) { context in openButton(at: context.date) }
            } else {
                openButton(at: .now)
            }
        }
        .background(hovering ? Color.notchRowHoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            actions(labelled: true)
            if session.cwd != nil || canClear { Divider() }
            hideFolderAction
            clearAction
        }
    }

    private func openButton(at now: Date) -> some View {
        Button {
            AgentOpener.open(session)
        } label: {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(spokenLabel(at: now))
        .accessibilityHint(AgentOpener.actionDescription(for: session))
        .accessibilityActions {
            actions(labelled: true)
            hideFolderAction
            clearAction
            ForEach(servers) { server in
                Button(String(localized: "Open localhost:\(String(server.port))")) { DevServerMenu.open(server) }
                Button(String(localized: "Stop \(server.program) on Port \(String(server.port))")) { DevServerStore.shared.stop(server) }
            }
        }
    }

    /// Only a quiet session's line changes with the clock (its minutes); the others redraw when the session does.
    private var countsQuietMinutes: Bool { quiet && session.phase == .working && reply == nil }

    @ViewBuilder private var status: some View {
        if countsQuietMinutes {
            TimelineView(quietMinutes) { context in statusLine(at: context.date) }
        } else {
            statusLine(at: .now)
        }
    }

    @ViewBuilder private func statusLine(at now: Date) -> some View {
        let style = self.style(at: now)
        Group {
            if let reply {
                Text(reply)
                    .foregroundStyle(.white.opacity(0.88))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: style.symbol)
                        .font(.notchSymbol(size: 10))
                        .foregroundStyle(style.tint)
                    Text(style.text)
                        .foregroundStyle(style.tint == .white ? .secondary : style.tint)
                }
            }
        }
        .font(.notchCaption)
        .lineLimit(1)
    }

    @ViewBuilder private var hideFolderAction: some View {
        if let cwd = session.cwd {
            Button(String(localized: "Hide Sessions in This Folder")) {
                withAnimation(.smooth) { AgentSessionStore.shared.hideFolder(cwd) }
            }
        }
    }

    @ViewBuilder private var clearAction: some View {
        if canClear {
            Button(String(localized: "Clear Finished Sessions")) {
                withAnimation(.smooth) { AgentSessionStore.shared.clearSettled() }
            }
        }
    }

    @ViewBuilder private func actions(labelled: Bool) -> some View {
        if canStartHere {
            // A session elsewhere (a terminal, an editor) starts its new one in the agent's app: it says so.
            let inApp = session.hostBundleID.map { $0 == session.provider.defaultHostBundleID } ?? true
            RowAction(labelled: labelled, symbol: "plus.bubble",
                      title: inApp ? String(localized: "New Session in This Folder")
                                   : String(localized: "New \(session.provider.appName) Session in This Folder")) {
                AgentOpener.startNewSession(session.provider, folder: session.cwd)
            }
        }
        if session.cwd != nil {
            RowAction(labelled: labelled, symbol: "folder", title: String(localized: "Show in Finder")) {
                AgentOpener.showInFinder(session)
            }
        }
        // Not while it works (its next event would bring it straight back), unless it
        // has gone quiet: then it may be stuck for good. One waiting on you only hears
        // again once you answer, so it can go (or it's stuck too).
        if session.phase != .working || quiet {
            RowAction(labelled: labelled, symbol: "xmark", title: String(localized: "Remove from List")) {
                withAnimation(.smooth) { AgentSessionStore.shared.dismiss(session.id) }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch session.phase {
        case .working:
            HStack(spacing: 3) {
                if keepsAwake {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.notchSymbol(size: 9))
                        .foregroundStyle(.secondary)
                }
                // The turn's time: an approval or a question along the way doesn't start it again.
                ElapsedText(since: session.turnSince)
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .attention, _ where asking:
            Text(String(localized: "Review"))
                .font(.notchCaption)
                .foregroundStyle(.orange)
        case .completed where reply != nil:
            // The state gives way to the reply; the corner says it's done.
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.notchSymbol(size: 10))
                    .foregroundStyle(.green)
                RelativeTimeText(date: session.phaseSince)
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            RelativeTimeText(date: session.phaseSince)
                .font(.notchCaption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

private struct DevServerMenu: View {
    let servers: [DevServer]

    static func open(_ server: DevServer) {
        if let url = server.url { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        Menu {
            ForEach(servers) { server in
                Section("\(server.program) · localhost:\(String(server.port))") {
                    Button(String(localized: "Open in Browser")) { Self.open(server) }
                    Button(String(localized: "Stop \(server.program)")) { DevServerStore.shared.stop(server) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.notchSymbol(size: 9))
                Text(verbatim: ":\(servers[0].port)" + (servers.count > 1 ? " +\(servers.count - 1)" : ""))
                    .monospacedDigit()
            }
            .font(.notchCaption)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.12), in: Capsule())
            .environment(\.layoutDirection, .leftToRight)  // a port reads left to right
            .accessibilityElement(children: .ignore)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(spoken)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        servers.map { String(localized: "Serving localhost:\(String($0.port))") }.joined(separator: ", ")
    }
}

/// An agent's task list: a mark per step (or a bar past ten), how many are
/// done, and the step it's on.
struct TaskProgressLine: View {
    let tasks: [AgentTask]
    /// The step it's on, after the count (a session's line leaves it to the tooltip).
    var showsStep = true

    static func spoken(_ tasks: [AgentTask]) -> String {
        let count = String(localized: "\(tasks.doneCount) of \(tasks.count) steps done")
        return tasks.currentStep.map { "\(count), \($0)" } ?? count
    }

    var body: some View {
        HStack(spacing: 5) {
            if tasks.count <= 10 {
                HStack(spacing: 2) {
                    ForEach(tasks.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Self.fill(tasks[index].status))
                            .frame(width: 6, height: 6)
                    }
                }
            } else {
                Capsule().fill(.white.opacity(0.18))
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(.green).frame(width: proxy.size.width * CGFloat(tasks.doneCount) / CGFloat(tasks.count))
                        }
                    }
                    .frame(width: 40, height: 4)
            }
            Text("\(tasks.doneCount) of \(tasks.count)")
                .monospacedDigit()
            if showsStep, let step = tasks.currentStep {
                Text(step)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.notchCaption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(tasks))
    }

    private static func fill(_ status: AgentTask.Status) -> Color {
        switch status {
        case .completed: .green
        case .inProgress: .orange
        case .pending: .white.opacity(0.22)
        }
    }
}

private struct RowAction: View {
    let labelled: Bool
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        if labelled {
            Button(title, action: action)
        } else {
            NotchSymbolButton(symbol: symbol, label: title, size: 11, box: 22, action: action)
        }
    }
}
