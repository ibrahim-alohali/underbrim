//
//  SystemWidget.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  CPU, memory and network at a glance, from the kernel's own counters (no
//  permission). Sampled every two seconds, only while the widget is on screen.
//

import Darwin
import SwiftUI

struct SystemSample: Equatable {
    var cpu: Double = 0
    var memory: Double = 0
    var down: Double = 0
    var up: Double = 0
}

struct SystemSampler {
    private var cpuTicks: [UInt32]?
    private var network: (received: UInt64, sent: UInt64, at: TimeInterval)?

    mutating func sample() -> SystemSample {
        let now = ProcessInfo.processInfo.systemUptime
        var result = SystemSample()
        if let ticks = Self.cpuTicks() {
            if let last = cpuTicks { result.cpu = Self.busyShare(from: last, to: ticks) }
            cpuTicks = ticks
        }
        result.memory = Self.memoryUsed()
        let bytes = Self.networkBytes()
        if let last = network, now > last.at {
            result.down = Double(Self.delta(bytes.received, last.received)) / (now - last.at)
            result.up = Double(Self.delta(bytes.sent, last.sent)) / (now - last.at)
        }
        network = (bytes.received, bytes.sent, now)
        return result
    }

    /// A drop (a counter wrapping at 4 GB, an interface going away) counts as nothing, not a spike.
    static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    /// The busy share between two tick readings. The counters are 32-bit and wrap after weeks of
    /// uptime, so the differences wrap too.
    static func busyShare(from old: [UInt32], to new: [UInt32]) -> Double {
        guard old.count == 4, new.count == 4 else { return 0 }
        let d = zip(new, old).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (d[0] + d[1] + d[3]) / total : 0
    }

    static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    /// Activity Monitor's "Memory Used" (app memory, wired and compressed) as a share of RAM.
    static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count))
        let pages = app + Double(stats.wire_count) + Double(stats.compressor_page_count)
        return min(1, pages * Double(sysconf(_SC_PAGESIZE)) / Double(ProcessInfo.processInfo.physicalMemory))
    }

    static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return (0, 0) }
        defer { freeifaddrs(first) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = entry.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(counters.ifi_ibytes)
            sent += UInt64(counters.ifi_obytes)
        }
        return (received, sent)
    }
}

struct SystemWidget: View {
    @State private var sample = SystemSample()
    var alone = false

    init(alone: Bool = false) {
        self.alone = alone
    }

    var body: some View {
        Group {
            if alone {
                // Download and upload either side of the camera at a set width, so the island keeps its size.
                AloneFrame(widget: .system) {
                    rate("arrow.down", sample.down, label: String(localized: "Download"), font: .notchBody)
                        .frame(width: Self.bandRate, alignment: .leading)
                } trailing: {
                    rate("arrow.up", sample.up, label: String(localized: "Upload"), font: .notchBody)
                        .frame(width: Self.bandRate, alignment: .trailing)
                } row: {
                    HStack(spacing: 14) {
                        meter(String(localized: "CPU"), value: sample.cpu, symbol: "cpu", inline: true)
                        meter(String(localized: "Memory"), value: sample.memory, symbol: "memorychip", inline: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    meter(String(localized: "CPU"), value: sample.cpu, symbol: "cpu")
                    meter(String(localized: "Memory"), value: sample.memory, symbol: "memorychip")
                    HStack(spacing: 8) {
                        rate("arrow.down", sample.down, label: String(localized: "Download"))
                        rate("arrow.up", sample.up, label: String(localized: "Upload"))
                    }
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task {
            var sampler = SystemSampler()
            sample = sampler.sample()  // memory now; CPU and rates need a second reading
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                sample = sampler.sample()
            }
        }
    }

    private func meter(_ title: String, value: Double, symbol: String, inline: Bool = false) -> some View {
        let label = Label(title, systemImage: symbol).foregroundStyle(.secondary)
        let percent = Text(value, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.white)
        let bar = ProgressView(value: value)
            .progressViewStyle(.linear)
            .controlSize(.mini)
            .tint(value > 0.85 ? .red : .notchAccent)
        return Group {
            if inline {
                HStack(spacing: 6) {
                    label
                    bar.frame(width: 56)
                    percent.frame(minWidth: 30, alignment: .trailing)
                }
                .font(.notchCaption)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        label
                        Spacer()
                        percent
                    }
                    .font(.notchCaption)
                    bar
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }

    private func rate(_ symbol: String, _ bytesPerSecond: Double, label: String, font: Font = .notchCaption) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text("\(Self.bytes(bytesPerSecond))/s").monospacedDigit().foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Self.bytes(bytesPerSecond)) per second")
    }

    /// Room for "999.9 MB/s" and its arrow.
    private static let bandRate: CGFloat = 86

    /// "1.2 MB", "0 KB" (never "Zero KB").
    static func bytes(_ count: Double) -> String {
        Int64(count).formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}
