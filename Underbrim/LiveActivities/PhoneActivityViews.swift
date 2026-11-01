//
//  PhoneActivityViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  An iPhone Live Activity in the notch: closed, its symbol and short value beside the camera; open,
//  a card with everything it says.
//

import Defaults
import SwiftUI

/// The app's symbol on its colour: macOS shares no logo, only text.
struct ActivityBadge: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint == .white ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }
}

extension PhoneActivity {
    var spokenDescription: String {
        [String(localized: "Live Activity"), app, text].compactMap { $0 }.joined(separator: ", ")
    }
}

struct PhoneActivityLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let activity: PhoneActivity

    private var itemSize: CGFloat { vm.closedItemSize }
    static let extraWidth: CGFloat = 18

    var body: some View {
        HStack {
            ActivityBadge(symbol: activity.symbol, tint: activity.tint, size: itemSize)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            Text(activity.value ?? "")
                .font(.notchCaption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: itemSize + Self.extraWidth, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.spokenDescription)
    }
}

/// Opened from an activity: one card each, two side by side at most; a call alone is one row.
struct PhoneActivitiesExpandedView: View {
    private var store: PhoneActivityStore { .shared }
    private var deliveries: DeliveryTracker { .shared }

    /// Only a call to show: the page is its row (compact mode shows nothing beside a call).
    @MainActor static var callOnly: Bool {
        CallActivity.shared.call != nil && (Defaults[.compactMode] || PhoneActivityStore.shared.activities.isEmpty
            && DeliveryTracker.shared.orders(besides: PhoneActivityStore.shared.activities).isEmpty)
    }

    var body: some View {
        let orders = deliveries.orders(besides: store.activities)
        let call = CallActivity.shared.call
        let room = (Defaults[.compactMode] ? 1 : 2) - (call != nil ? 1 : 0)
        let empty = store.activities.isEmpty && orders.isEmpty && call == nil
        HStack(spacing: NotchMetrics.cardSpacing) {
            if empty {
                Text("No Live Activities right now")
                    .font(.notchBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // A call first: beside another card, at that card's height.
            if let call {
                CallRow(call: call)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(store.activities.prefix(room)) { activity in
                PhoneActivityCard(activity: activity)
            }
            ForEach(orders.prefix(max(0, room - store.activities.count))) { order in
                DeliveryCard(order: order)
            }
        }
        .frame(height: Self.callOnly ? CallRow.height : NotchMetrics.tabHeight)
        // Nothing left: Home, not an empty page grown from the call's row.
        .onChange(of: empty) { _, empty in
            if empty { withAnimation(StandardAnimations.open) { NotchViewCoordinator.shared.currentView = .home } }
        }
    }
}

// MARK: - Deliveries from notifications

extension DeliveryTracker.Order {
    var look: (symbol: String, tint: Color) {
        PhoneActivityCatalog.app(named: app).map { ($0.symbol, $0.tint) } ?? (PhoneActivityCatalog.delivery, .green)
    }

    func spokenDescription(at now: Date) -> String {
        let left = minutesLeft(at: now).map { String(localized: "about \($0) minutes") }
        return [app, latest, finished ? String(localized: "finished") : left].compactMap { $0 }.joined(separator: ", ")
    }
}

extension DeliveryTracker {
    /// Orders without a Live Activity of their own showing (the app can send both).
    func orders(besides activities: [PhoneActivity]) -> [Order] {
        orders.filter { order in !activities.contains { $0.app == order.app } }
    }
}

struct DeliveryLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let order: DeliveryTracker.Order

    private var itemSize: CGFloat { vm.closedItemSize }

    var body: some View {
        HStack {
            ActivityBadge(symbol: order.look.symbol, tint: order.look.tint, size: itemSize)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Group {
                    if order.finished {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(order.look.tint)
                    } else {
                        Text(order.minutesLeft(at: context.date).map { String(localized: "\($0) min") } ?? "")
                    }
                }
                .font(.notchCaption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(order.spokenDescription(at: context.date))
            }
            .frame(width: itemSize + PhoneActivityLiveActivity.extraWidth, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

struct DeliveryCard: View {
    let order: DeliveryTracker.Order

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityBadge(symbol: order.look.symbol, tint: order.look.tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(order.app).font(.notchCaption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(Array(order.steps.suffix(3).enumerated()), id: \.offset) { index, step in
                    let latest = index == min(order.steps.count, 3) - 1
                    HStack(spacing: 6) {
                        Text(step.at, format: .dateTime.hour().minute())
                            .font(.notchCaption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(step.text)
                            .font(latest ? .notchBody.weight(.semibold) : .notchBody)
                            .foregroundStyle(latest ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if order.finished {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(order.look.tint)
                    } else if let left = order.minutesLeft(at: context.date) {
                        Text(String(localized: "\(left) min"))
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                Spacer(minLength: 0)
                NotchTextButton(title: String(localized: "Dismiss"), help: String(localized: "Stops following this order")) {
                    DeliveryTracker.shared.dismiss(order)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(order.spokenDescription(at: .now))
    }
}

struct PhoneActivityCard: View {
    let activity: PhoneActivity
    private var store: PhoneActivityStore { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityBadge(symbol: activity.symbol, tint: activity.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                let rest = activity.textWithoutValue
                if let app = activity.app, rest != nil {
                    Text(app).font(.notchCaption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(rest ?? activity.app ?? String(localized: "Live Activity"))
                    .font(.notchTitle)
                    .lineLimit(activity.app == nil ? 3 : 2)
                Spacer(minLength: 0)
                HStack(spacing: 14) {
                    NotchTextButton(title: String(localized: "Full view"),
                                    help: String(localized: "Opens the app's own Live Activity from the menu bar")) {
                        store.open(activity)
                    }
                    NotchTextButton(title: String(localized: "Hide"),
                                    help: String(localized: "Hides it in the notch until it ends")) {
                        store.hide(activity)
                    }
                }
            }
            Spacer(minLength: 0)
            if let value = activity.value {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityHidden(true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(activity.spokenDescription)
    }
}
