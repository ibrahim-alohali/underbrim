//
//  WidgetsIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings island on Widgets: Home's widgets, to turn on, off and reorder.
//

import Defaults
import SwiftUI

struct WidgetsIsland: View {
    let camera: CameraModel
    @Default(.homeWidgetOrder) private var order
    /// Bumped when Home's widgets change (a switch, the order or a size).
    @State private var switches = 0
    @State private var dragging: (widget: HomeWidget, moved: Int)?
    @State private var dragOffset: CGFloat = 0
    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slot: CGFloat = 42

    var body: some View {
        let _ = switches
        let widgets = HomeWidget.ordered(order).filter { Defaults[$0.enabledKey] }
        let addable = HomeWidget.ordered(order).filter { !Defaults[$0.enabledKey] }
        // Six fit the island; the sixth gives way to + while one could be added.
        let plus = !addable.isEmpty && widgets.count < 6
        let shown = Array(widgets.prefix(plus ? 5 : 6))
        HStack(spacing: 8) {
            if widgets.isEmpty {
                Text("Home is empty").islandText(dim: true)
            }
            ForEach(shown) { widget in
                let lifted = dragging?.widget == widget
                WidgetIcon(widget: widget, lifted: lifted) { translation in
                    dragged(widget, by: translation, among: shown)
                } dropped: {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dragging = nil; dragOffset = 0 }
                }
                    .offset(x: lifted ? dragOffset : 0)
                    .zIndex(lifted ? 1 : 0)
                    // The dragged one stays under the pointer as the others slide.
                    .transaction { if lifted { $0.animation = nil } }
            }
            if plus {
                AddWidgetButton(addable: addable, camera: camera.cameraAvailable, order: $order)
            }
        }
        .task {
            for await _ in Defaults.updates(HomeWidget.layoutKeys, initial: false) { switches += 1 }
        }
    }

    private func dragged(_ widget: HomeWidget, by translation: CGFloat, among shown: [HomeWidget]) {
        let sign: CGFloat = direction == .rightToLeft ? -1 : 1
        var moved = dragging?.widget == widget ? dragging?.moved ?? 0 : 0
        let wanted = Int((translation * sign / Self.slot).rounded())
        if wanted != moved, let index = shown.firstIndex(of: widget) {
            let target = min(max(index + wanted - moved, 0), shown.count - 1)
            if target != index {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    order = HomeWidget.moving(widget, to: shown[target], in: HomeWidget.ordered(order))
                }
                moved += target - index
            }
        }
        dragging = (widget, moved)
        dragOffset = translation - CGFloat(moved) * Self.slot * sign
    }
}

/// Not a Button: pressing and dragging a button moves the window instead. A press that doesn't move
/// (or Space, Return, VoiceOver) offers "Remove from Home"; one that moves drags the icon along the row.
private struct WidgetIcon: View {
    let widget: HomeWidget
    var lifted = false
    let drag: (CGFloat) -> Void
    let dropped: () -> Void
    @State private var frame = CGRect.zero
    @State private var pulled = false
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        Image(systemName: widget.symbol)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color(white: lifted ? 0.2 : 0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .modifier(IslandHighlight(pressed: lifted, radius: 11))
            .settingsIslandFrame($frame)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { press in
                        if pulled || hypot(press.translation.width, press.translation.height) > 3 {
                            pulled = true
                            drag(press.translation.width)
                        }
                    }
                    .onEnded { _ in
                        pulled ? dropped() : showMenu()
                        pulled = false
                    }
            )
            .holdsSettingsWindow()
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                showMenu()
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(widget.title)
            .accessibilityAction { showMenu() }
            .accessibilityAction(named: Text("Remove from Home")) { Defaults[widget.enabledKey] = false }
            .help(islandHelp(widget.title, String(localized: "Drag to reorder")))
    }

    private func showMenu() {
        let menu = IslandMenu()
        menu.add(String(localized: "Remove from Home")) { Defaults[widget.enabledKey] = false }
        menu.show(under: frame, rightToLeft: direction == .rightToLeft)
    }
}

private struct AddWidgetButton: View {
    let addable: [HomeWidget]
    let camera: Bool
    @Binding var order: [HomeWidget]
    @State private var frame = CGRect.zero
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        Button {
            let menu = IslandMenu()
            for widget in addable {
                let refusal = widget == .mirror && !camera ? String(localized: "No Camera")
                    : HomeWidget.canTurnOn(widget) ? nil : HomeWidget.noRoom
                menu.add(widget.title, enabled: refusal == nil, help: refusal) {
                    order = HomeWidget.adding(widget, to: HomeWidget.ordered(order), after: Set(HomeWidget.enabled))
                    Defaults[widget.enabledKey] = true
                }
            }
            menu.show(under: frame, rightToLeft: direction == .rightToLeft)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 34, height: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(radius: 11))
        .settingsIslandFrame($frame)
        .help(String(localized: "Add to Home"))
        .accessibilityLabel(String(localized: "Add to Home"))
    }
}
