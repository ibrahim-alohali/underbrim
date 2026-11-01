//
//  HeadphoneViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI

extension HeadphoneBatteryStore.Device {
    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods") { return "airpods" }
        return "headphones"
    }

    var accessibilityText: String {
        var parts = [name]
        if let left { parts.append(String(localized: "left \(left) percent")) }
        if let right { parts.append(String(localized: "right \(right) percent")) }
        if let caseLevel { parts.append(String(localized: "case \(caseLevel) percent")) }
        if let single { parts.append(String(localized: "\(single) percent")) }
        if !hasAnyReading { parts.append(String(localized: "battery not reported")) }
        return ListFormatter.localizedString(byJoining: parts)
    }
}

/// Closed-notch pill shown for a few seconds after headphones connect.
struct HeadphoneLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let device: HeadphoneBatteryStore.Device

    private var itemSize: CGFloat { vm.closedItemSize }

    var body: some View {
        HStack {
            Image(systemName: device.symbol)
                .font(.notchSymbol(size: 12))
                .foregroundStyle(.white)
                .frame(width: itemSize, height: itemSize)
            Rectangle().fill(.black).frame(width: vm.closedMiddleWidth)
            Text(device.lowest.map { (Double($0) / 100).formatted(.percent) } ?? "—")
                .font(.notchCaption.weight(.semibold).monospacedDigit())
                .foregroundStyle((device.lowest ?? 100) <= 20 ? .orange : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)  // "100%" fits, as the other pills' text does
                .frame(width: itemSize + 6, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.accessibilityText)
    }
}

/// Compact indicator for the open notch header, with a details popover.
struct HeadphoneBatteryIndicator: View {
    @EnvironmentObject private var vm: NotchViewModel
    private let store = HeadphoneBatteryStore.shared
    @State private var showDetails = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        if let device = store.devices.first {
            Button { showDetails.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: device.symbol)
                    Text(device.lowest.map { (Double($0) / 100).formatted(.percent) } ?? "—").monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(device.accessibilityText)
            .onHover { hovering in
                isHoveringButton = hovering
                if hovering { cancelHide() } else { scheduleHideIfNeeded() }
            }
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.devices) { device in
                        Text(device.name).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            if let left = device.left { GridRow { Text("Left"); Text((Double(left) / 100).formatted(.percent)).monospacedDigit() } }
                            if let right = device.right { GridRow { Text("Right"); Text((Double(right) / 100).formatted(.percent)).monospacedDigit() } }
                            if let caseLevel = device.caseLevel { GridRow { Text("Case"); Text((Double(caseLevel) / 100).formatted(.percent)).monospacedDigit() } }
                            if let single = device.single { GridRow { Text("Battery"); Text((Double(single) / 100).formatted(.percent)).monospacedDigit() } }
                        }
                        .font(.subheadline)
                        if !device.hasAnyReading {
                            Text("This device doesn't report its battery to the Mac.").font(.caption).foregroundStyle(.secondary)
                        } else if device.caseLevel == nil, device.left != nil {
                            Text("The case reports its level only while an earbud is in it.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .frame(width: 230)
                .onHover { hovering in
                    isHoveringPopover = hovering
                    if hovering { cancelHide() } else { scheduleHideIfNeeded() }
                }
            }
            // It hangs below the island: shown, it holds the island open, as the battery's popover does.
            .onChange(of: showDetails) { _, shown in vm.isPopoverActive = shown }
            .onReceive(NotificationCenter.default.publisher(for: .closeIslandPopovers)) { _ in showDetails = false }
            .onAppear { store.reloadConnected() }
            .onDisappear {
                cancelHide()
                if showDetails { vm.isPopoverActive = false }
            }
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    /// Hides it a moment after the pointer has left both the indicator and the popover, like the island's other popovers.
    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { showDetails = false } }
        }
    }
}
