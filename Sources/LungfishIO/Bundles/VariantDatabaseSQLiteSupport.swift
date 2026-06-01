// VariantDatabaseSQLiteSupport.swift - SQLite binding helpers + logger
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

/// Logger for variant database operations
let variantDBLogger = Logger(subsystem: LogSubsystem.io, category: "VariantDatabase")

// MARK: - Safe SQLite Text Binding

/// The SQLITE_TRANSIENT destructor value, telling SQLite to copy the string immediately.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a Swift String to a SQLite prepared statement at the given parameter index.
///
/// Uses `withCString` to keep the C string alive for the duration of the bind call,
/// combined with `SQLITE_TRANSIENT` so SQLite copies the bytes immediately.
/// This prevents dangling pointer bugs from temporary NSString conversions.
func variantDBBindText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String) {
    _ = text.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }
}

/// Binds a Swift String to a SQLite prepared statement, or NULL if the string is nil.
func variantDBBindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
    if let text {
        variantDBBindText(stmt, index, text)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

func variantDBBindSmartBinding(_ stmt: OpaquePointer?, _ index: Int32, _ binding: VariantSmartBinding) {
    switch binding {
    case .text(let value):
        variantDBBindText(stmt, index, value)
    case .double(let value):
        sqlite3_bind_double(stmt, index, value)
    case .int(let value):
        sqlite3_bind_int64(stmt, index, Int64(value))
    }
}
