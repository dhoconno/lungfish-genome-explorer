// ProjectStorageRecordJSON.swift - The encoder of the cleanup journal, summaries and failure record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A cleanup journal, summary or failure record that `ProjectStorageRecordJSON` encodes.
///
/// Only the three types below adopt it. `ProvenanceEnvelope` never does, so an envelope handed to this encoder does
/// not compile, and every envelope is encoded by `ProvenanceWriter` (Q-A5).
protocol ProjectStorageRecordPayload: Encodable {}

extension ProjectStorageCleanupJournal: ProjectStorageRecordPayload {}
extension ProjectStorageCleanupExecutionSummary: ProjectStorageRecordPayload {}
extension ProjectStorageAutomaticCleanupFailureRecord: ProjectStorageRecordPayload {}

/// The one encoder of the cleanup records that are not envelopes.
///
/// It writes ISO 8601 dates, pretty-printed and sorted keys and unescaped slashes, the options of the provenance
/// encoder, so the bytes are those the base wrote. The preparation record names the journal's digest and size, and
/// the executor checks both before any item moves.
enum ProjectStorageRecordJSON {
    static func encode<Payload: ProjectStorageRecordPayload>(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}
