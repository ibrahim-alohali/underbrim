//
//  TokenHistoryViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  An agent's tokens over two weeks in the Agents tab's row: a bar per day and today's
//  total split into fresh, written and cached reads, with the models used.
//

import SwiftUI

struct TokenHistoryRow: View {
    let provider: AgentProvider
    private let store = TokenHistoryStore.shared

    private var history: TokenHistoryStore.History? { store.history(for: provider) }

    var body: some View {
        Group {
            if let history, history.days.contains(where: { $0.tokens.total > 0 }) {
                content(history)
            } else if history == nil || store.reading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Adding up the tokens in \(provider.displayName)'s logs…")
                        .font(.notchCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No tokens in \(provider.displayName)'s logs in the last 14 days")
                    .font(.notchCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { store.refresh() }
    }

    private func content(_ history: TokenHistoryStore.History) -> some View {
        let today = history.days.last?.tokens ?? TokenDay()
        return HStack(alignment: .top, spacing: NotchMetrics.margin) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(provider.displayName) · last 14 days")
                    .font(.notchCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                TokenBars(days: history.days)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.notchCaption)
                    .foregroundStyle(.secondary)
                Text(Self.compact(today.total))
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text("\(Self.compact(today.input)) in · \(Self.compact(today.output)) out · \(Self.compact(today.cached)) cached")
                    .font(.notchCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if !today.models.isEmpty {
                    Text(today.models.sorted { $0.value > $1.value }.prefix(3).map(\.key).formatted(.list(type: .and, width: .narrow)))
                        .font(.notchCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: 220, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
    }

    /// "1.2M", "640K", in the app's language.
    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}

/// A bar per day across the room beside today's figures, oldest on the leading side; today's in the
/// accent. Each bar says its day and count on hover; VoiceOver hears today, the busiest day and the total.
private struct TokenBars: View {
    let days: [(date: Date, tokens: TokenDay)]

    var body: some View {
        let peak = max(1, days.map(\.tokens.total).max() ?? 1)
        // The gaps keep the bars' proportions as they widen: about a fifth of a bar, as 3 pt was at 14.
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days.indices, id: \.self) { index in
                let day = days[index]
                let isToday = index == days.count - 1
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isToday ? Color.notchAccent : .white.opacity(day.tokens.total > 0 ? 0.32 : 0.12))
                    .frame(height: max(2, 44 * CGFloat(day.tokens.total) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
                    .help("\(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(TokenHistoryRow.compact(day.tokens.total))")
            }
        }
        .frame(height: 44, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(peak: peak))
    }

    private func spoken(peak: Int) -> String {
        let today = TokenHistoryRow.compact(days.last?.tokens.total ?? 0)
        let total = TokenHistoryRow.compact(days.reduce(0) { $0 + $1.tokens.total })
        let busiest = days.max { $0.tokens.total < $1.tokens.total }
        let busiestDay = busiest.map { $0.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) } ?? ""
        return String(localized: "Tokens per day. Today \(today). Busiest \(busiestDay), \(TokenHistoryRow.compact(peak)). All 14 days \(total).")
    }
}
