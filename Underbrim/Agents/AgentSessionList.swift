//
//  AgentSessionList.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Agents tab's live sessions, grouped by what they need from you.
//

import SwiftUI

/// Sessions one to a line under what they need from you, in the store's order (newest first). It
/// grows with its lines to `listCap`, then scrolls. While the pointer is over it every line keeps its
/// group and place, so a click lands where it was aimed; they settle once it leaves. Lines come and go
/// on the island's own spring, so the outline moves with them.
struct AgentSessionList: View {
    let sessions: [AgentSession]
    let quiet: Set<String>
    /// Sessions whose question under a reply waits on the user.
    var asking: Set<String> = []
    /// Each group's name beside its symbol; compact mode's narrow island leaves the room to the titles.
    var namesGroups = true
    /// The list grows to this, then scrolls.
    var cap = AgentsTabContent.listCap

    struct Lines: Equatable {
        var group: AgentSessionGroup
        var ids: [String]
    }
    struct Place {
        var group: AgentSessionGroup
        var rank: Int
    }

    /// The lines as shown: they follow the sessions on the island's spring.
    @State private var shown: [Lines]
    /// Each line's group and place while the pointer is over the list.
    @State private var held: [String: Place]?
    @State private var pointer = IslandPointerWatch()
    /// Where each line is in the list, and the one the pointer is on (its actions show).
    @State private var lineFrames: [String: CGRect] = [:]
    @State private var hovered: String?

    static let separator: CGFloat = 7
    private static let space = "agentSessionList"

    init(sessions: [AgentSession], quiet: Set<String>, asking: Set<String> = [], namesGroups: Bool = true,
         cap: CGFloat = AgentsTabContent.listCap) {
        self.sessions = sessions
        self.quiet = quiet
        self.asking = asking
        self.namesGroups = namesGroups
        self.cap = cap
        _shown = State(initialValue: Self.arrange(sessions, quiet: quiet, asking: asking, held: nil))
    }

    /// A row of the list: a session's line (the first of its group with the group's name beside it), or
    /// the rule between two groups.
    enum Row: Identifiable {
        case rule(AgentSessionGroup)
        case line(String, named: AgentSessionGroup?)

        var id: String {
            switch self {
            case .rule(let group): "rule \(group.rawValue)"
            case .line(let id, _): id
            }
        }
    }

    /// Held lines keep their place; a session new meanwhile goes to the end of its group.
    static func arrange(_ sessions: [AgentSession], quiet: Set<String>, asking: Set<String>, held: [String: Place]?) -> [Lines] {
        let placed = sessions.enumerated().map { index, session in
            (id: session.id, place: held?[session.id] ?? Place(group: AgentSessionGroup(session, quiet: quiet.contains(session.id),
                                                                                        asking: asking.contains(session.id)),
                                                               rank: (held?.count ?? 0) + index))
        }
        return AgentSessionGroup.allCases.compactMap { group in
            let ids = placed.filter { $0.place.group == group }.sorted { $0.place.rank < $1.place.rank }.map(\.id)
            return ids.isEmpty ? nil : Lines(group: group, ids: ids)
        }
    }

    /// One list of rows, so a line that changes group keeps its identity and slides to its new place.
    static func rows(_ shown: [Lines]) -> [Row] {
        shown.enumerated().flatMap { index, lines in
            (index > 0 ? [Row.rule(lines.group)] : [])
                + lines.ids.enumerated().map { Row.line($1, named: $0 == 0 ? lines.group : nil) }
        }
    }

    var body: some View {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let count = shown.reduce(0) { $0 + $1.ids.count }
        let natural = CGFloat(count) * AgentsTabContent.lineHeight + CGFloat(max(0, shown.count - 1)) * Self.separator
        let canClear = sessions.contains(where: \.isSettled)
        // One container, so its window reader and pointer watch stay as the empty state gives way to lines.
        ZStack {
            Group {
                if shown.isEmpty {
                    AgentEmptyState()
                } else {
                    ScrollView(.vertical) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                            ForEach(Self.rows(shown)) { row in
                                switch row {
                                case .rule:
                                    // Outside a grid row, it spans both columns.
                                    Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                                        .padding(.vertical, (Self.separator - 1) / 2)
                                        .transition(.opacity)
                                case .line(let id, let named):
                                    GridRow {
                                        // The name moves from line to line at once, so it stays put while lines slide.
                                        Group {
                                            if let named {
                                                AgentGroupLabel(group: named, showsTitle: namesGroups)
                                            } else {
                                                Color.clear.frame(width: 0)
                                            }
                                        }
                                        .frame(height: AgentsTabContent.lineHeight)
                                        .transaction { $0.animation = nil }
                                        Group {
                                            if let session = byID[id] {
                                                AgentSessionRow(session: session, quiet: quiet.contains(session.id),
                                                                asking: asking.contains(session.id), canClear: canClear,
                                                                hovering: hovered == session.id)
                                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                                                        lineFrames[id] = frame
                                                    }
                                            } else {
                                                Color.clear
                                            }
                                        }
                                        .frame(height: AgentsTabContent.lineHeight)
                                        // The line moves as one, so new words for it change on the line
                                        // instead of fading in where it ends up.
                                        .geometryGroup()
                                        // On the island's black, so a line sliding past another hides it instead of mixing.
                                        .background(.black)
                                        .transition(.opacity)
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(natural, cap))
                    .modifier(ListEdgeFade(overflows: natural > cap))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Coding sessions"))
        }
        .coordinateSpace(.named(Self.space))
        // As for the island: onHover alone misses moves in its panel, so the pointer watch decides.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            pointer.islandFrame = frame
            pointer.update()
        }
        .onHover { _ in pointer.update() }
        .background(WindowReader { pointer.window = $0 })
        .onChange(of: Self.arrange(sessions, quiet: quiet, asking: asking, held: held)) {
            // The pointer coming onto the list can go unseen, so where it is now decides before anything moves.
            pointer.update()
            let now = Self.arrange(sessions, quiet: quiet, asking: asking, held: held)
            withAnimation(StandardAnimations.open) { shown = now }
        }
        .onAppear {
            pointer.start(contains: { point in
                let inside = CGRect(origin: .zero, size: pointer.islandFrame.size).contains(point)
                let line = inside ? lineFrames.first { $0.value.contains(point) }?.key : nil
                if line != hovered { hovered = line }
                return inside
            }, onChange: hold)
            DevServerStore.shared.watch(true)
        }
        .onDisappear {
            pointer.stop()
            held = nil
            hovered = nil
            DevServerStore.shared.watch(false)
        }
    }

    private func hold(_ inside: Bool) {
        guard inside else { return held = nil }
        guard held == nil else { return }
        let lines = shown.flatMap { lines in lines.ids.map { (id: $0, group: lines.group) } }
        held = Dictionary(lines.enumerated().map { ($1.id, Place(group: $1.group, rank: $0)) }, uniquingKeysWith: { first, _ in first })
    }
}

private struct AgentGroupLabel: View {
    let group: AgentSessionGroup
    /// Without it, the name is in the symbol's help.
    var showsTitle = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: group.symbol)
                .font(.notchSymbol(size: 10))
            if showsTitle {
                Text(group.title)
                    .lineLimit(1)
            }
        }
        .font(.notchCaption.weight(.semibold))
        .foregroundStyle(group.tint)
        .padding(.leading, 4)
        .help(showsTitle ? "" : group.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(group.title))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Fades a list's top or bottom edge where more of it is scrolled out of sight, as the Scratchpad's
/// note does. Before macOS 15, which can't say where a list is scrolled, the bottom while it overflows.
struct ListEdgeFade: ViewModifier {
    let overflows: Bool
    @State private var hidden = HiddenEdges(above: false, below: true)

    struct HiddenEdges: Equatable {
        var above: Bool
        var below: Bool
    }

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 15, *) {
                content.onScrollGeometryChange(for: HiddenEdges.self) { geometry in
                    HiddenEdges(above: geometry.visibleRect.minY > 1,
                                below: geometry.contentSize.height - geometry.visibleRect.maxY > 1)
                } action: { _, now in
                    hidden = now
                }
            } else {
                content
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [overflows && hidden.above ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 10)
                Color.black
                LinearGradient(colors: [.black, overflows && hidden.below ? .clear : .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
            }
        }
    }
}
