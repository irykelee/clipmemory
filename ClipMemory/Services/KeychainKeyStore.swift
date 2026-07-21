import Foundation
import Security

/// Abstraction over the root-key store so tests can substitute in-memory
/// fakes and never touch the real Keychain or the real key file (C1).
protocol KeyStoring {
    /// Raw key bytes, or nil when absent/unreadable. Never throws — a
    /// Keychain error (denied ACL, locked keychain) is indistinguishable
    /// from "no key" for callers, which then fall back or regenerate.
    func load() -> Data?
    /// Persists key bytes, replacing any existing item.
    /// Returns errSecSuccess or a Keychain OSStatus.
    @discardableResult
    func store(_ keyData: Data) -> OSStatus
    func delete()
}

/// Stores the app's 32-byte root encryption key in the login keychain as a
/// generic password (C1). Replaces the pre-C1 plaintext key file: raw bytes
/// in `~/Library/Application Support` were readable by any process running
/// as the user (parent dir 0o755). This-device-only and available after
/// first unlock — never synced via iCloud, never leaving the machine.
struct KeychainKeyStore: KeyStoring {
    /// Production identity. Tests must pass their own service/account —
    /// overwriting the real item would make live history undecryptable.
    static let defaultService = "com.clipmemory.app"
    static let defaultAccount = "root-encryption-key"

    let service: String
    let account: String

    init(service: String = KeychainKeyStore.defaultService,
         account: String = KeychainKeyStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    func store(_ keyData: Data) -> OSStatus {
        // L-3: SecItemDelete + SecItemAdd had a non-atomic window — if
        // SecItemAdd failed (e.g. ACL violation), the previous key was
        // already deleted. Now try SecItemUpdate first (atomic at OS
        // level when item exists); fall back to SecItemAdd only when the
        // item is absent. Caller (CryptoService.prepareKey) keeps its
        // key-file fallback regardless — this only removes the delete
        // window inside this method.
        var attributes = baseQuery
        attributes[kSecValueData as String] = keyData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus != errSecItemNotFound {
            return updateStatus
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
