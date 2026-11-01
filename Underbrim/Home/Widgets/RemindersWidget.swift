//
//  RemindersWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Open reminders, those due by today first. Reminders access is asked for only from this widget's button.
//

import EventKit
import SwiftUI

@MainActor
@Observable
final class RemindersModel {
    static let shared = RemindersModel()

    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let due: Date?
    }

    private(set) var status = EKEventStore.authorizationStatus(for: .reminder)
    private(set) var items: [Item] = []
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess else { return }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { RemindersModel.shared.reload() }
            }
        }
        reload()
    }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToReminders()
            refresh()
        }
    }

    private func reload() {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { reminders in
            let found = (reminders ?? []).map {
                Item(id: $0.calendarItemIdentifier, title: $0.title ?? "", due: $0.dueDateComponents?.date)
            }
            Task { @MainActor in RemindersModel.shared.items = Self.ordered(found) }
        }
    }

    /// Due ones first, soonest first; then the rest by title.
    nonisolated static func ordered(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): x != y ? x < y : a.title < b.title
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    func complete(_ item: Item) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return NSSound.beep() }
        reminder.isCompleted = true
        guard (try? store.save(reminder, commit: true)) != nil else { return NSSound.beep() }
        items.removeAll { $0.id == item.id }
    }

    func add(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard let list = store.defaultCalendarForNewReminders() else { return NSSound.beep() }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        // Gregorian, and saying so: a Hijri "current" calendar would give another day's numbers.
        reminder.dueDateComponents = Calendar(identifier: .gregorian).dateComponents([.calendar, .year, .month, .day], from: .now)
        if (try? store.save(reminder, commit: true)) == nil { NSSound.beep() }
        reload()
    }
}

struct RemindersWidget: View {
    @EnvironmentObject private var vm: NotchViewModel
    private let model = RemindersModel.shared
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    var alone = false

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        Group {
            if alone {
                aloneLayout
            } else {
                Group {
                    switch model.status {
                    case .fullAccess:
                        list
                    case .notDetermined:
                        prompt(String(localized: "See your reminders here"), button: String(localized: "Allow Reminders Access…")) {
                            model.requestAccess()
                        }
                    default:
                        prompt(String(localized: "Reminders access is off"), button: String(localized: "Open Privacy Settings…")) {
                            SystemSettings.open(.reminders)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(NotchTextInputFocus(active: adding))
        .onAppear { model.refresh() }
        .onChange(of: vm.notchState) { _, state in if state == .closed { adding = false } }
        .onDisappear { adding = false }
    }

    /// Alone: Reminders and how many more beside the camera, New Reminder on the other side, the first one under them.
    private var aloneLayout: some View {
        AloneFrame(widget: .reminders) {
            AloneTitle(symbol: HomeWidget.reminders.symbol, title: String(localized: "Reminders"))
            if model.status == .fullAccess, model.items.count > 1 {
                (Text(verbatim: "+") + Text(model.items.count - 1, format: .number))
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            if model.status == .fullAccess {
                NotchSymbolButton(symbol: "plus", label: String(localized: "New Reminder"), size: 11, box: 22) { startAdding() }
            }
        } row: {
            Group {
                switch model.status {
                case .fullAccess:
                    if adding {
                        newReminder
                    } else if let first = model.items.first {
                        row(first)
                    } else {
                        Text(String(localized: "Nothing to do")).font(.notchCaption).foregroundStyle(.secondary)
                    }
                case .notDetermined:
                    NotchTextButton(title: String(localized: "Allow Reminders Access…")) { model.requestAccess() }
                default:
                    HStack(spacing: 6) {
                        Text(String(localized: "Reminders access is off")).font(.notchCaption).foregroundStyle(.secondary)
                        NotchTextButton(title: String(localized: "Open Privacy Settings…")) { SystemSettings.open(.reminders) }
                    }
                }
            }
            .frame(minWidth: 0, idealWidth: HomeWidget.reminders.width(HomeWidget.reminders.size, height: 0), maxWidth: .infinity,
                   alignment: .leading)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(String(localized: "Reminders"), systemImage: "checklist").font(.notchCaption).foregroundStyle(.secondary)
                Spacer()
                NotchSymbolButton(symbol: "plus", label: String(localized: "New Reminder"), size: 11, box: 18) { startAdding() }
            }
            if adding {
                newReminder
            }
            if model.items.isEmpty && !adding {
                Text(String(localized: "Nothing to do")).font(.notchCaption).foregroundStyle(.secondary).padding(.top, 4)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.items) { row($0) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func row(_ item: RemindersModel.Item) -> some View {
        let overdue = item.due.map { $0 < Calendar.current.startOfDay(for: .now) } ?? false
        return HStack(spacing: 6) {
            Button { model.complete(item) } label: {
                Image(systemName: "circle").font(.notchSymbol(size: 12)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Mark as done"))
            .accessibilityLabel(String(localized: "Mark \(item.title) as done"))
            Text(item.title).font(.notchBody).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
            if let due = item.due {
                Text(overdue ? String(localized: "Overdue") : Calendar.current.isDateInToday(due) ? String(localized: "Today") : due.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.notchCaption)
                    .foregroundStyle(overdue ? .red : .secondary)
            }
        }
        .frame(height: 20)
    }

    private var newReminder: some View {
        TextField(String(localized: "New reminder, due today"), text: $draft)
            .textFieldStyle(.plain)
            .font(.notchBody)
            .focused($focused)
            .onSubmit {
                model.add(draft)
                draft = ""
                adding = false
            }
            .onExitCommand { adding = false }
            .padding(.horizontal, 4)
            .frame(height: 20)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func prompt(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(String(localized: "Reminders"), systemImage: "checklist").font(.notchCaption).foregroundStyle(.secondary)
            Text(text).font(.notchCaption).foregroundStyle(.secondary)
            NotchTextButton(title: button, action: action)
        }
        .padding(.top, 2)
    }

    private func startAdding() {
        adding = true
        DispatchQueue.main.async { focused = true }
    }
}
