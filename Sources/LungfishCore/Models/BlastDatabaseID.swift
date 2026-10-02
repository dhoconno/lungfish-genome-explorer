// BlastDatabaseID.swift - NCBI BLAST database identifiers submitted by the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The NCBI BLAST databases that Lungfish submits searches against.
///
/// The raw value is the exact string sent to NCBI, so it must not change.
public enum BlastDatabaseID: String, Sendable, CaseIterable {
    /// The NCBI core nucleotide collection used by every BLAST verification entry point.
    case coreNT = "core_nt"
}
