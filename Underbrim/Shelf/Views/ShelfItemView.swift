//
//  ShelfItemView.swift
//  Underbrim
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI

struct ShelfItemView: View {
    let item: ShelfItem
    let quickLookService: QuickLookService
    let dropInteraction: DropInteractionState
    @StateObject private var viewModel: ShelfItemViewModel
    @State private var selectionState: ShelfItemSelectionState

    private var isSelected: Bool { selectionState.isSelected }

    private var highlight: HighlightPresentation {
        if isSelected {
            HighlightPresentation(
                fill: Color.notchAccent.opacity(0.15),
                stroke: Color.notchAccent.opacity(0.8),
                lineWidth: 2
            )
        } else {
            HighlightPresentation(fill: .clear, stroke: .clear, lineWidth: 1)
        }
    }

    init(
        item: ShelfItem,
        quickLookService: QuickLookService,
        dropInteraction: DropInteractionState
    ) {
        self.item = item
        self.quickLookService = quickLookService
        self.dropInteraction = dropInteraction
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
        _selectionState = State(initialValue: ShelfSelectionModel.shared.state(for: item.id))
    }

    var body: some View {
        itemContent
        .task(id: item.id) {
            await viewModel.loadThumbnail()
        }
        .onAppear {
            // Only the service: capturing the view would keep the model that keeps this closure,
            // and every item view the Shelf replaced would stay in memory.
            viewModel.onQuickLookRequest = { [quickLookService] urls in
                quickLookService.show(urls: urls, selectFirst: true)
            }
        }
    }

    // MARK: - View Components

    /// Padding, icon, spacing, two lines of name, padding: the Shelf's row less 2 pt above and below.
    static let height: CGFloat = 5 + 44 + 2 + nameHeight + 5
    /// Two lines of the caption font (about 26.3 pt).
    static let nameHeight: CGFloat = 28

    private var itemContent: some View {
        VStack(alignment: .center, spacing: 2) {
            iconView
            textView
        }
        .frame(width: 80)
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(backgroundView)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.1), value: isSelected)
        .overlay {
            ShelfItemInteractionView(
                item: item,
                viewModel: viewModel,
                dragPreview: {
                    DragPreviewView(
                        thumbnail: viewModel.thumbnail ?? item.icon,
                        displayName: item.displayName
                    )
                },
                onPrimaryClick: viewModel.handleClick,
                onContextClick: viewModel.handleRightClick
            )
        }
        // Underbrim: input goes to the bare NSView above, so for VoiceOver the item names itself and offers the menu's actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { ShelfActionService.open(item) }
        .accessibilityActions {
            // As its menu: Quick Look for files and links, Show in Finder for files.
            if let url = item.URL {
                Button(ShelfStrings.quickLook) { quickLookService.show(urls: [url]) }
            }
            if case .file = item.kind {
                Button(ShelfStrings.showInFinder) { ShelfActionService.reveal(item) }
            }
            Button(ShelfStrings.remove) { ShelfActionService.remove(item) }
        }
    }

    private var iconView: some View {
        Image(nsImage: viewModel.thumbnail ?? item.icon)
            .resizable().scaledToFit()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var textView: some View {
        Text(item.displayName)
            .font(.notchCaption)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(height: Self.nameHeight, alignment: .top)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous)
            .fill(highlight.fill)
            .overlay(
                RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous)
                    .strokeBorder(
                        highlight.stroke,
                        lineWidth: highlight.lineWidth
                    )
            )
    }

    private struct HighlightPresentation {
        let fill: Color
        let stroke: Color
        let lineWidth: CGFloat
    }
}
