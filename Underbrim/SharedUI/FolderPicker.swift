//
//  FolderPicker.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit

/// Asks for a folder and returns its bookmark. The selection is also what grants this app access to the folder.
@MainActor
func chooseFolderBookmark(prompt: String, message: String, startingAt directory: URL) -> Data? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = directory
    panel.prompt = prompt
    panel.message = message
    guard runFromNotch({ panel.runModal() }) == .OK, let url = panel.url else { return nil }
    return try? url.bookmarkData(options: [.withSecurityScope])
}
