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

/// P2-3 (OpenCode auto-review, 2026-09-23): distinguishes transient Keychain
/// store failures (Keychain locked / unavailable / auth-failed — auto-retry
/// next launch will succeed; callers MUST preserve the fallback key file) from
/// permanent failures (everything else — Keychain definitively rejected the
/// request; no retry path; callers may delete the fallback file). This mirrors
/// `KeychainLoadStatus`'s `.interactionLocked` vs `.otherError` distinction:
/// before this classification, ANY store failure caused `CryptoService.prepareKey`
/// to delete `.encryption_key` permanently, destroying the only copy of the
/// root key when the failure was actually transient (errSecInteractionNotAllowed
/// at login/pre-first-unlock launch). Per the audit, that collapsed the
/// "transient-failure self-heals on retry" design into a data-loss event.
enum KeyStoreError: Error, Equatable {
    /// Auto-retry next launch will fix. Keep fallback key file. Examples:
    /// - errSecInteractionNotAllowed (-25308) — launchd start before unlock
    /// - errSecNotAvailable (-25291) — Keychain subsystem unavailable
    /// - errSecAuthFailed (-25293) — Keychain locked
    case transient(OSStatus)
    /// Keychain definitively rejected the request. No retry path. Caller
    /// may delete the fallback key file. Examples: errSecParam (-50),
    /// errSecAllocate (-108), errSecDecode, ACL violations, etc.
    case permanent(OSStatus)

    /// The underlying `OSStatus` (for logging / user-visible diagnostics).
    var status: OSStatus {
        switch self {
        case .transient(let s): return s
        case .permanent(let s): return s
        }
    }

    /// Maps a raw `OSStatus` to the typed classification. Tests use this
    /// directly to seed `FailingKeychainStore.statusToReturn`.
    static func classify(_ status: OSStatus) -> KeyStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed:
            return .transient(status)
        default:
            return .permanent(status)
        }
    }
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
    /// Throws `KeyStoreError` on failure (transient vs permanent classification
    /// per P2-3 OpenCode review, 2026-09-23). Success returns normally.
    @discardableResult
    func store(_ keyData: Data) throws
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
        // L-4 (2026-07-24 audit): prevent the system from showing an
        // authentication prompt on a miss / mismatch — the root key item
        // is `AfterFirstUnlockThisDeviceOnly` (no user auth) and an
        // unexpected prompt indicates something is wrong; fail fast
        // instead of blocking the calling thread on a modal.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
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
    func store(_ keyData: Data) throws {
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
        // P2-3 (OpenCode auto-review, 2026-09-23): throws KeyStoreError
        // (transient / permanent) instead of returning OSStatus, so callers
        // can keep vs delete the .encryption_key fallback based on whether
        // retry will help.
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus != errSecItemNotFound {
            if updateStatus != errSecSuccess {
                throw KeyStoreError.classify(updateStatus)
            }
            return
        }
        // SecItemAdd needs the full query (class/service/account) + value attrs.
        var addAttributes = baseQuery
        addAttributes[kSecValueData as String] = keyData
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addAttributes[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeyStoreError.classify(addStatus)
        }
    }

    func delete() {
        // ID-SILENT-0015 (2026-07-30 audit): surface the OSStatus. A
        // non-zero result here means the key wasn't actually removed,
        // which has security implications (stale key file still on disk,
        // keychain item still queryable). Callers (`CryptoService.prepareKey`
        // migration path, `Cask zap`) currently ignore the return; the
        // most important ones already check, but logging makes future
        // regressions visible.
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("KeychainKeyStore.delete failed: OSStatus %d", Int(status))
        }
    }
}
