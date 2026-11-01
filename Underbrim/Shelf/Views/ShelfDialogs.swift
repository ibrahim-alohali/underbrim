//
//  ShelfDialogs.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The panels and alerts the Shelf's item menu opens: Open With › Other…,
//  Rename, Convert Image… and errors. They ask; ShelfActionService does the work.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum ShelfDialogs {
    // Keep associated objects (like accessory view handlers) without magic keys
    private static var sliderHandlerAssoc = AssociatedObject<AnyObject>()

    /// Open With › Other…: an app chosen in a panel, recommended apps first, optionally made the default.
    static func openWith(_ item: ShelfItem) {
        // Support both file items and link items
        let targetURL: URL?
        if let fileURL = item.fileURL {
            targetURL = fileURL
        } else if case .link(let url) = item.kind {
            targetURL = url
        } else {
            targetURL = nil
        }
        guard let fileURL = targetURL else { return }

        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Application")
        panel.message = String(localized: "Choose an application to open the document \"\(item.displayName)\".")
        panel.prompt = String(localized: "Open")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.application]
        }
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        // The file's type, read once: it picks the recommended apps, and the default app when asked.
        let contentType = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType

        // Compute recommended applications for the selected target
        let recommendedApps: Set<URL> = {
            let apps: [URL]
            if let uti = contentType {
                apps = NSWorkspace.shared.urlsForApplications(toOpen: uti)
            } else {
                apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
            }
            return Set(apps.map { $0.standardizedFileURL })
        }()

        // Delegate to filter entries when in "Recommended Applications" mode
        final class AppChooserDelegate: NSObject, NSOpenSavePanelDelegate {
            enum Mode { case recommended, all }
            var mode: Mode = .recommended
            let recommended: Set<URL>
            init(recommended: Set<URL>) { self.recommended = recommended }

            func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
                let ext = url.pathExtension.lowercased()
                if ext == "app" {
                    switch mode {
                    case .all:
                        return true
                    case .recommended:
                        // Standardize URLs for reliable comparison
                        let std = url.standardizedFileURL
                        return recommended.contains(std)
                    }
                }

                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return true
                }

                return false
            }
        }

        let chooserDelegate = AppChooserDelegate(recommended: recommendedApps)
        panel.delegate = chooserDelegate

        let enableLabel = NSTextField(labelWithString: String(localized: "Enable:"))
        enableLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        enableLabel.alignment = .natural
        enableLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [String(localized: "Recommended Applications"), String(localized: "All Applications")])
        popup.font = .systemFont(ofSize: NSFont.systemFontSize)
        popup.selectItem(at: 0)

        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        // Underbrim: it says it changes the default app for every file of this type. Links, folders,
        // bundles and extensionless files open only this once, so no folder or app default ever changes;
        // document packages (.rtfd, .pages) keep it.
        let alwaysType = contentType.flatMap { $0.conforms(to: .folder) || $0.conforms(to: .bundle) ? nil : $0 }
        let fileExtension = alwaysType == nil ? "" : fileURL.pathExtension
        let alwaysCheckbox = NSButton(checkboxWithTitle: String(localized: "Always open .\(fileExtension) files with this app"), target: nil, action: nil)
        alwaysCheckbox.font = .systemFont(ofSize: NSFont.systemFontSize)
        alwaysCheckbox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        alwaysCheckbox.isHidden = fileExtension.isEmpty

        let row = NSStackView(views: [enableLabel, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fill

        let column = NSStackView(views: [row, alwaysCheckbox])
        column.orientation = .vertical
        column.spacing = 12
        column.alignment = .centerX
        column.distribution = .fill
        column.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        panel.accessoryView = column
        panel.isAccessoryViewDisclosed = true

        // Wire up popup to switch filter mode
        class PopupBinder: NSObject {
            weak var popup: NSPopUpButton?
            weak var chooserDelegate: AppChooserDelegate?
            weak var panel: NSOpenPanel?
            init(popup: NSPopUpButton, chooserDelegate: AppChooserDelegate, panel: NSOpenPanel) {
                self.popup = popup
                self.chooserDelegate = chooserDelegate
                self.panel = panel
            }
            @MainActor @objc func changed(_ sender: Any?) {
                if popup?.indexOfSelectedItem == 1 {
                    chooserDelegate?.mode = .all
                } else {
                    chooserDelegate?.mode = .recommended
                }
                if let panel = panel {
                    panel.validateVisibleColumns()
                    let currentDir = panel.directoryURL
                    panel.directoryURL = currentDir
                }
            }
        }
        let binder = PopupBinder(popup: popup, chooserDelegate: chooserDelegate, panel: panel)
        popup.target = binder
        popup.action = #selector(PopupBinder.changed(_:))

        // Underbrim: in front, not behind the app in front, which gets the keyboard back on Cancel.
        Task {
            if await runFromNotch(panel) == .OK, let appURL = panel.url {
                let defaultFor = alwaysCheckbox.state == .on ? alwaysType : nil
                await ShelfActionService.open(fileURL, with: appURL, defaultFor: defaultFor)
            }
            // Keep binder/delegate alive until panel finishes
            _ = binder
            _ = chooserDelegate
        }
    }

    /// Rename: a save panel beside the file, in front.
    static func rename(_ item: ShelfItem) {
        guard case let .file(bookmarkData) = item.kind else { return }
        Task {
            let bookmark = Bookmark(data: bookmarkData)
            if let fileURL = bookmark.resolvedURL {
                // Start security-scoped access and keep it active until rename completes.
                let didStart = fileURL.startAccessingSecurityScopedResource()

                let savePanel = NSSavePanel()
                savePanel.title = String(localized: "Rename File")
                savePanel.prompt = String(localized: "Rename")
                savePanel.nameFieldStringValue = fileURL.lastPathComponent
                savePanel.directoryURL = fileURL.deletingLastPathComponent()
                // Underbrim: in front, not behind the app in front (as Open With › Other…).
                if await runFromNotch(savePanel) == .OK, let newURL = savePanel.url, newURL != fileURL {
                    do {
                        try ShelfActionService.rename(item, at: fileURL, to: newURL)
                    } catch {
                        Log.shelf.error("❌ Failed to rename file: \(error.localizedDescription)")
                        showError(title: String(localized: "Couldn't Rename"), message: error.localizedDescription)
                    }
                }
                if didStart { fileURL.stopAccessingSecurityScopedResource() }
            }
        }
    }

    /// Convert Image…: the format, size and metadata asked in an alert; nil on Cancel.
    static func convertOptions() -> ImageConversionOptions? {
        // Create and show conversion options dialog with better layout
        let alert = NSAlert()
        alert.messageText = String(localized: "Convert Image")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Convert"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        // Create accessory view with better spacing and organization
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        accessoryView.wantsLayer = true

        // MARK: Format Row
        let formatLabel = NSTextField(labelWithString: String(localized: "Format:"))
        formatLabel.frame = NSRect(x: 0, y: 145, width: 100, height: 20)
        formatLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accessoryView.addSubview(formatLabel)

        let formatPopup = NSPopUpButton(frame: NSRect(x: 120, y: 140, width: 250, height: 28))
        formatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "TIFF", "BMP"])
        formatPopup.selectItem(at: 0)
        formatPopup.font = .systemFont(ofSize: 12)
        formatPopup.setAccessibilityTitleUIElement(formatLabel)  // Underbrim: VoiceOver reads its label
        accessoryView.addSubview(formatPopup)

        // MARK: Image Size Row
        let imageSizeLabel = NSTextField(labelWithString: String(localized: "Image Size:"))
        imageSizeLabel.frame = NSRect(x: 0, y: 105, width: 100, height: 20)
        imageSizeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accessoryView.addSubview(imageSizeLabel)

        let imageSizePopup = NSPopUpButton(frame: NSRect(x: 120, y: 100, width: 160, height: 28))
        imageSizePopup.addItems(withTitles: [String(localized: "Actual Size"), String(localized: "Large"), String(localized: "Medium"), String(localized: "Small"), String(localized: "Custom…")])
        imageSizePopup.selectItem(at: 0)
        imageSizePopup.font = .systemFont(ofSize: 12)
        imageSizePopup.setAccessibilityTitleUIElement(imageSizeLabel)
        accessoryView.addSubview(imageSizePopup)

        // Custom size field (initially hidden)
        let customSizeField = NSTextField(frame: NSRect(x: 285, y: 103, width: 85, height: 22))
        customSizeField.placeholderString = String(localized: "e.g., 1920")
        customSizeField.font = .systemFont(ofSize: 12)
        customSizeField.isHidden = true
        accessoryView.addSubview(customSizeField)

        // MARK: Preserve Metadata Checkbox
        let metadataCheckbox = NSButton(checkboxWithTitle: String(localized: "Preserve Metadata"), target: nil, action: nil)
        metadataCheckbox.frame = NSRect(x: 120, y: 65, width: 200, height: 20)
        metadataCheckbox.font = .systemFont(ofSize: 12)
        metadataCheckbox.state = .on
        accessoryView.addSubview(metadataCheckbox)

        // MARK: Separator line
        let separatorLine = NSView(frame: NSRect(x: 0, y: 50, width: 380, height: 1))
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
        accessoryView.addSubview(separatorLine)

        // MARK: Format-specific options (shown/hidden based on format selection)
        let qualityLabel = NSTextField(labelWithString: String(localized: "Compression:"))
        qualityLabel.frame = NSRect(x: 0, y: 7, width: 100, height: 20)
        qualityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accessoryView.addSubview(qualityLabel)  // Underbrim: it sat in a row never added, so it never showed

        let qualitySlider = NSSlider(frame: NSRect(x: 120, y: 12, width: 200, height: 20))
        qualitySlider.minValue = 0.0
        qualitySlider.maxValue = 1.0
        qualitySlider.doubleValue = 0.85
        qualitySlider.setAccessibilityTitleUIElement(qualityLabel)
        accessoryView.addSubview(qualitySlider)

        let qualityValueLabel = NSTextField(labelWithString: 0.85.formatted(.percent.precision(.fractionLength(0))))
        qualityValueLabel.frame = NSRect(x: 325, y: 7, width: 55, height: 20)
        qualityValueLabel.font = .systemFont(ofSize: 12)
        qualityValueLabel.alignment = .natural
        accessoryView.addSubview(qualityValueLabel)
        // Underbrim: frame-laid rows don't mirror on their own: right to left, labels go right of their controls.
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            for view in accessoryView.subviews {
                view.frame.origin.x = accessoryView.bounds.width - view.frame.maxX
            }
        }

        // Update quality label and hide/show compression row based on format
        let updateQualityLabel = {
            qualityValueLabel.stringValue = qualitySlider.doubleValue.formatted(.percent.precision(.fractionLength(0)))
        }

        let updateCompressionVisibility = {
            let formatIndex = formatPopup.indexOfSelectedItem
            let showCompression = formatIndex == 1 || formatIndex == 2 // JPEG or HEIC
            qualitySlider.isHidden = !showCompression
            qualityValueLabel.isHidden = !showCompression
            qualityLabel.isHidden = !showCompression
        }

        let updateCustomSizeVisibility = {
            let sizeIndex = imageSizePopup.indexOfSelectedItem
            customSizeField.isHidden = sizeIndex != 4 // Show only for "Custom..."
        }

        // Create a target object to handle slider value changes
        class SliderHandler: NSObject {
            let updateLabel: () -> Void
            let updateVisibility: () -> Void
            let updateCustomSize: () -> Void
            init(updateLabel: @escaping () -> Void, updateVisibility: @escaping () -> Void, updateCustomSize: @escaping () -> Void) {
                self.updateLabel = updateLabel
                self.updateVisibility = updateVisibility
                self.updateCustomSize = updateCustomSize
            }
            @objc func sliderChanged(_ sender: NSSlider) {
                updateLabel()
            }
            @objc func formatChanged(_ sender: NSPopUpButton) {
                updateVisibility()
            }
            @objc func sizeChanged(_ sender: NSPopUpButton) {
                updateCustomSize()
            }
        }

        let handler = SliderHandler(updateLabel: updateQualityLabel, updateVisibility: updateCompressionVisibility, updateCustomSize: updateCustomSizeVisibility)
        qualitySlider.target = handler
        qualitySlider.action = #selector(SliderHandler.sliderChanged(_:))
        qualitySlider.isContinuous = true

        formatPopup.target = handler
        formatPopup.action = #selector(SliderHandler.formatChanged(_:))

        imageSizePopup.target = handler
        imageSizePopup.action = #selector(SliderHandler.sizeChanged(_:))

        updateCompressionVisibility()
        updateQualityLabel()
        updateCustomSizeVisibility()

        // Keep the handler alive using the `AssociatedObject` helper instead of a magic string key
        sliderHandlerAssoc[accessoryView] = handler

        alert.accessoryView = accessoryView

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        // Get selected options
        let formatIndex = formatPopup.indexOfSelectedItem
        let format: ImageConversionOptions.ImageFormat
        switch formatIndex {
        case 0: format = .png
        case 1: format = .jpeg
        case 2: format = .heic
        case 3: format = .tiff
        case 4: format = .bmp
        default: format = .png
        }

        let quality = qualitySlider.doubleValue

        // Get max dimension based on image size selection
        let maxDimension: CGFloat? = {
            let sizeIndex = imageSizePopup.indexOfSelectedItem
            switch sizeIndex {
            case 0: return nil // Actual Size
            case 1: return 1280 // Large 
            case 2: return 640  // Medium 
            case 3: return 320  // Small 
            case 4: // Custom (user-specified)
                let text = customSizeField.stringValue.trimmingCharacters(in: .whitespaces).westernDigits
                guard !text.isEmpty, let value = Double(text), value > 0 else { return nil }
                return CGFloat(value)
            default: return nil
            }
        }()

        let removeMetadata = metadataCheckbox.state == .off // Note: we invert this

        return ImageConversionOptions(
            format: format,
            compressionQuality: quality,
            maxDimension: maxDimension,
            removeMetadata: removeMetadata
        )
    }

    static func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
