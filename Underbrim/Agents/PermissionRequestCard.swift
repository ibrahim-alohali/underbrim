//
//  PermissionRequestCard.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  An approval: the command or change asked about, and the rules the agent suggests.
//

import SwiftUI

struct PermissionRequestCard: View {
    let request: AgentRequest
    let action: RelayAction
    /// The permission changes the agent offered with it.
    let suggestions: [RelaySuggestion]
    let queue: RequestQueue?
    /// The approvals shown with it, which its Allow All allows.
    var shownPermissions: [String] = []
    @State private var denying = false
    @State private var reason = ""

    private var store: AgentRequestStore { .shared }

    /// The first change the agent offered that grants something: what Always Allow saves.
    private var always: RelaySuggestion? {
        suggestions.first { suggestion in
            switch suggestion.type {
            case "addRules": suggestion.behavior == "allow"
            case "setMode": suggestion.mode == "acceptEdits"
            case "addDirectories": true
            default: false
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                RequestHeader(request: request, title: request.provider.displayName, queue: queue)
                Text(question)
                    .font(.notchTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(action.target ?? question)
                if denying {
                    RequestTextField(placeholder: String(localized: "Tell \(request.provider.appName) why, or what to do instead (optional)"),
                                     text: $reason, submit: deny, cancel: { denying = false })
                } else {
                    details
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 3) {
                if denying {
                    Button(String(localized: "Deny"), action: deny)
                        .buttonStyle(RequestButtonStyle(role: .primary))
                    Button(String(localized: "Cancel")) { denying = false }
                        .buttonStyle(RequestButtonStyle())
                } else {
                    Button(String(localized: "Allow Once")) { withAnimation(StandardAnimations.open) { store.allow(request.id) } }
                        .buttonStyle(RequestButtonStyle(role: .primary))
                    if let always {
                        Button {
                            withAnimation(StandardAnimations.open) { store.allow(request.id, suggestion: always.index) }
                        } label: {
                            Text(String(localized: "Always Allow \(Self.label(for: always))"))
                                .truncationMode(.middle)
                        }
                        .buttonStyle(RequestButtonStyle())
                        .help(Self.help(for: always, provider: request.provider))
                    }
                    Button(String(localized: "Deny…")) { denying = true }
                        .buttonStyle(RequestButtonStyle())
                }
                Spacer(minLength: 0)
                if shownPermissions.count > 1, !denying { AllowAllButton(ids: shownPermissions) }
            }
            .frame(width: 168)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "\(request.provider.displayName) asks: \(question)"))
    }

    /// What it asks, in words: "Run this command?", "Edit AgentViews.swift?"…
    private var question: String {
        let file = action.target.map { ($0 as NSString).lastPathComponent }
        switch action.kind {
        case .command: return String(localized: "Run this command?")
        case .edit: return file.map { String(localized: "Edit \($0)?") } ?? String(localized: "Edit this file?")
        case .write: return file.map { String(localized: "Create \($0)?") } ?? String(localized: "Write this file?")
        case .fetch: return String(localized: "Open this web address?")
        case .search: return String(localized: "Search the web?")
        case .read: return file.map { String(localized: "Read \($0)?") } ?? String(localized: "Read these files?")
        case .agent: return String(localized: "Start a subagent?")
        case .mcp, .other:
            return String(localized: "Use \(Self.toolName(request.body.tool))?")
        }
    }

    @ViewBuilder private var details: some View {
        if let diff = action.diff {
            CodeBox {
                ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: (line.added ? "+ " : "- ") + line.text)
                        .foregroundStyle(line.added ? Color(red: 0.49, green: 0.89, blue: 0.66) : Color(red: 1, green: 0.61, blue: 0.57))
                        .lineLimit(1)
                }
            }
        } else if let body = action.body ?? action.target {
            CodeBox { Text(verbatim: body).foregroundStyle(.white) }
        } else if let summary = action.summary {
            Text(summary).font(.notchBody).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func deny() {
        withAnimation(StandardAnimations.open) { store.deny(request.id, message: reason) }
    }

    /// As the session's line names it: "mcp__github__create_issue" → "create issue (github)".
    static func toolName(_ tool: String?) -> String {
        tool.map(AgentToolName.readable) ?? String(localized: "this tool")
    }

    /// The rule Always Allow saves, short: "npm test …", "example.com", "all edits".
    static func label(for suggestion: RelaySuggestion) -> String {
        switch suggestion.type {
        case "setMode": return String(localized: "Edits")
        case "addDirectories":
            return suggestion.directories?.first.map { ($0 as NSString).lastPathComponent } ?? String(localized: "This Folder")
        default:
            let rules = (suggestion.rules ?? []).map { rule -> String in
                guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")") else { return rule }
                var content = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
                if content.hasPrefix("domain:") { content.removeFirst("domain:".count) }
                if content.hasSuffix(":*") { content = String(content.dropLast(2)) + " …" }
                return content
            }
            return rules.joined(separator: ", ")
        }
    }

    /// Where it's saved and for how long, in the agent's own folder (Qoder keeps rules in .qoder,
    /// as Claude Code in .claude).
    static func help(for suggestion: RelaySuggestion, provider: AgentProvider) -> String {
        let rules = (suggestion.rules ?? []).joined(separator: ", ")
        let place: String = switch suggestion.destination {
        case "session": String(localized: "For the rest of this session")
        case "projectSettings": String(localized: "Saved in this project's .claude/settings.json")
        case "userSettings": String(localized: "Saved for all projects in ~/.claude/settings.json")
        default: String(localized: "Saved for this project on this Mac (.claude/settings.local.json)")
        }
        let saved = provider.spec.rulesFolder.map { place.replacingOccurrences(of: ".claude/", with: "\($0)/") } ?? place
        return rules.isEmpty ? saved : "\(rules)\n\(saved)"
    }
}

/// Red with a warning sign: it approves calls not looked at.
private struct AllowAllButton: View {
    let ids: [String]

    var body: some View {
        Button {
            withAnimation(StandardAnimations.open) { AgentRequestStore.shared.allowAll(ids) }
        } label: {
            Label(String(localized: "Allow All \(ids.count)"), systemImage: "exclamationmark.triangle.fill")
        }
        .buttonStyle(RequestButtonStyle(role: .warning))
        .help(String(localized: "Allows every tool request waiting now, including ones you haven't looked at"))
    }
}
