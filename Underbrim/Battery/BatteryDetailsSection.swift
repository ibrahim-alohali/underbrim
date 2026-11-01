//
//  BatteryDetailsSection.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import SwiftUI

/// Extra rows for the battery popover. Live values refresh only while the popover is open.
struct BatteryDetailsSection: View {
    private let details = BatteryDetails.shared
    @State private var energy: [EnergyEstimator.AppEnergy]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cycles = details.health?.cycles {
                Label("Cycle count: \(cycles)", systemImage: "arrow.triangle.2.circlepath")
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                if let watts = BatteryDetails.systemPowerWatts() {
                    Label {
                        Text("Mac is drawing \(watts, format: .number.precision(.fractionLength(1))) W")
                    } icon: {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                    }
                    .help(String(localized: "Measured by the battery's power telemetry."))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Most CPU energy (estimate)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let energy {
                    if energy.isEmpty {
                        Text("No app is using much right now").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(energy) { app in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable().frame(width: 14, height: 14).accessibilityHidden(true)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Text(app.milliwatts >= 1000
                                 ? String(localized: "≈ \(app.milliwatts / 1000, format: .number.precision(.fractionLength(1))) W")
                                 : String(localized: "≈ \(Int(app.milliwatts)) mW"))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("The kernel's estimate of CPU energy only — not GPU, display or radios, so not exact battery use.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .task {
            details.refreshHealthIfNeeded()
            energy = await EnergyEstimator.sample()
        }
    }
}
