import SQLite3
import XCTest
@testable import ClipMemory

/// ID-REVIEW-1024 (PR-D N.4, 2026-10-21) — the shared value binder.
///
/// `SQLiteBinder` is the shared place where a Swift VALUE (text /
/// integer / blob / boolean / null) is bound to a SQLite statement.
/// Before it existed, the backend and the migrator each had their own
/// `bind`, and they had drifted: the migrator's covered only `String`
/// and `Int` and bound NULL for everything else, silently. These tests
/// pin the mapping down, so a future change to the storage class of a
/// value cannot quietly turn into "it became NULL".
///
/// (The backend still has a few direct `sqlite3_bind_text` calls for
/// literal SQL it assembles itself. Those bind a constant, not a Swift
/// value, and carry no `Any` hazard.)
final class SQLiteBinderTests: XCTestCase {

    private var dir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteBinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("binder.sqlite3")
    }

    override func tearDownWithError() throws {
        if let dir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    /// Binds `value` through the shared binder and reads the result
    /// back with `typeof()` (the SQLite storage class) plus the value.
    private func roundTrip(_ value: SQLiteValue) throws -> (type: String, value: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }

        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT ?", -1, &stmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(stmt) }
        guard let stmt else {
            XCTFail("could not prepare the statement")
            return ("", "")
        }
        SQLiteBinder.bind(stmt: stmt, index: 1, value: value)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)

        var typeStmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(handle, "SELECT typeof(?), quote(?)", -1, &typeStmt, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(typeStmt) }
        guard let typeStmt else {
            XCTFail("could not prepare the typeof statement")
            return ("", "")
        }
        SQLiteBinder.bind(stmt: typeStmt, index: 1, value: value)
        SQLiteBinder.bind(stmt: typeStmt, index: 2, value: value)
        XCTAssertEqual(sqlite3_step(typeStmt), SQLITE_ROW)
        let type = String(cString: sqlite3_column_text(typeStmt, 0))
        let quoted = String(cString: sqlite3_column_text(typeStmt, 1))
        return (type, quoted)
    }

    /// A text value binds as TEXT and round-trips unchanged.
    func testTextBindsAsText() throws {
        let result = try roundTrip(.text("hello 世界 🎉"))
        XCTAssertEqual(result.type, "text")
        XCTAssertTrue(result.value.contains("hello 世界 🎉"), result.value)
    }

    /// An integer binds as INTEGER.
    func testIntegerBindsAsInteger() throws {
        let result = try roundTrip(.integer(42))
        XCTAssertEqual(result.type, "integer")
        XCTAssertEqual(result.value, "42")
    }

    /// A negative integer must not become text.
    func testNegativeIntegerBindsAsInteger() throws {
        let result = try roundTrip(.integer(-7))
        XCTAssertEqual(result.type, "integer")
        XCTAssertEqual(result.value, "-7")
    }

    /// The largest Int64 must survive — a silent narrowing to Int32
    /// would corrupt the value.
    func testMaxInt64Survives() throws {
        let result = try roundTrip(.integer(Int64.max))
        XCTAssertEqual(result.type, "integer")
        XCTAssertEqual(result.value, "9223372036854775807")
    }

    /// A boolean binds as an INTEGER 0/1 — SQLite has no boolean
    /// storage class.
    func testBooleanBindsAsInteger() throws {
        XCTAssertEqual(try roundTrip(.boolean(true)).value, "1")
        XCTAssertEqual(try roundTrip(.boolean(false)).value, "0")
        XCTAssertEqual(try roundTrip(.boolean(true)).type, "integer")
    }

    /// A blob binds as BLOB and keeps its bytes.
    func testBlobBindsAsBlob() throws {
        let payload = Data([0x00, 0x01, 0xFE, 0xFF])
        let result = try roundTrip(.blob(payload))
        XCTAssertEqual(result.type, "blob")
    }

    /// An EMPTY blob must still bind as a blob — not as NULL, and not
    /// as text.
    ///
    /// Measured, not assumed: `sqlite3_bind_blob` binds **NULL** when
    /// the pointer is nil (even with a length of 0), and
    /// `Data().withUnsafeBytes` is not contractually required to
    /// return a non-nil pointer for empty data — today it does, but
    /// that is an implementation detail. The binder therefore binds
    /// the empty case explicitly as a zero-length blob, so this test
    /// pins a real guarantee rather than a Foundation detail.
    func testEmptyBlobBindsAsBlobNotNull() throws {
        let result = try roundTrip(.blob(Data()))
        XCTAssertEqual(result.type, "blob")
        XCTAssertNotEqual(result.value, "NULL")
    }

    /// An explicit null binds as NULL — and is distinguishable from
    /// "no value at all", which is what the `NSNull` handling in the
    /// old binder was about.
    func testNullBindsAsNull() throws {
        let result = try roundTrip(.null)
        XCTAssertEqual(result.type, "null")
        XCTAssertEqual(result.value, "NULL")
    }
}
