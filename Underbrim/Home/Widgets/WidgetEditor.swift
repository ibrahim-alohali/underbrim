//
//  WidgetEditor.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Home in edit mode, inside the notch: every widget as a tile, those on Home first. Tap to add or
//  remove, drag to reorder, tap the size to cycle it. Done or Escape goes back.
//

import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct WidgetEditor: View {
    nonisolated static let tileWidth: CGFloat = 74
    nonisolated static let spacing: CGFloat = 10
    nonisolated static let contentWidth = CGFloat(HomeWidget.allCases.count) * (tileWidth + spacing) + 1

    /// Its own copy of the order, written through as it changes: a reorder then slides (the
    /// setting's own updates arrive a moment after the change, outside its animation).
    @State private var shownOrder = Defaults[.homeWidgetOrder]
    private var order: [HomeWidget] {
        get { shownOrder }
        nonmutating set { shownOrder = newValue; Defaults[.homeWidgetOrder] = newValue }
    }
    @Default(.homeWidgetSizes) private var sizes
    @State private var on = Set(HomeWidget.enabled)
    @State private var dragged: HomeWidget?
    @ObservedObject private var coordinator = NotchViewCoordinator.shared
    @EnvironmentObject private var vm: NotchViewModel
    /// False without one: the mirror can't go on Home (Settings greys it out too).
    let camera: Bool
    private var limit: CGFloat { HomeWidget.room }

    var body: some View {
        let all = HomeWidget.ordered(order)
        let placed = all.filter(on.contains)
        let available = all.filter { !on.contains($0) }
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(placed) { tile($0, placed: true) }
                if !placed.isEmpty && !available.isEmpty {
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 64).padding(.top, 2)
                }
                ForEach(available) { tile($0, placed: false) }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            // A drag that ended outside a tile sends no drop; once the button is up, it's over.
            .onContinuousHover { _ in
                if dragged != nil, NSEvent.pressedMouseButtons == 0 { dragged = nil }
            }
        }
        .scrollIndicators(.never)
        .scrollsBeforePages()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Edit Widgets"))
        // A switch flipped or the order changed meanwhile elsewhere (this editor's own changes are
        // written as they're made).
        .task {
            for await _ in Defaults.updates(HomeWidget.layoutKeys, initial: false) {
                on = Set(HomeWidget.enabled)
                let saved = Defaults[.homeWidgetOrder]
                if saved != shownOrder { withAnimation(.snappy(duration: 0.2)) { shownOrder = saved } }
            }
        }
        // Closing the notch or leaving Home ends editing, once the pointer has had its moment to
        // catch the close by coming straight back: the island then reopens on the editor.
        .onDisappear {
            let vm = vm, coordinator = coordinator
            Task {
                try? await Task.sleep(for: .seconds(ContentView.catchWindow))
                if vm.notchState == .closed || coordinator.currentView != .home { coordinator.editingWidgets = false }
            }
        }
    }

    private func tile(_ widget: HomeWidget, placed: Bool) -> some View {
        let others = HomeWidget.ordered(order).filter { on.contains($0) && $0 != widget }
        return WidgetTile(
            widget: widget,
            placed: placed,
            refusal: placed ? nil
                : widget == .mirror && !camera ? String(localized: "No Camera")
                : HomeWidget.fit(others + [widget], within: limit) ? nil : HomeWidget.noRoom,
            size: placed && !widget.sizes.isEmpty ? widget.size : nil,
            resizable: widget.nextSize(beside: others, within: limit) != widget.size,
            toggle: { toggle(widget) },
            cycleSize: { sizes[widget.rawValue] = widget.nextSize(beside: others, within: limit) },
            move: placed ? { move(widget, by: $0) } : nil
        )
        .opacity(dragged == widget ? 0.4 : 1)
        .onDrag {
            dragged = widget
            return NSItemProvider(object: widget.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: TileDrop(target: widget, placed: placed, dragged: $dragged) { moved in
            withAnimation(.snappy(duration: 0.2)) { order = HomeWidget.moving(moved, to: widget, in: HomeWidget.ordered(order)) }
        })
    }

    private func toggle(_ widget: HomeWidget) {
        // A tile moves when added, so a double-click's second click would take it off again.
        guard !NSEvent.isSecondClick else { return }
        withAnimation(.snappy(duration: 0.2)) {
            if on.contains(widget) {
                on.remove(widget)
            } else {
                guard HomeWidget.fit(HomeWidget.ordered(order).filter(on.contains) + [widget], within: limit) else { return }
                order = HomeWidget.adding(widget, to: HomeWidget.ordered(order), after: on)
                on.insert(widget)
            }
        }
        Defaults[widget.enabledKey] = on.contains(widget)
    }

    private func move(_ widget: HomeWidget, by offset: Int) {
        let all = HomeWidget.ordered(order)
        let placed = all.filter(on.contains)
        guard let index = placed.firstIndex(of: widget), placed.indices.contains(index + offset) else { return }
        order = HomeWidget.moving(widget, to: placed[index + offset], in: all)
    }
}

private struct TileDrop: DropDelegate {
    let target: HomeWidget
    let placed: Bool
    @Binding var dragged: HomeWidget?
    let move: (HomeWidget) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragged != nil && placed && NSEvent.pressedMouseButtons != 0 }

    func dropEntered(info: DropInfo) {
        guard placed, let dragged, dragged != target, Defaults[dragged.enabledKey] else { return }
        move(dragged)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

private struct WidgetTile: View {
    let widget: HomeWidget
    let placed: Bool
    let refusal: String?
    private var fits: Bool { refusal == nil }
    let size: WidgetSize?
    let resizable: Bool
    let toggle: () -> Void
    let cycleSize: () -> Void
    let move: ((Int) -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Button(action: toggle) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(placed ? 0.16 : 0.08))
                    .frame(width: 62, height: 46)
                    .overlay {
                        Image(systemName: widget.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(placed ? 0.95 : 0.65))
                    }
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: placed ? "minus.circle.fill" : "plus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(placed || !fits ? Color.white : Color.onNotchAccent,
                                             placed || !fits ? Color(white: 0.45) : Color.notchAccent)
                            .font(.system(size: 15))
                            .offset(x: 5, y: -5)
                    }
                    .brightness(hovering ? 0.06 : 0)
            }
            .buttonStyle(.plain)
            .notchDisabled(!fits)
            .onHover { hovering = $0 }
            .help(placed ? String(localized: "Remove \(widget.title) from Home")
                  : refusal ?? String(localized: "Add \(widget.title) to Home"))
            .accessibilityLabel(widget.title)
            .accessibilityValue(placed ? String(localized: "On Home") : String(localized: "Not on Home"))
            .accessibilityHint(placed ? String(localized: "Removes it from Home")
                               : refusal ?? String(localized: "Adds it to Home"))
            .accessibilityActions {
                if let move {
                    Button(String(localized: "Move Left")) { move(-1) }
                    Button(String(localized: "Move Right")) { move(1) }
                }
            }

            Text(widget.title)
                .font(.notchCaption)
                .foregroundStyle(.white.opacity(placed ? 0.95 : fits ? 0.7 : 0.4))
                .lineLimit(1)
                // Some languages' names ("Быстрый запуск") are wider than the tile.
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)

            if let size {
                Button(action: cycleSize) {
                    Text(size.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .notchDisabled(!resizable)
                .help(resizable ? String(localized: "Change the size") : String(localized: "No room for another size"))
                .accessibilityLabel(String(localized: "\(widget.title) size"))
                .accessibilityValue(size.title)
                .accessibilityHint(resizable ? String(localized: "Switches between Small, Medium and Large")
                                   : String(localized: "No room for another size"))
            }
        }
        .frame(width: WidgetEditor.tileWidth)
    }
}
