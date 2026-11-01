//
//  DownloadViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Downloads in the notch. A percentage appears only when the browser reported a total.
//

import SwiftUI

struct DownloadClosedSummary: Equatable {
    let id: String
    let browserBundleID: String
    let state: DownloadsStore.Item.State

    /// Read here rather than kept in the summary: it carries the percentage,
    /// and a summary change re-renders the whole notch on every progress tick.
    @MainActor var spokenText: String {
        DownloadsStore.shared.items.first { $0.id == id }.map(DownloadsStore.accessibilityText(for:)) ?? ""
    }
}

/// Ring for the closed pill. Reads the live fraction itself, so byte updates redraw only this view.
struct DownloadProgressRing: View {
    let id: String
    let state: DownloadsStore.Item.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounces = 0

    var body: some View {
        let fraction = DownloadsStore.shared.items.first { $0.id == id }?.fraction
        ZStack {
            switch state {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .symbolEffect(.bounce, value: bounces)
            case .cancelled, .stopped:
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .dangerous:
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.yellow)
            case .paused:
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
            case .active:
                if let fraction {
                    ProgressRing(fraction: fraction, animated: !reduceMotion, color: NSColor(Color.notchAccent))
                } else {
                    // No total from the browser: activity only, and no endless animation.
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .font(.notchSymbol(size: 13))
        .padding(1.5)
        .accessibilityHidden(true)
        // Once, as it finishes (see AgentStateGlyph): not when the island closes over it later.
        .task(id: state) {
            guard !reduceMotion, state == .completed,
                  let item = DownloadsStore.shared.items.first(where: { $0.id == id }),
                  Date.now.timeIntervalSince(item.updatedAt) < 1 else { return }
            bounces += 1
        }
    }
}

struct DownloadLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let summary: DownloadClosedSummary

    private var itemSize: CGFloat { vm.closedItemSize }

    var body: some View {
        HStack {
            AppIconView(bundleID: summary.browserBundleID, size: itemSize)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            DownloadProgressRing(id: summary.id, state: summary.state)
                .frame(width: itemSize, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.spokenText)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct DownloadsExpandedView: View {
    private let store = DownloadsStore.shared
    static let cardWidth: CGFloat = 232

    var body: some View {
        Group {
            if store.items.isEmpty {
                Label(String(localized: "No downloads right now"), systemImage: "arrow.down.circle")
                    .font(.notchBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: NotchMetrics.cardSpacing) {
                        ForEach(store.items) { item in DownloadRow(item: item).frame(width: Self.cardWidth) }
                    }
                }
                .scrollIndicators(.never)
                .scrollsBeforePages()
            }
        }
        .frame(height: NotchMetrics.tabHeight)
    }
}

struct DownloadRow: View {
    let item: DownloadsStore.Item

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: item.browserBundleID, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.notchTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .active || item.state == .paused {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.mini)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.mini)
                    }
                }
                // Two lines if need be ("12.4 MB so far · size unknown" is wider than the card).
                Text(detail).font(.notchCaption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            // The whole width, not a Spacer after it, whose gap cost the text 16 pt.
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.state == .completed, let url = item.fileURL {
                NotchTextButton(title: String(localized: "Show"), help: String(localized: "Show \(item.name) in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(.notchRowFill, in: RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        // "0 bytes of 12 MB" as a download starts, not "Zero KB".
        let bytes: (Int64) -> String = { $0.formatted(.byteCount(style: .file, spellsOutZero: false)) }
        switch item.state {
        case .active:
            if let received = item.received, let total = item.total { return String(localized: "\(bytes(received)) of \(bytes(total))") }
            if let received = item.received, received > 0 { return String(localized: "\(bytes(received)) so far · size unknown") }
            return String(localized: "Downloading · size unknown")
        case .paused: return String(localized: "Paused")
        case .completed: return item.total.map { String(localized: "Finished · \(bytes($0))") } ?? String(localized: "Finished")
        case .cancelled: return String(localized: "Cancelled")
        case .failed: return String(localized: "Failed in the browser")
        case .dangerous: return String(localized: "Flagged by the browser — decide in the browser")
        case .stopped: return String(localized: "Stopped before finishing")
        }
    }
}
