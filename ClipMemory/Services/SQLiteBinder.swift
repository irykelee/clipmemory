//
//  SQLiteBinder.swift
//  ClipMemory
//
//  ID-REVIEW-1024 (PR-D N.4, 2026-10-21): the shared SQLite value
//  binder.
//
//  Why it exists: the migrator and the backend each had their own
//  `bind`, and they had DIVERGED. The backend's covered String / Int
//  / Int64 / Data / Bool / NSNull; the migrator's covered only String
//  and Int and bound NULL for everything else — silently. A migration
//  step that needed a Data would have written NULL, and the failure
//  would have surfaced much later, in a query nobody was looking at.
//
//  One implementation, one set of supported types, one behaviour.
//
//  Why an enum and not `Any`: the parameter lists used to carry
//  `[(Int32, Any)]`, which erased the type at every call site and
//  forced the binder to keep a "what if it is none of these?" branch.
//  `SQLiteValue` makes the set of bindable values EXHAUSTIVE at
//  compile time — that branch is now impossible to write — and being
//  `Sendable`, it crosses a concurrency boundary without the compiler
//  losing the type check.
//

import Foundation
import SQLite3

/// A value bound to a SQLite statement.
enum SQLiteValue: Sendable {
    case text(String)
    case integer(Int64)
    case blob(Data)
    case boolean(Bool)
    /// An explicit SQL NULL.
    case null
}

/// Binds `SQLiteValue`s to SQLite statements.
enum SQLiteBinder {

    /// The destructor that tells SQLite to COPY the bound bytes.
    ///
    /// `SQLITE_TRANSIENT` is a C macro; Swift cannot import it as a
    /// constant, so it is rebuilt from its documented value (-1).
    static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Binds `value` to the statement at `index`.
    ///
    /// Exhaustive by construction: every case maps to exactly one
    /// SQLite storage class. There is no "unsupported" fallback —
    /// binding NULL for a value nobody recognised is how data goes
    /// quietly missing.
    static func bind(stmt: OpaquePointer, index: Int32, value: SQLiteValue) {
        switch value {
        case .text(let s):
            sqlite3_bind_text(stmt, index, s, -1, transientDestructor)
        case .integer(let i):
            sqlite3_bind_int64(stmt, index, i)
        case .blob(let d):
            // An EMPTY blob must bind as a blob, never as NULL.
            //
            // Measured, not assumed: `sqlite3_bind_blob` binds **NULL**
            // when the pointer is nil — even with a length of 0 — and
            // `Data().withUnsafeBytes` is not contractually required to
            // hand back a non-nil pointer for empty data (today it
            // does, but that is an implementation detail). Binding the
            // empty case EXPLICITLY means the guarantee does not
            // depend on that detail, and a future Foundation change
            // cannot turn an empty blob into a silently missing value.
            if d.isEmpty {
                sqlite3_bind_zeroblob(stmt, index, 0)
            } else {
                d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, index, ptr.baseAddress, Int32(d.count), transientDestructor)
                }
            }
        case .boolean(let b):
            sqlite3_bind_int(stmt, index, b ? 1 : 0)
        case .null:
            sqlite3_bind_null(stmt, index)
        }
    }
}
