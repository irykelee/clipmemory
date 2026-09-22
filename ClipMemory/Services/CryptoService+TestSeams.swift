import Foundation
import Security

#if DEBUG
// P1-AUDIT-2026-09-22 (P2-3) test seams: KeyStoring conformers for
// prepareKey tests without touching the real Keychain. Kept in a
// separate file (not appended to CryptoService.swift) to honor the
// SwiftLint file_length cap (1250 lines). DEBUG-only — production
// never references these types.

// FailingKeychainStore: store() always fails so prepareKey's
// migration path is exercised without touching the real Keychain
// (which would trigger ACL prompts on a test runner). loadStatus
// returns .notFound to direct prepareKey into the file-migration
// branch; store throws KeyStoreError.classify(statusToReturn).
// P2-3 (OpenCode auto-review, 2026-09-23): tests can flip
// `statusToReturn` between transient codes (errSecInteractionNotAllowed,
// errSecAuthFailed, errSecNotAvailable) and permanent codes
// (errSecParam, errSecAllocate, etc.) to exercise both branches.
final class FailingKeychainStore: KeyStoring {
    var statusToReturn: OSStatus = errSecAuthFailed
    func load() -> Data? { nil }
    func loadStatus() -> KeychainLoadStatus { .notFound }
    @discardableResult
    func store(_ keyData: Data) throws {
        throw KeyStoreError.classify(statusToReturn)
    }
    func delete() {}
}

// InMemoryKeychainStore: in-memory KeyStoring for the happy-path
// regression guard. loadStatus returns .notFound when empty (so
// prepareKey falls into the migration branch) and .found when
// populated. store() throws nothing on success; load() returns the
// stored bytes so prepareKey's store+load verification passes.
// P2-3 (OpenCode auto-review, 2026-09-23): store signature changed
// from `-> OSStatus` to `throws` per the new KeyStoring contract.
final class InMemoryKeychainStore: KeyStoring {
    private var stored: Data?
    func load() -> Data? { stored }
    func loadStatus() -> KeychainLoadStatus {
        if let data = stored { return .found(data) }
        return .notFound
    }
    @discardableResult
    func store(_ keyData: Data) throws {
        stored = keyData
    }
    func delete() { stored = nil }
}
#endif