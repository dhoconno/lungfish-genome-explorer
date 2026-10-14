// PersistedEsVirituResult.swift - The JSON form of an EsViritu result sidecar
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - PersistedEsVirituResult

/// Codable representation of an EsViritu result for JSON serialization.
///
/// File paths are stored as relative filenames (not absolute paths) so the
/// sidecar remains valid if the output directory is moved.
struct PersistedEsVirituResult: Codable, Sendable {
    let config: EsVirituConfig
    let detectionPath: String
    let assemblyPath: String?
    let taxProfilePath: String?
    let coveragePath: String?
    let virusCount: Int
    let runtime: TimeInterval
    let toolVersion: String
    let provenanceId: UUID?
    let savedAt: Date
}
