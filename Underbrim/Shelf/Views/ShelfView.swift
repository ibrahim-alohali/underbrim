//
//  ShelfItemView.swift
//  Underbrim
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit
import Defaults

struct ShelfView: View {
    let dropInteraction: DropInteractionState
    @StateObject var shelfState = ShelfStateViewModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = 8

    private var displayedItems: [ShelfItem] {
        Defaults[.reverseShelfOrdering] ? Array(shelfState.items.reversed()) : shelfState.items
    }

    var body: some View {
        @Bindable var interaction = dropInteraction

        ShelfQuickLookHost { quickLookService in
            HStack(spacing: NotchMetrics.margin) {
                FileShareView(dropInteraction: dropInteraction)
                    .aspectRatio(1, contentMode: .fit)
                panel(quickLookService: quickLookService)
                    .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $interaction.dragDetectorTargeting) { providers in
                        handleDrop(providers: providers)
                    }
            }
            .frame(height: NotchMetrics.tabHeight)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !ShelfSelectionModel.shared.isDragging else { return false }
        dropInteraction.dropEvent = true
        shelfState.load(providers)
        return true
    }

    private func panel(quickLookService: QuickLookService) -> some View {
        RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous)
            .strokeBorder(
                dropInteraction.dragDetectorTargeting
                    ? Color.notchAccent.opacity(0.9)
                    : Color.white.opacity(0.15),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4])
            )
            .overlay {
                ZStack {
                    ShelfBackgroundInteractionView()
                    // The files row scrolls edge to edge (its -spacing padding).
                    content(quickLookService: quickLookService)
                        .padding(spacing)
                }
            }
    }

    private func content(quickLookService: QuickLookService) -> some View {
        @Bindable var interaction = dropInteraction

        return Group {
            if shelfState.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.notchSymbol(size: 18))
                        .foregroundStyle(.secondary)

                    Text("Drop files here")
                        .font(.notchBody)
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: spacing) {
                        ForEach(displayedItems) { item in
                            ShelfItemView(
                                item: item,
                                quickLookService: quickLookService,
                                dropInteraction: dropInteraction
                            )
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .scrollsBeforePages()
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $interaction.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        // Files arriving and leaving glide into place (the rest of the Shelf isn't animated).
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: displayedItems.map(\.id))
        .onAppear {
            shelfState.cleanupInvalidItems()
        }
    }
}

private struct ShelfBackgroundInteractionView: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundView {
        BackgroundView()
    }

    func updateNSView(_ nsView: BackgroundView, context: Context) {}

    static func dismantleNSView(_ nsView: BackgroundView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class BackgroundView: NSView {
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()

            guard window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window,
                  event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let contentView = window.contentView
            else { return }

            // hitTest takes the point in the view's superview (the content view's own space is
            // flipped): otherwise a click on an item cleared the selection that ⌘ and ⇧ add to.
            let hitPoint = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard !isShelfItemInteraction(contentView.hitTest(hitPoint)) else { return }

            ShelfSelectionModel.shared.clear()
        }

        private func isShelfItemInteraction(_ hitView: NSView?) -> Bool {
            var view = hitView
            while let currentView = view {
                if currentView is any ShelfItemInteractionSurface {
                    return true
                }
                view = currentView.superview
            }
            return false
        }
    }
}

/// The notch's own Quick Look (ContentView owns and presents it), so a preview outlives the island closing.
private struct ShelfQuickLookHost<Content: View>: View {
    @EnvironmentObject private var service: QuickLookService
    @ViewBuilder let content: (QuickLookService) -> Content

    var body: some View {
        content(service)
    }
}
