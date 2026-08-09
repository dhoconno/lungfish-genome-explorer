// SQLiteTransient.swift - Shared SQLITE_TRANSIENT destructor constant
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SQLite3

/// Tells SQLite to copy bound bytes immediately, rather than trusting the caller to
/// keep the pointer valid until sqlite3_step()/sqlite3_reset() (F38). SQLite's own
/// `SQLITE_TRANSIENT` macro isn't imported into Swift, so every call site that binds a
/// transient C string needs this `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`
/// value; this is the single LungfishIO-module-internal definition (F53, round-2 repo
/// review fix campaign) that replaces the file-local copies previously hand-duplicated
/// across `ClassifierSQLiteDatabaseSupport`, `NaoMgsDatabase`, `NvdDatabase`,
/// `KrakenIndexDatabase`, `Kraken2Database`, `TaxTriageDatabase`, `EsVirituDatabase`,
/// `ProjectUniversalSearchIndex+SQL`, `NaoMgsBamMaterializer`,
/// `VariantDatabaseSQLiteSupport`, `MultipleSequenceAlignmentBundle+SQLite`,
/// `GenBankRecordDatabase`, `VariantDatabase+Cache`, `AlignmentMetadataDatabase`, and
/// `PhylogeneticTreeIndexWriter`.
///
/// Scoped `internal` (LungfishIO-only) per task instructions -- other modules that
/// define their own copy of this constant are out of scope for this consolidation.
let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
