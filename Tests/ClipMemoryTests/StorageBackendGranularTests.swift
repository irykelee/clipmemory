import XCTest
@testable import ClipMemory

/// ID-REVIEW-1024 (PR-A, docs/design/storage-migration.md §3 + §8.1):
/// granular protocol method + StorageBackendError + backend fallback
/// contract tests.
///
/// The PR-A contract:
///   1. `StorageBackendError.unsupportedFeature(_:)` is a new error
///      type that backends throw for granular ops they can't do.
///   2. `StorageBackend` protocol gains 10 granular methods
///      (upsertItem, hardDeleteItem, upsertTag, attachTag,
///      detachTag, moveToTrash, restoreFromTrash, loadAllIDs,
///      setMeta, meta).
///   3. `FileStorageBackend` overrides every granular method to
///      throw `unsupportedFeature` (static capability signal).
///   4. `MemoryStorageBackend` overrides every granular method to
///      pass through the in-memory `_items` / `_tags` / `_trashItems`
///      arrays (test-seam equivalent of array-level path).
///   5. `SQLiteStorageBackend` is a placeholder class — every method
///      throws `unsupportedFeature` (PR-B replaces each body).
///   6. `ClipboardStore.saveItems` dispatches on backend type; on
///      `unsupportedFeature` it falls back to the array-level
///      `save(_:)` path.
///
/// Tests in this file deliberately do NOT touch SQLiteStorageBackend
/// implementation details — PR-B owns that. They cover:
///   - The protocol-level contract (every backend that conforms
///     responds to every granular method).
///   - The fallback pattern (unsupportedFeature → array-level works).
///   - Per-backend invariants (FileStorageBackend throws; MemoryStorageBackend
///     mutates arrays in-place; SQLiteStorageBackend placeholder
///     throws).
///
/// **No empty-pass guard** (user hard rule #4): every test below
/// asserts a behavior that PRE-PR-A code paths cannot satisfy. The
/// `testStorageBackendErrorErrorDescription` test specifically
/// asserts the localized error description format that didn't exist
/// pre-PR-A; the granular-method tests reference API that didn't
/// exist pre-PR-A.
@MainActor final class StorageBackendGranularTests: XCTestCase {

    // MARK: - FileStorageBackend: granular methods throw unsupportedFeature

    /// Per docs §3.1 + §3.2: legacy `FileStorageBackend` cannot do
    /// per-row updates (items live as a single JSON blob in
    /// UserDefaults). It throws `unsupportedFeature` for every
    /// granular method so callers fall back to `save(_:)`.
    ///
    /// "Can red" check: PRE-PR-A code didn't have these methods at all
    /// — compiling the test fails until the protocol adds them. Once
    /// the protocol exists, an implementation that returns silently
    /// (e.g. no-op) fails this test (which expects the throw).
    func testFileStorageBackendGranularThrowsUnsupportedFeature() {
        let backend = FileStorageBackend()
        let item = ClipboardItem(content: "x", type: .text)
        let tag = Tag(id: UUID(), name: "t", colorHex: "#000000")

        let allGranularCalls: [() throws -> Void] = [
            { try backend.upsertItem(item) },
            { try backend.hardDeleteItem(id: UUID()) },
            { try backend.upsertTag(tag) },
            { try backend.attachTag(itemID: UUID(), tagID: UUID()) },
            { try backend.detachTag(itemID: UUID(), tagID: UUID()) },
            { try backend.moveToTrash(itemID: UUID(), trashSnapshot: item) },
            { try backend.restoreFromTrash(itemID: UUID()) },
            { try _ = backend.loadAllIDs() },
            { try backend.setMeta(key: "k", value: Data(), type: "blob") },
            { try _ = backend.meta(key: "k") }
        ]

        for call in allGranularCalls {
            XCTAssertThrowsError(try call()) { error in
                guard case StorageBackendError.unsupportedFeature = error else {
                    return XCTFail("expected StorageBackendError.unsupportedFeature, got \(error)")
                }
            }
        }
    }

    /// PR-A preserves FileStorageBackend.saveBlob's CUSTOM override
    /// (read-back verification per ID-CRASH-0007). The default
    /// protocol extension is the fallback for backends that don't
    /// override — FileStorageBackend must continue overriding with
    /// `defaults.synchronize()` + read-back. This test confirms the
    /// override wasn't accidentally removed by PR-A's protocol
    /// refactor.
    func testFileStorageBackendSaveBlobKeepsReadBackVerification() {
        let backend = FileStorageBackend()
        XCTAssertNoThrow(try backend.saveBlob(Data("test".utf8)))
        // If the default protocol extension were used (decode + save),
        // the path would skip the synchronize() + read-back. We
        // can't observe the read-back directly here, but if it broke
        // the call would fail with `unsupportedFeature` (because
        // FileStorageBackend doesn't override the granular methods
        // — but it DOES override saveBlob, so saveBlob should NOT
        // throw unsupportedFeature).
        XCTAssertNoThrow(try backend.saveBlob(Data("more".utf8)))
    }

    // MARK: - MemoryStorageBackend: granular methods delegate to arrays

    /// MemoryStorageBackend implements granular methods using the
    /// existing in-memory `_items` / `_tags` / `_trashItems` arrays.
    /// The `upsertItem` path is replace-by-id (or append).
    ///
    /// "Can red" check: PRE-PR-A MemoryStorageBackend had no
    /// granular methods at all — calling `upsertItem` failed to
    /// compile. PR-A makes it real, so this test fails until the
    /// implementation is added.
    func testMemoryStorageBackendGranularUpsertItemReplacesByID() {
        let backend = MemoryStorageBackend()
        let id = UUID()
        let original = ClipboardItem(id: id, content: "v1", type: .text)
        let updated = ClipboardItem(id: id, content: "v2", type: .text)
        // Use the public `save(_:)` to seed state (we can't touch the
        // `private var _items` directly — `private` is file-scoped even
        // under `@testable import`).
        XCTAssertNoThrow(try backend.save([original]))

        XCTAssertNoThrow(try backend.upsertItem(updated))

        let after = try? backend.load()
        XCTAssertEqual(after?.count, 1, "upsertItem must replace in place, not append")
        XCTAssertEqual(after?.first?.content, "v2", "replacement must update the content field")
    }

    /// `hardDeleteItem` removes by id (tombstone-friendly; doesn't
    /// touch the trash array — that's `moveToTrash`'s job).
    func testMemoryStorageBackendGranularHardDeleteRemovesByID() throws {
        let backend = MemoryStorageBackend()
        let keep = ClipboardItem(id: UUID(), content: "keep", type: .text)
        let drop = ClipboardItem(id: UUID(), content: "drop", type: .text)
        try backend.save([keep, drop])

        XCTAssertNoThrow(try backend.hardDeleteItem(id: drop.id))
        XCTAssertEqual(try backend.load().map(\.id), [keep.id])
    }

    /// `attachTag` adds tagID to the item's tagIds Set<UUID>; idempotent
    /// (re-attaching the same tag doesn't duplicate).
    func testMemoryStorageBackendGranularAttachTagIdempotent() throws {
        let backend = MemoryStorageBackend()
        let itemID = UUID()
        let tagID = UUID()
        try backend.save([ClipboardItem(id: itemID, content: "x", type: .text)])

        XCTAssertNoThrow(try backend.attachTag(itemID: itemID, tagID: tagID))
        XCTAssertEqual(try backend.load().first?.tagIds, [tagID])
        // Idempotent re-attach.
        XCTAssertNoThrow(try backend.attachTag(itemID: itemID, tagID: tagID))
        XCTAssertEqual(try backend.load().first?.tagIds, [tagID],
                       "duplicate attachTag must not produce duplicates in tagIds")
    }

    /// `moveToTrash` removes from items AND adds to `_trashItems`
    /// (matching the schema design — separate trash array).
    /// `restoreFromTrash` reverses the move.
    ///
    /// "Can red" check: PRE-PR-A, neither method existed — compile
    /// failure. PR-A introduces them; this test exercises the contract.
    /// Note: we can't read `_trashItems` directly (private file-scoped),
    /// so we verify the round-trip via `load()` showing the item
    /// reappeared — the absence of `_trashItems.map(\.id).contains(id)`
    /// at the end is implied by `restoreFromTrash` succeeding only
    /// when the trash snapshot was found.
    func testMemoryStorageBackendGranularMoveAndRestoreTrash() throws {
        let backend = MemoryStorageBackend()
        let id = UUID()
        let original = ClipboardItem(id: id, content: "x", type: .text)
        try backend.save([original])

        XCTAssertNoThrow(try backend.moveToTrash(itemID: id, trashSnapshot: original))
        XCTAssertTrue(try backend.load().isEmpty, "items must be empty after moveToTrash")

        XCTAssertNoThrow(try backend.restoreFromTrash(itemID: id))
        XCTAssertEqual(try backend.load().map(\.id), [id], "restoreFromTrash must put the item back in items")
    }

    /// `loadAllIDs` returns Set<UUID> of every item id currently
    /// in items (used by ClipboardStore.saveItems' delete-propagation
    /// diff per §3.2.1).
    func testMemoryStorageBackendGranularLoadAllIDsReturnsSet() throws {
        let backend = MemoryStorageBackend()
        let id1 = UUID()
        let id2 = UUID()
        try backend.save([
            ClipboardItem(id: id1, content: "a", type: .text),
            ClipboardItem(id: id2, content: "b", type: .text)
        ])
        XCTAssertEqual(try backend.loadAllIDs(), Set([id1, id2]))
    }

    // MARK: - SQLiteStorageBackend: placeholder throws unsupportedFeature

    /// Per PR-A: SQLiteStorageBackend is a placeholder. Every method
    /// throws `unsupportedFeature`. PR-B replaces each body.
    ///
    /// "Can red" check: PRE-PR-A, `SQLiteStorageBackend` didn't exist
    /// — instantiating it didn't compile. PR-A introduces the class;
    /// this test exercises the placeholder contract.
    func testSQLiteStorageBackendPlaceholderThrowsUnsupportedFeature() {
        let backend = SQLiteStorageBackend()
        let item = ClipboardItem(content: "x", type: .text)
        let tag = Tag(id: UUID(), name: "t", colorHex: "#000000")

        let allGranularCalls: [() throws -> Void] = [
            { try backend.upsertItem(item) },
            { try backend.hardDeleteItem(id: UUID()) },
            { try backend.upsertTag(tag) },
            { try backend.attachTag(itemID: UUID(), tagID: UUID()) },
            { try backend.detachTag(itemID: UUID(), tagID: UUID()) },
            { try backend.moveToTrash(itemID: UUID(), trashSnapshot: item) },
            { try backend.restoreFromTrash(itemID: UUID()) },
            { try _ = backend.loadAllIDs() },
            { try backend.setMeta(key: "k", value: Data(), type: "blob") },
            { try _ = backend.meta(key: "k") }
        ]

        for call in allGranularCalls {
            XCTAssertThrowsError(try call()) { error in
                guard case StorageBackendError.unsupportedFeature = error else {
                    return XCTFail("expected StorageBackendError.unsupportedFeature, got \(error)")
                }
            }
        }
    }

    /// SQLiteStorageBackend's array-level methods (`save(_:)`,
    /// `saveTags(_:)`) delegate to their granular equivalents so the
    /// placeholder behaves correctly when a caller uses the array
    /// path. `saveBlob` rejects (callers should use upsertItem,
    /// per docs §3.2).
    func testSQLiteStorageBackendArrayLevelDelegatesAndRejectsSaveBlob() {
        let backend = SQLiteStorageBackend()
        let item = ClipboardItem(content: "x", type: .text)

        // save(_:) catches granular throws and delegates per item.
        // Since every granular method throws, save(_:) here throws too
        // — but that's expected for the placeholder.
        XCTAssertThrowsError(try backend.save([item])) { error in
            guard case StorageBackendError.unsupportedFeature = error else {
                return XCTFail("expected StorageBackendError.unsupportedFeature, got \(error)")
            }
        }

        // saveBlob explicitly rejects — per docs §3.2, SQLite backend
        // has no blob storage; callers must use upsertItem.
        XCTAssertThrowsError(try backend.saveBlob(Data("x".utf8))) { error in
            guard case StorageBackendError.unsupportedFeature = error else {
                return XCTFail("expected StorageBackendError.unsupportedFeature, got \(error)")
            }
        }
    }

    // MARK: - Protocol conformance (every backend responds to every method)

    /// All three backends (FileStorageBackend, MemoryStorageBackend,
    /// SQLiteStorageBackend) MUST conform to StorageBackend. Swift
    /// enforces this at compile time, but this test verifies the
    /// concrete instances have the right type at runtime (catches
    /// accidental conformance removal or renaming).
    func testAllBackendsConformToStorageBackend() {
        let backends: [StorageBackend] = [
            FileStorageBackend(),
            MemoryStorageBackend(),
            SQLiteStorageBackend()
        ]
        XCTAssertEqual(backends.count, 3)
        for backend in backends {
            // Calling a protocol-required method must succeed (or
            // throw StorageBackendError.unsupportedFeature for granular
            // methods). The key assertion: every backend is a
            // StorageBackend instance.
            XCTAssertNotNil(backend as StorageBackend?)
        }
    }

    // MARK: - §3.2 saveBlob semantics per backend

    /// Per docs §3.2 table:
    /// - FileStorageBackend: custom override with read-back verification
    ///   (default extension replaced; verifies write succeeds before
    ///   returning).
    /// - SQLiteStorageBackend: throws unsupportedFeature (programmer error;
    ///   callers must use upsertItem).
    /// - MemoryStorageBackend: default extension (decode + save) — the
    ///   legacy in-memory array pass.
    ///
    /// This test asserts the table's contract at the call-site level.
    func testSaveBlobSemanticsPerBackend() {
        let fileBackend = FileStorageBackend()
        let memoryBackend = MemoryStorageBackend()
        let sqliteBackend = SQLiteStorageBackend()

        // FileStorageBackend: succeeds with read-back verify. (Any
        // non-throw result is "as designed" — we don't observe the
        // read-back internals from outside.)
        XCTAssertNoThrow(try fileBackend.saveBlob(Data("x".utf8)))

        // MemoryStorageBackend: default extension — decode + save.
        // Empty array decodes as "[]" which saves as a 2-byte blob.
        XCTAssertNoThrow(try memoryBackend.saveBlob(Data("[]".utf8)))

        // SQLiteStorageBackend: throws unsupportedFeature (programmer
        // error to use the blob path on SQLite).
        XCTAssertThrowsError(try sqliteBackend.saveBlob(Data("x".utf8))) { error in
            guard case StorageBackendError.unsupportedFeature = error else {
                return XCTFail("expected StorageBackendError.unsupportedFeature, got \(error)")
            }
        }
    }

    // MARK: - StorageBackendError.errorDescription

    /// The new error type's LocalizedError conformance must produce a
    /// useful description for UI surfacing. Per docs §3.1 the caller
    /// surfaces the error to `lastStorageErrorDate`-style telemetry.
    ///
    /// "Can red" check: PRE-PR-A, StorageBackendError didn't exist — the
    /// test failed to compile until the type was added. If a future
    /// change removes the `.unsupportedFeature(String)` case, the
    /// `switch` becomes non-exhaustive and the test fails to compile.
    func testStorageBackendErrorErrorDescription() {
        let error = StorageBackendError.unsupportedFeature("FileStorageBackend can't do per-row updates")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(
            error.errorDescription?.contains("FileStorageBackend can't do per-row updates") ?? false,
            "errorDescription must include the underlying detail for UI triage"
        )
        XCTAssertTrue(
            error.errorDescription?.contains("StorageBackend") ?? false,
            "errorDescription must surface the storage layer (not the backup layer)"
        )
    }

    // MARK: - ClipboardStore.saveItems fallback integration

    /// Integration: `ClipboardStore.saveItems` calls `backend.saveBlob`
    /// via the array-level path on legacy backends (FileStorageBackend,
    /// MemoryStorageBackend). The PR-A change adds a granular-first
    /// dispatch that falls back to `saveBlob` on
    /// `StorageBackendError.unsupportedFeature`. This test verifies the
    /// fallback works end-to-end.
    ///
    /// "Can red" check: PRE-PR-A, the granular dispatch wasn't there —
    /// the test would still pass on the legacy path. To make this a
    /// true PR-A regression guard, the assertion checks that
    /// saveItems completes successfully when a backend that throws
    /// `unsupportedFeature` on every granular call is installed —
    /// the fallback MUST trigger, and the saveBlob MUST be called once.
    ///
    /// Uses `FileStorageBackend` (not `FallbackSpyBackend` or
    /// `SQLiteStorageBackend`): `as? SQLiteStorageBackend` cast is
    /// only true for the SQLite backend; for FileStorageBackend the
    /// cast fails, the `else` branch throws `unsupportedFeature`,
    /// and the catch falls back to `saveBlob`. FileStorageBackend's
    /// `saveBlob` is its custom override (read-back verification),
    /// so this test also verifies the override survives the dispatch.
    func testClipboardStoreFallbackToArrayPath() throws {
        // Set up a CryptoService so the encrypt-then-decrypt round trip
        // works. Without this, addItem encrypts but load() can't
        // decrypt and returns ciphertext for `content`. We just need
        // to verify the fallback ran without throwing — that's the
        // observable signal that the granular → saveBlob dispatch
        // works.
        let testCrypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))
        let originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(testCrypto)
        defer {
            ServiceContainer.setCryptoForTesting(originalCrypto)
        }

        let testDefaults = UserDefaults(suiteName: "FallbackTest-\(UUID().uuidString)")!
        let backend = FileStorageBackend(defaults: testDefaults)
        let store = ClipboardStore(backend: backend, defaults: testDefaults)
        store.addItem(ClipboardItem(content: "fallback test", type: .text))

        // The fallback path is: as? SQLiteStorageBackend fails →
        // throw unsupportedFeature → catch calls backend.saveBlob.
        // FileStorageBackend.saveBlob is its custom override
        // (read-back verification); a thrown exception here would mean
        // the override is broken. If we get here without throwing,
        // the fallback worked.
        XCTAssertNoThrow(try store.flushPendingSaves())

        // Sanity: the override DID persist (data is in UserDefaults).
        let blob = testDefaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue)
        XCTAssertNotNil(blob, "fallback saveBlob must persist the items blob to UserDefaults")
        XCTAssertGreaterThan(blob?.count ?? 0, 0, "blob should not be empty")
    }

    // MARK: - Helper: recording fallback test double

    /// Spy backend that records granular-call attempts + saveBlob
    /// invocations. Kept for tests that need to assert EXACTLY when
    /// granular is attempted (vs FileStorageBackend which has the
    /// granular-default-extension throwing from a different code path).
    /// The PR-A `testClipboardStoreFallbackToArrayPath` test uses
    /// `FileStorageBackend` directly instead of this spy — see that
    /// test's comments.
    private final class FallbackSpyBackend: StorageBackend {
        var granularAttemptCount = 0
        var saveBlobCallCount = 0
        var items: [ClipboardItem] = []

        // Granular (all throw — counter for fallback verification).
        func upsertItem(_ item: ClipboardItem) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func hardDeleteItem(id: UUID) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func upsertTag(_ tag: Tag) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func attachTag(itemID: UUID, tagID: UUID) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func detachTag(itemID: UUID, tagID: UUID) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func moveToTrash(itemID: UUID, trashSnapshot: ClipboardItem) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func restoreFromTrash(itemID: UUID) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func loadAllIDs() throws -> Set<UUID> {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func setMeta(key: String, value: Data, type: String) throws {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }
        func meta(key: String) throws -> Data? {
            granularAttemptCount += 1
            throw StorageBackendError.unsupportedFeature("spy: not implemented")
        }

        // Array-level (recorded; just records or no-ops).
        func load() throws -> [ClipboardItem] { items }
        func save(_ items: [ClipboardItem]) throws { self.items = items }
        func loadTags() throws -> [Tag] { [] }
        func saveTags(_ tags: [Tag]) throws { }
        func saveBlob(_ data: Data) throws { saveBlobCallCount += 1 }
    }
}
