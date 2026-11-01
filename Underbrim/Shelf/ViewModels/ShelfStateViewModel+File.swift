//
//  ShelfStateViewModel+File.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Finished downloads and new screenshots join the Shelf, referenced by bookmark, never copied or moved.
//

import Defaults
import Foundation

extension ShelfStateViewModel {
    func addFile(_ url: URL) {
        guard Defaults[.shelfEnabled], let bookmark = try? Bookmark(url: url) else { return }
        add([ShelfItem(kind: .file(bookmark: bookmark.data))])
    }
}
