//
//  FileShareView.swift
//  Underbrim
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    let dropInteraction: DropInteractionState
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var interactionNonce: UUID = .init()
    @State private var isProcessing = false

    private var selectedProvider: QuickShareProvider {
        let providers = quickShare.availableProviders
        return providers.first { $0.id == quickShareProvider }
            ?? providers.first { $0.id == QuickShareProvider.airDropId } ?? .systemShareMenu
    }

    var body: some View {
        @Bindable var interaction = dropInteraction

        // Underbrim: a button (not a tap gesture), so VoiceOver can press it too.
        Button { Task { await handleClick() } } label: { dropArea }
            .buttonStyle(.plain)
            .accessibilityLabel(selectedProvider.title)
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $interaction.dropZoneTargeting) { providers in
                interactionNonce = .init()
                interaction.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
    }

    private var dropArea: some View {
        ZStack {
            // Underbrim: a quiet outline inside the frame, no fill or shadow.
            RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous)
                .strokeBorder(
                    dropInteraction.dropZoneTargeting
                        ? Color.notchAccent.opacity(0.9)
                        : Color.white.opacity(0.15),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4])
                )

            // Content
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(
                            dropInteraction.dropZoneTargeting ? 0.11 : 0.07
                        ))
                        .frame(width: 44, height: 44)
                    Group {
                        if let icon = quickShare.icon(for: selectedProvider.id, size: 28) {
                            Image(nsImage: icon)
                                .resizable().scaledToFit()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .font(.notchSymbol(size: 18))
                        }
                    }
                    .frame(width: 28, height: 28)
                        .foregroundStyle(
                            dropInteraction.dropZoneTargeting ? Color.notchAccent : Color.gray
                        )
                        .scaleEffect(
                            dropInteraction.dropZoneTargeting ? 1.06 : 1.0
                        )
                        .animation(.spring(response: 0.36, dampingFraction: 0.7), value: dropInteraction.dropZoneTargeting)
                }

                Text(selectedProvider.title)
                    .font(.notchCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(10)

            // Loading overlay
            if isProcessing || quickShare.isPickerOpen {
                RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous)
                    .fill(.black.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous))
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }

    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}
