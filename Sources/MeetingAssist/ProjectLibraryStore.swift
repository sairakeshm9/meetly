import CryptoKit
import Foundation
import MeetingCore
import Security

/// Only explicit Save/Load actions touch the encryption key. Meeting transcripts are never saved here.
struct ProjectLibraryStore {
    let url: URL
    let key: () throws -> SymmetricKey
    init(url: URL? = nil, key: (() throws -> SymmetricKey)? = nil) {
        self.url =
            url
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Meeting Assist/project-library.encrypted")
        self.key = key ?? Self.libraryKey
    }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    func save(_ library: ProjectLibrary) throws {
        let bytes = try JSONEncoder().encode(library)
        guard bytes.count <= 300000 else {
            throw MeetingError.message("Project library too large. Shorten your notes.")
        }
        guard let sealed = try AES.GCM.seal(bytes, using: key()).combined else {
            throw MeetingError.message("Could not protect project library.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func load() throws -> ProjectLibrary {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= 300100 else {
            throw MeetingError.message("Saved library invalid. Delete it and save again.")
        }
        return try JSONDecoder().decode(
            ProjectLibrary.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key()))
    }
    func delete() throws { if exists { try FileManager.default.removeItem(at: url) } }
    private static func libraryKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.akshay.meetingassist",
            kSecAttrAccount as String: "project-library-encryption", kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            throw MeetingError.message(
                "Project library Keychain access unavailable. Approve access locally and retry.")
        }
        let key = SymmetricKey(size: .bits256)
        var insert = query
        insert.removeValue(forKey: kSecReturnData as String)
        insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw MeetingError.message("Could not save project encryption key in Keychain.")
        }
        return key
    }
}
