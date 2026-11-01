//
//  HomeWidgetKeys.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Keys Home's widgets work while the notch has the keyboard (opened with its shortcut). Each widget's
//  model registers its own; the notch window asks them for each key a text field doesn't get.
//

import AppKit

@MainActor
enum HomeWidgetKeys {
    /// Works a key; true when the widget took it.
    typealias Handler = @MainActor (_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool

    private static var handlers: [HomeWidget: Handler] = [:]
    private static var typing: [HomeWidget: @MainActor () -> Bool] = [:]

    /// `handle` works the widget's keys. `typing` says it's about to take the keyboard for text:
    /// until it has, no widget takes a key.
    static func register(_ widget: HomeWidget, typing: (@MainActor () -> Bool)? = nil, handle: Handler? = nil) {
        handlers[widget] = handle
        self.typing[widget] = typing
    }

    /// Whether a widget took the key, asked in the widgets' own order.
    static func handle(_ key: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !typing.values.contains(where: { $0() }) else { return false }
        return HomeWidget.allCases.contains { handlers[$0]?(key, modifiers) == true }
    }
}
