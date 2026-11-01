//
//  TemporaryFileStorageService.swift
//  Underbrim
//
//  Created by Alexander on 2025-09-24.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

enum TempFileType {
    case data(Data, suggestedName: String?)
    case text(String)
}

final class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()

    /// Underbrim: next to the Shelf's list, not in the temp folder macOS empties of files older than
    /// three days. Cleanup never reaches past this folder.
    private static let root = Relay.supportDirectory
        .appendingPathComponent("Shelf", isDirectory: true)
        .appendingPathComponent("Files", isDirectory: true)

    /// Removes stored files no Shelf item uses, except folders made in the last minute (a drop may be coming).
    func removeUnused(keeping kept: [URL]) {
        let keptFolders = Set(kept.map { $0.resolvingSymlinksInPath().deletingLastPathComponent().lastPathComponent })
        Relay.removeEntries(in: Self.root, recursive: true) { entries in
            Set(entries.filter { !keptFolders.contains($0.name) && Date().timeIntervalSince($0.created) > 60 }.map(\.name))
        }
    }

    // MARK: - Public Interface

    /// Creates a temporary file and tracks it for manual cleanup
    func createTempFile(for type: TempFileType) async -> URL? {
        return await withCheckedContinuation { continuation in
            let result = createTempFile(for: type)
            continuation.resume(returning: result)
        }
    }

    func removeTemporaryFileIfNeeded(at url: URL) {
        // Underbrim: the item's own folder, directly in ours. Removal is relative to
        // folders opened without following links (Relay.removeEntries).
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.path == Self.root.standardizedFileURL.path else {
            Log.shelf.debug("Attempted to remove temporary file outside temp directory: \(url.path)")
            return
        }
        Relay.removeEntries(in: folder) { _ in [url.lastPathComponent] }
        Relay.removeEntries(in: Self.root) { _ in [folder.lastPathComponent] }  // only once it's empty
    }

    // MARK: - Private Implementation

    private func createTempFile(for type: TempFileType) -> URL? {
        let tempDir = Self.root
        let uuid = UUID().uuidString

        switch type {
        case .data(let data, let suggestedName):
            // Underbrim: the name comes from the drag's source, so only its last component counts (no "../").
            let given = ((suggestedName ?? "") as NSString).lastPathComponent
            let filename = ["", ".", "..", "/"].contains(given) ? String(localized: "Dropped Item") : given
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)

            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                Log.shelf.error("Error: \(error)")
                return nil
            }

        case .text(let string):
            let filename = "\(uuid).txt"
            let dirURL = tempDir.appendingPathComponent(uuid, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent(filename)

            guard let data = string.data(using: .utf8) else {
                Log.shelf.error("❌ Failed to convert text to data")
                return nil
            }

            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                return fileURL
            } catch {
                Log.shelf.error("Error: \(error)")
                return nil
            }
        }
    }

    func createZip(from urls: [URL], suggestedName: String? = nil) async -> URL? {
        let tempDir = Self.root
        let uuid = UUID().uuidString
        let workingDir = tempDir.appendingPathComponent("zip_\(uuid)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        } catch {
            Log.shelf.error("❌ Failed to create zip working directory: \(error)")
            return nil
        }

        // Helper to run zip process
        func runZip(arguments: [String], currentDirectory: URL) -> Bool {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = arguments
            proc.environment = Process.cleanEnvironment()  // Underbrim: zip reads options from ZIPOPT
            proc.currentDirectoryURL = currentDirectory
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                Log.shelf.error("❌ Failed to run zip: \(error)")
                return false
            }
        }

        // Single-item optimization: do not copy contents into the working dir.
        // Underbrim: not for a link, which goes in as what it points to (below).
        if urls.count == 1, let src = urls.first,
           (try? src.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
            let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let baseName = src.lastPathComponent
            let archiveName: String
            if isDir {
                // Folder: name as FolderName.zip and include the folder itself in the archive
                archiveName = "\(baseName).zip"
                let archiveURL = workingDir.appendingPathComponent(archiveName)
                // Run zip from the parent directory so the folder is stored as top-level entry
                let parent = src.deletingLastPathComponent()
                // Underbrim: "./" so a name starting with "-" isn't an option; -y keeps links inside as links, as
                // Finder's Compress does, so no files from elsewhere (~/.ssh) end up in an archive to share.
                let args = ["-r", "-y", "-q", archiveURL.path, "./" + baseName]
                let ok = runZip(arguments: args, currentDirectory: parent)
                if ok {
                    return archiveURL
                } else {
                    return nil
                }
            } else {
                // File: include the file only (no parent folders). Name should include original extension.
                archiveName = "\(baseName).zip"
                let archiveURL = workingDir.appendingPathComponent(archiveName)
                let parent = src.deletingLastPathComponent()
                // -j to junk paths and store only the file
                let args = ["-j", "-q", archiveURL.path, "./" + baseName]
                let ok = runZip(arguments: args, currentDirectory: parent)
                if ok {
                    return archiveURL
                } else {
                    return nil
                }
            }
        }

        // Multi-item: copy items into working dir (so their relative structure is preserved), zip, then remove copies.
        for src in urls {
            let dest = workingDir.appendingPathComponent(src.lastPathComponent)
            // Underbrim: a linked item goes in as its target under its own name; links inside folders stay links (-y).
            let source = src.resolvingSymlinksInPath()
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    // Avoid collision by appending a suffix
                    let unique = "\(UUID().uuidString)_\(src.lastPathComponent)"
                    try FileManager.default.copyItem(at: source, to: workingDir.appendingPathComponent(unique))
                } else {
                    try FileManager.default.copyItem(at: source, to: dest)
                }
            } catch {
                Log.shelf.error("⚠️ Failed to copy \(src.path) to working dir: \(error)")
                Relay.removeOwnItem(at: workingDir)
                return nil
            }
        }

        let archiveName = suggestedName ?? (urls.count == 1 ? "\(urls[0].lastPathComponent).zip" : "Archive.zip")
        let archiveURL = workingDir.appendingPathComponent(archiveName)
        let args = ["-r", "-y", "-q", archiveURL.path, "."]  // Underbrim: -y, as above
        let ok = runZip(arguments: args, currentDirectory: workingDir)
        if ok {
            // Remove the copied (uncompressed) items so the temp folder contains only the archive
            Relay.removeEntries(in: workingDir, recursive: true) { Set($0.map(\.name)).subtracting([archiveName]) }
            return archiveURL
        } else {
            return nil
        }
    }
}
