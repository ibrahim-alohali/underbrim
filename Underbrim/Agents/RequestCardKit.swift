//
//  RequestCardKit.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What the request cards share: the header with its pager, the buttons, the code box
//  and the text field.
//

import SwiftUI

struct RequestQueuePager: View {
    let queue: RequestQueue

    var body: some View {
        HStack(spacing: 2) {
            NotchSymbolButton(symbol: "chevron.backward", label: String(localized: "Previous request"), size: 9, box: 16) { queue.step(-1) }
                .notchDisabled(queue.position == 1)
            Text("\(queue.position) of \(queue.count) waiting").monospacedDigit()
            NotchSymbolButton(symbol: "chevron.forward", label: String(localized: "Next request"), size: 9, box: 16) { queue.step(1) }
                .notchDisabled(queue.position == queue.count)
        }
    }
}

/// Not `.borderedProminent`: the notch's window is rarely key, and AppKit greys that
/// style out then.
struct RequestButtonStyle: ButtonStyle {
    enum Role { case primary, normal, warning }
    var role: Role = .normal
    var height: CGFloat = 22
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height < 20 ? 11 : 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            // The translations fit; this only keeps a longer one whole rather than cut.
            .minimumScaleFactor(0.85)
            .foregroundStyle(role == .primary ? Color.onNotchAccent : .white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.4)
    }

    private var fill: Color {
        switch role {
        case .primary: .notchAccent
        case .normal: .white.opacity(0.13)
        case .warning: .red
        }
    }
}

extension LayoutDirection {
    /// Starts a line that joins an agent's name and a title in the island's direction: otherwise its first
    /// word decides, and in Arabic a Latin "Claude Code" lays it out left to right, the title first.
    var lineMark: String { self == .rightToLeft ? "\u{200F}" : "\u{200E}" }
}

struct RequestHeader: View {
    let request: AgentRequest
    let title: String
    let queue: RequestQueue?
    var trailing: AnyView?
    @Environment(\.layoutDirection) private var layoutDirection

    private var session: AgentSession? {
        request.sessionKey.flatMap { key in AgentSessionStore.shared.sessions.first { $0.id == key } }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let session { AgentOpener.open(session) } else {
                    AppInfo.activate(request.hostBundleID ?? request.provider.defaultHostBundleID)
                }
            } label: {
                HStack(spacing: 6) {
                    AppIconView(bundleID: request.hostBundleID ?? request.provider.defaultHostBundleID, size: 16)
                    // Cut at the end, so only the session's name is: a cut in the middle could land in a
                    // question's heading and run it into the name.
                    Text(verbatim: layoutDirection.lineMark
                         + [title, session?.displayTitle ?? request.projectName].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if request.body.subagent == true {
                        Text("Subagent").foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Go to this session"))
            Spacer(minLength: 6)
            if let queue { RequestQueuePager(queue: queue) }
            if let trailing { trailing }
            NotchTextButton(title: String(localized: "Answer in \(request.provider.appName)"),
                            help: String(localized: "Leaves this request to \(request.provider.appName)'s own prompt")) {
                withAnimation(StandardAnimations.open) { AgentRequestStore.shared.handBack(request.id) }
            }
            .fixedSize()
            ElapsedText(since: request.arrived, spokenAs: String(localized: "Waiting"))
                .monospacedDigit()
                .foregroundStyle(.orange)
        }
        .font(.notchCaption)
        .foregroundStyle(.secondary)
        .frame(height: 16)
    }
}

struct CodeBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) { content }
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.1)))
        // Commands, paths and code read left to right in every language.
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// A one-line text field that takes the keyboard while it shows; Return
/// sends, Escape cancels.
struct RequestTextField: View {
    let placeholder: String
    @Binding var text: String
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.notchBody)
            .lineLimit(1...2)
            .focused($focused)
            .onSubmit(submit)
            .onExitCommand(perform: cancel)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.notchAccent.opacity(0.7)))
            .background(NotchTextInputFocus(active: true))
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}
