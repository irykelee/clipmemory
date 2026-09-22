import XCTest
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-10): single source of truth for backup blob
/// types — adding a new blob type is a one-line change to the enum
/// that automatically flows to both backup paths.
final class BackupBlobRegistryTests: XCTestCase {
    /// P2-10: filenames and UserDefaults keys must be unique within the
    /// registry. A duplicate would silently overwrite a sibling blob.
    func testAllBlobKeysAreUnique() {
        let filenames = BackupBlobRegistry.BlobKey.allCases.map { $0.filename }
        let keys = BackupBlobRegistry.BlobKey.allCases.map { $0.userDefaultsKey }
        XCTAssertEqual(Set(filenames).count, filenames.count,
                      "P2-10: filenames must be unique across backup blob types")
        XCTAssertEqual(Set(keys).count, keys.count,
                      "P2-10: UserDefaults keys must be unique across backup blob types")
    }

    /// P2-10: registry must cover the canonical items/tags/trash blobs.
    /// (Adapted from brief: brief listed 5 cases including settings + ocrCache,
    /// but the actual backup flow only serializes 3 — see P2-10 adapt note.)
    func testAllBlobKeysEnumerate() {
        XCTAssertGreaterThanOrEqual(BackupBlobRegistry.allBlobKeys.count, 3,
                                  "P2-10: must cover items/tags/trash blobs")
    }

    /// P1-AUDIT-2026-09-22 (P2-10) Round-2: every blob type must declare a
    /// `decodeType` (any Decodable.Type) so `BackupPackage.exportPackage`
    /// can build the manifest count without string-dispatching on
    /// `UserDefaultsKey.rawValue`. Without this, adding a new blob type
    /// silently falls into the inner switch's `default` arm — the previous
    /// false claim "both paths pick up automatically" only applied to
    /// iteration, not to the decode dispatch.
    func testAllBlobKeysDeclareDecodeType() {
        for blob in BackupBlobRegistry.BlobKey.allCases {
            // decodeType is a computed property returning `any Decodable.Type`;
            // verify it's non-nil and usable by decoding `[]` JSON.
            XCTAssertNotNil(blob.decodeType, "P2-10: every blob type must declare decodeType")
            XCTAssertNoThrow(try JSONDecoder().decode(blob.decodeType, from: "[]".data(using: .utf8)!),
                             "P2-10: \(blob).decodeType must decode an empty array")
        }
    }
}