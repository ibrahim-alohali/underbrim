//
//  PlanRequestCard.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A plan to approve, or to send back with what to change.
//

import SwiftUI

struct PlanRequestCard: View {
    let request: AgentRequest
    let plan: RelayPlan
    let queue: RequestQueue?
    @EnvironmentObject private var quickLook: QuickLookService
    @State private var revising = false
    @State private var feedback = ""

    /// Its text; a plan that's only a file shows its heading and "Show Full Plan".
    private var planText: String { plan.text ?? "" }

    private var title: String {
        let lines = planText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let heading = lines.first { $0.hasPrefix("#") } ?? lines.first ?? String(localized: "Plan")
        return heading.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    }

    private var outline: String {
        planText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) != title }
            .prefix(8)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> ")) }
            .joined(separator: "  ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                RequestHeader(request: request, title: AgentSession.Attention.plan.words, queue: queue,
                              trailing: plan.file.map { path in
                                  AnyView(NotchTextButton(title: String(localized: "Show Full Plan")) {
                                      quickLook.show(urls: [URL(fileURLWithPath: path)])
                                  })
                              })
                Text(verbatim: title)
                    .font(.notchTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if revising {
                    RequestTextField(placeholder: String(localized: "What should change?"), text: $feedback,
                                     submit: keepPlanning, cancel: { revising = false })
                } else {
                    Text(verbatim: outline)
                        .font(.notchBody)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 3) {
                if revising {
                    Button(String(localized: "Send"), action: keepPlanning)
                        .buttonStyle(RequestButtonStyle(role: .primary))
                    Button(String(localized: "Cancel")) { revising = false }
                        .buttonStyle(RequestButtonStyle())
                } else {
                    Button(String(localized: "Approve")) {
                        withAnimation(StandardAnimations.open) { AgentRequestStore.shared.approvePlan(request.id, acceptEdits: false) }
                    }
                    .buttonStyle(RequestButtonStyle(role: .primary))
                    .help(String(localized: "\(request.provider.displayName) still asks before each edit"))
                    Button(String(localized: "Approve, Accept Edits")) {
                        withAnimation(StandardAnimations.open) { AgentRequestStore.shared.approvePlan(request.id, acceptEdits: true) }
                    }
                    .buttonStyle(RequestButtonStyle())
                    .help(String(localized: "File edits go ahead without asking for the rest of this session"))
                    Button(String(localized: "Keep Planning…")) { revising = true }
                        .buttonStyle(RequestButtonStyle())
                }
            }
            .frame(width: 168)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Plan ready: \(title)"))
    }

    private func keepPlanning() {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(StandardAnimations.open) {
            AgentRequestStore.shared.deny(request.id, message: text.isEmpty ? "Keep planning." : text)
        }
    }
}
