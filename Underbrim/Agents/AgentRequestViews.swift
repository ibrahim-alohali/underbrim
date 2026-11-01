//
//  AgentRequestViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Agents tab while an agent waits on the user: one request at a time, oldest
//  first. The keyboard is taken only while a reason or an answer is typed.
//

import SwiftUI

struct AgentRequestsRow: View {
    let requests: [AgentRequest]
    /// The tallest a question may be, its options scrolling past it.
    var questionHeight: CGFloat = 300
    @State private var shownID: String?

    private var shown: AgentRequest? {
        requests.first { $0.id == shownID } ?? requests.first
    }

    var body: some View {
        if let shown {
            let position = (requests.firstIndex(of: shown) ?? 0) + 1
            let queue = requests.count > 1 ? RequestQueue(position: position, count: requests.count) { step in
                let index = min(max(position - 1 + step, 0), requests.count - 1)
                withAnimation(.smooth(duration: 0.25)) { shownID = requests[index].id }
            } : nil
            Group {
                switch shown.body.payload {
                case .permission(let action, let suggestions):
                    PermissionRequestCard(request: shown, action: action, suggestions: suggestions, queue: queue,
                                          shownPermissions: requests.filter { $0.kind == .permission }.map(\.id))
                        .frame(height: NotchMetrics.tabHeight)
                // As tall as the questions need, as on the island.
                case .question(let asked): QuestionCard(ask: .request(shown), questions: asked, maxHeight: questionHeight, queue: queue)
                case .plan(let plan):
                    PlanRequestCard(request: shown, plan: plan, queue: queue)
                        .frame(height: NotchMetrics.tabHeight)
                }
            }
            // A new request starts with fresh state (a half-typed reason stays with its own).
            .id(shown.id)
            .transition(.opacity)
        }
    }
}

struct RequestQueue {
    let position: Int
    let count: Int
    let step: (Int) -> Void
}
