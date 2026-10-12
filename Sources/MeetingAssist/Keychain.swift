import Foundation
import MeetingCore
import Security

@MainActor
final class CredentialAccess {
    private let reader: () async throws -> String?
    private var cached: String?
    private var loading: Task<String?, Error>?
    private var generation = UUID()
    init(reader: @escaping () async throws -> String? = { try await Keychain.readAsync() }) {
        self.reader = reader
    }
    func load() async throws -> String? {
        if let cached { return cached }
        let run = generation
        let task = loading ?? Task { try await reader() }
        loading = task
        do {
            let value = try await task.value
            guard generation == run else { throw CancellationError() }
            cached = value
            loading = nil
            return value
        } catch {
            if generation == run { loading = nil }
            throw error
        }
    }
    func replace(with key: String?) {
        generation = UUID()
        loading?.cancel()
        loading = nil
        cached = key
    }
}

enum Keychain {
    private static let service = "com.akshay.meetingassist"
    static func contains(account: String = "openai") -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func readAsync(account: String = "openai") async throws -> String? {
        // Keychain authorization can wait for a user prompt. Keep the window responsive.
        try await Task.detached(priority: .userInitiated) { try read(account: account) }.value
    }
    static func read(account: String = "openai") throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MeetingError.message("Cannot read the API key from Keychain (\(status)).")
        }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, account: String = "openai") throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("sk-"), value.count > 20 else {
            throw MeetingError.message("Enter a valid OpenAI API key in this secure field.")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query.merging(attrs, uniquingKeysWith: { _, new in new })
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else {
                throw MeetingError.message("Cannot save to Keychain (\(result)).")
            }
        } else if status != errSecSuccess {
            throw MeetingError.message("Cannot update Keychain (\(status)).")
        }
    }
    static func delete(account: String = "openai") throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeetingError.message("Cannot remove the saved key (\(status)).")
        }
    }
}
