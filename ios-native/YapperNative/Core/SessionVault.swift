import Foundation
import Security

@MainActor protocol SessionVault {
    func read() throws -> NativeSession?
    func save(_ session: NativeSession) throws
    func clear() throws
}

/// Tokens are device-only and never enter UserDefaults, backups, or app-group storage.
@MainActor final class KeychainSessionVault: SessionVault {
    private let service = "website.yapper.native.ios.session"
    private let account = "current-user"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> NativeSession? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NativeClientError.keychain(status) }
        guard let data = item as? Data else { throw NativeClientError.invalidResponse }
        do { return try JSONDecoder().decode(NativeSession.self, from: data) }
        catch { throw NativeClientError.malformedResponse("Stored session") }
    }

    func save(_ session: NativeSession) throws {
        let data = try JSONEncoder().encode(session)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NativeClientError.keychain(status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeClientError.keychain(status) }
    }
}

@MainActor final class MemorySessionVault: SessionVault {
    private(set) var session: NativeSession?
    init(session: NativeSession? = nil) { self.session = session }
    func read() -> NativeSession? { session }
    func save(_ session: NativeSession) { self.session = session }
    func clear() { session = nil }
}
