import Foundation
import Security

/// C-2 (2026-07-24 audit): distinguishes Keychain load outcomes so callers
/// can avoid the data-loss path where a locked Keychain is misread as
/// "no key" and the app silently regenerates + overwrites the existing
/// item. Maps the SecItemCopyMatching OSStatus to a typed result.
enum KeychainLoadStatus {
    /// errSecItemNotFound — no item, caller may generate or migrate.
    case notFound
    /// errSecInteractionNotAllowed — item exists but the keychain is
    /// locked (typical for launchd-started processes pre-unlock, or
    /// "open at login" launches). Caller MUST NOT regenerate.
    case interactionLocked
    /// errSecSuccess with valid data.
    case found(Data)
    /// Any other OSStatus (parameter error, decode failure, etc).
    case otherError(OSStatus)
}

/// Abstraction over the root-key store so tests can substitute in-memory
/// fakes and never touch the real Keychain or the real key file (C1).
protocol KeyStoring {
    /// Raw key bytes, or nil when absent/unreadable. Never throws — a
    /// Keychain error (denied ACL, locked keychain) is indistinguishable
    /// from "no key" for callers, which then fall back or regenerate.
    func load() -> Data?
    /// C-2: typed view of the Keychain load result. Preferred over `load()`
    /// in paths that must NOT regenerate (i.e. `CryptoService.prepareKey`),
    /// so a locked Keychain (`interactionLocked`) is not mistaken for
    /// `notFound`.
    func loadStatus() -> KeychainLoadStatus
    /// Persists key bytes, replacing any existing item.
    /// Returns errSecSuccess or a Keychain OSStatus.
    @discardableResult
    func store(_ keyData: Data) -> OSStatus
    func delete()
}

extension KeyStoring {
    /// Default for stores that cannot distinguish locked from not-found
    /// (in-memory test fakes, encrypted-file fallbacks). Real Keychain
    /// conformers (`KeychainKeyStore`) MUST override to surface
    /// `errSecInteractionNotAllowed` as `.interactionLocked` — C-2 callers
    /// rely on that distinction to avoid regenerating the user's key.
    func loadStatus() -> KeychainLoadStatus {
        if let data = load() { return .found(data) }
        return .notFound
    }
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
        switch loadStatus() {
        case .found(let data): return data
        default: return nil
        }
    }

    func loadStatus() -> KeychainLoadStatus {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .otherError(status) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .interactionLocked
        default:
            return .otherError(status)
        }
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
        // BUG-019 (2026-07-21): attributesToUpdate must NOT include
        // kSecClass — the query attribute is the 1st arg, the update
        // payload is the 2nd. Apple docs are ambiguous; current macOS
        // silently accepts, but defensive split avoids errSecParam risk
        // on older Security frameworks.
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus != errSecItemNotFound {
            return updateStatus
        }
        // SecItemAdd needs the full query (class/service/account) + value attrs.
        var addAttributes = baseQuery
        addAttributes[kSecValueData as String] = keyData
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addAttributes[kSecAttrSynchronizable as String] = false
        return SecItemAdd(addAttributes as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
