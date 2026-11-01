//
//  ClipboardVault.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Encrypted storage for clipboard history: every file is sealed with AES-GCM, the key is sealed in
//  turn by the Secure Enclave. If the key can't be read, nothing is decrypted or written in plaintext.
//

import CryptoKit
import Foundation
import Security

struct ClipboardEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, link, image }

    /// What was copied: text and links have their text, images their size (the picture is in its own file).
    enum Content: Equatable, Sendable {
        case text(String)
        case link(String)
        case image(size: CGSize?)
    }

    let id: UUID
    var content: Content
    var byteCount: Int
    var sourceBundleID: String?
    var copiedAt: Date
    var pinned = false

    var kind: Kind {
        switch content {
        case .text: .text
        case .link: .link
        case .image: .image
        }
    }

    /// A text's or a link's text.
    var text: String? {
        switch content {
        case .text(let text), .link(let text): text
        case .image: nil
        }
    }
}

/// Stored flat, as before the content had a type of its own, so other versions read it: a text or a
/// link without its text isn't an entry, and the history that holds one isn't read.
extension ClipboardEntry: Codable {
    private enum CodingKeys: String, CodingKey { case id, kind, text, byteCount, imageSize, sourceBundleID, copiedAt, pinned }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text: content = .text(try container.decode(String.self, forKey: .text))
        case .link: content = .link(try container.decode(String.self, forKey: .text))
        case .image: content = .image(size: try container.decodeIfPresent(CGSize.self, forKey: .imageSize))
        }
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        copiedAt = try container.decode(Date.self, forKey: .copiedAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        switch content {
        case .text(let text), .link(let text): try container.encode(text, forKey: .text)
        case .image(let size): try container.encodeIfPresent(size, forKey: .imageSize)
        }
        try container.encode(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try container.encode(copiedAt, forKey: .copiedAt)
        try container.encode(pinned, forKey: .pinned)
    }
}

enum ClipboardVaultError: Error, Equatable {
    case keyUnavailable(OSStatus)
    case corrupt
}

/// The history key, sealed by a key in this Mac's Secure Enclave and kept in `history.key` next to
/// the history, so every build opens it without asking. The login Keychain can't do that for a
/// self-made certificate: with no Team ID it tells builds apart by their code hash, and asks for the
/// login password whenever a new one reads the key. Like the history, the file can't be opened on
/// another Mac; a program already running as you on this Mac can use it, as it could read the
/// clipboard itself. A Mac without a Secure Enclave keeps the key where earlier versions did.
struct ClipboardKeyStore: Sendable {
    let file: URL
    /// Where earlier versions kept the key.
    let earlier: PlainClipboardKey

    static var app: ClipboardKeyStore {
        let directory = ClipboardVault.defaultDirectory()
        return ClipboardKeyStore(file: directory.appendingPathComponent("history.key"), earlier: .app)
    }

    /// When the earlier key is there but macOS would ask about it, `setAside` runs before a new key
    /// is stored, so the history it opens is kept for `loadEarlier`.
    func loadOrCreate(settingAside setAside: () throws -> Void) throws -> SymmetricKey {
        guard SecureEnclave.isAvailable else { return try earlier.loadOrCreate() }
        if let sealed = try Self.read(file) { return try Self.open(sealed) }
        var adopted: SymmetricKey?
        do {
            adopted = try earlier.load(asking: false)
        } catch {
            try setAside()
        }
        let key = adopted ?? SymmetricKey(size: .bits256)
        // Another open of this history may have stored a key meanwhile: that one stays, and is used.
        guard try Self.store(Self.seal(key), at: file) else {
            guard let sealed = try Self.read(file) else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
            return try Self.open(sealed)
        }
        if adopted != nil { earlier.delete(asking: false) }
        return key
    }

    /// nil only when there's no file: any other failure throws, so a key that's there is never replaced.
    private static func read(_ file: URL) throws -> Data? {
        do {
            return try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw ClipboardVaultError.keyUnavailable(errSecIO)
        }
    }

    /// Stores the file only where there's none yet; false when there is.
    private static func store(_ data: Data, at file: URL) throws -> Bool {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let written = folder.appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: written.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
        if renamex_np(written.path, file.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let failure = errno
        try? FileManager.default.removeItem(at: written)
        guard failure == EEXIST else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
        return false
    }

    /// The key to the history set aside; macOS may ask about it.
    func loadEarlier() throws -> SymmetricKey {
        guard let key = try earlier.load(asking: true) else { throw ClipboardVaultError.keyUnavailable(errSecItemNotFound) }
        return key
    }

    /// Once the history set aside is brought back or deleted. A Keychain item stored by a build the
    /// Keychain doesn't trust stays (deleting it fails without asking).
    func forgetEarlier() {
        if SecureEnclave.isAvailable { earlier.delete(asking: false) }
    }

    func delete() {
        try? FileManager.default.removeItem(at: file)
        earlier.delete(asking: !SecureEnclave.isAvailable)
    }

    /// The enclave key's blob, the public half of a one-off key, and the history key sealed with
    /// what the two agree on.
    private struct Sealed: Codable {
        var enclaveKey: Data
        var publicKey: Data
        var sealedKey: Data
    }

    private static func wrappingKey(_ enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey,
                                    _ publicKey: P256.KeyAgreement.PublicKey) throws -> SymmetricKey {
        try enclaveKey.sharedSecretFromKeyAgreement(with: publicKey)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("Underbrim clipboard history key".utf8),
                                     outputByteCount: 32)
    }

    private static func seal(_ key: SymmetricKey) throws -> Data {
        // Usable from the first unlock on, while the screen is locked too, and on this Mac only.
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil)
        else { throw ClipboardVaultError.keyUnavailable(errSecParam) }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let oneOff = P256.KeyAgreement.PrivateKey()
        let plain = key.withUnsafeBytes { Data($0) }
        guard let sealedKey = try AES.GCM.seal(plain, using: wrappingKey(enclaveKey, oneOff.publicKey)).combined
        else { throw ClipboardVaultError.corrupt }
        return try PropertyListEncoder().encode(Sealed(enclaveKey: enclaveKey.dataRepresentation,
                                                       publicKey: oneOff.publicKey.rawRepresentation, sealedKey: sealedKey))
    }

    /// Fails on another Mac, or after this one's Secure Enclave was reset.
    private static func open(_ data: Data) throws -> SymmetricKey {
        do {
            let sealed = try PropertyListDecoder().decode(Sealed.self, from: data)
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: sealed.enclaveKey)
            let wrapping = try wrappingKey(enclaveKey, P256.KeyAgreement.PublicKey(rawRepresentation: sealed.publicKey))
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.sealedKey), using: wrapping)
            guard plain.count == 32 else { throw ClipboardVaultError.corrupt }
            return SymmetricKey(data: plain)
        } catch {
            throw ClipboardVaultError.keyUnavailable(errSecDecode)
        }
    }
}

/// Key in the login Keychain, readable only by this app's code signature. The file-based login
/// keychain ignores "this device only", so the key can travel with a keychain backup, like the
/// history; the data-protection keychain would need a provisioning profile.
struct PlainClipboardKey: Sendable {
    var service = bundleIdentifier + ".clipboard"
    var account = "history-key"
    var file: URL?

    /// A debug build keeps its key in a file: it's signed anew at every build, and the Keychain asks
    /// for the login password each time a build it doesn't know reads a key.
    static var app: PlainClipboardKey {
        #if DEBUG
        PlainClipboardKey(file: ClipboardVault.defaultDirectory().appendingPathComponent("test-build.key"))
        #else
        PlainClipboardKey()
        #endif
    }

    func loadOrCreate() throws -> SymmetricKey {
        if let existing = try load(asking: true) { return existing }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
            return key
        }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Underbrim clipboard history key",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClipboardVaultError.keyUnavailable(status) }
        return key
    }

    /// Without `asking`, a key macOS would ask about throws instead.
    func load(asking: Bool) throws -> SymmetricKey? {
        if let file {
            guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
            #if DEBUG
            // To check setting the history aside without a Keychain item.
            if !asking, ProcessInfo.processInfo.environment["UNDERBRIM_SIMULATE_LOCKED_CLIPBOARD_KEY"] == "1" {
                throw ClipboardVaultError.keyUnavailable(errSecInteractionNotAllowed)
            }
            #endif
            guard data.count == 32 else { throw ClipboardVaultError.keyUnavailable(errSecDecode) }
            return SymmetricKey(data: data)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = Self.keychain(asking: asking) { SecItemCopyMatching(query as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw ClipboardVaultError.keyUnavailable(status)
        }
        return SymmetricKey(data: data)
    }

    private static let silent = NSLock()

    func delete(asking: Bool) {
        if let file {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = Self.keychain(asking: asking) { SecItemDelete(query as CFDictionary) }
    }

    /// Without `asking`, what macOS would ask about fails instead. The file-based keychain ignores
    /// kSecUseAuthenticationUI; only this per-process switch keeps its dialogs away. Calls without
    /// asking go one at a time, so each puts back the switch as it found it.
    private static func keychain(asking: Bool, _ body: () -> OSStatus) -> OSStatus {
        guard !asking else { return body() }
        silent.lock()
        defer { silent.unlock() }
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }
}

/// Sealed files: `index.sealed` (entries incl. text) and `blobs/<id>.sealed`.
struct ClipboardVault: Sendable {
    let directory: URL
    let key: SymmetricKey

    private var indexURL: URL { directory.appendingPathComponent("index.sealed") }
    private var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    static func defaultDirectory() -> URL {
        #if DEBUG
        Relay.supportDirectory.appendingPathComponent("Clipboard-Debug", isDirectory: true)
        #else
        Relay.supportDirectory.appendingPathComponent("Clipboard", isDirectory: true)
        #endif
    }

    /// The history an earlier key opens, kept while macOS would ask about that key.
    static func earlierDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("Earlier", isDirectory: true)
    }

    /// Moves the history into `Earlier/`, images first so an index never goes without them, through
    /// the folders opened: by their paths, a link swapped in would have this move another folder.
    /// Nothing is moved over what's already there.
    static func setAside(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sealed").path) else { return }
        guard let fd = Relay.openOwnFolder(directory) else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
        defer { close(fd) }
        guard mkdirat(fd, "Earlier", 0o700) == 0 || errno == EEXIST else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
        let earlier = openat(fd, "Earlier", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard earlier >= 0 else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
        defer { close(earlier) }
        for name in ["blobs", "index.sealed"] {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }  // moved already
            // Something by that name there already: nothing is moved over it, and no new key is made.
            guard fstatat(earlier, name, &st, AT_SYMLINK_NOFOLLOW) != 0 else { throw ClipboardVaultError.keyUnavailable(errSecDuplicateItem) }
            guard renameat(fd, name, earlier, name) == 0 else { throw ClipboardVaultError.keyUnavailable(errSecIO) }
        }
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: blobDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Only on a folder of our own, through the folder opened: by its path,
        // a link swapped in would have these change another folder.
        guard let fd = Relay.openOwnFolder(directory) else { return }
        defer { close(fd) }
        fchmod(fd, 0o700)
        // Out of Time Machine, which also backs up the Keychain with the key: history deleted here
        // shouldn't come back from a backup.
        let exclude = try? PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
        exclude?.withUnsafeBytes { _ = fsetxattr(fd, "com.apple.metadata:com_apple_backup_excludeItem", $0.baseAddress, $0.count, 0, 0) }
    }

    func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw ClipboardVaultError.corrupt }
        return combined
    }

    func open(_ data: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        } catch {
            throw ClipboardVaultError.corrupt
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try seal(data).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// No index yet is an empty history. One that can't be read throws, so nothing is swept or saved over it.
    func loadEntries() throws -> [ClipboardEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let sealed = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([ClipboardEntry].self, from: open(sealed))
    }

    func saveEntries(_ entries: [ClipboardEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try write(encoder.encode(entries), to: indexURL)
    }

    private func blobURL(_ id: UUID) -> URL {
        blobDirectory.appendingPathComponent("\(id.uuidString).sealed")
    }

    func saveBlob(_ data: Data, for id: UUID) throws {
        try write(data, to: blobURL(id))
    }

    func hasBlob(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(id).path)
    }

    func loadBlob(for id: UUID) throws -> Data {
        guard let sealed = try? Data(contentsOf: blobURL(id)) else { throw ClipboardVaultError.corrupt }
        return try open(sealed)
    }

    func deleteBlob(for id: UUID) {
        try? FileManager.default.removeItem(at: blobURL(id))
    }

    func removeOrphanBlobs(keeping ids: Set<UUID>) {
        let kept = Set(ids.map { blobURL($0).lastPathComponent })
        Relay.removeEntries(in: blobDirectory) { Set($0.map(\.name)).subtracting(kept) }
    }
}
