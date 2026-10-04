// FASTQDerivativeService+TrimExtraction.swift - Trim position extraction + materialization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {
    // MARK: - Trim Materialization

    /// Materializes a trim derivative by applying trim positions to root FASTQ records.
    ///
    /// Handles both plain keys (`readID`) and positional keys (`readID#ordinal`)
    /// for PE interleaved data where R1/R2 share the same base ID.
    func extractTrimmedReads(
        fromRootFASTQ rootFASTQ: URL,
        positions: [String: (start: Int, end: Int)],
        outputFASTQ: URL
    ) async throws {
        if positions.isEmpty {
            throw FASTQDerivativeError.emptyResult
        }

        // Detect whether positions use positional keys (contain '#')
        let usesPositionalKeys = positions.keys.contains(where: { $0.contains("#") })

        let reader = FASTQReader(validateSequence: false)
        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        if usesPositionalKeys {
            // Track occurrence count per base ID to reconstruct positional keys
            var occurrencePerBaseID: [String: Int] = [:]
            for try await record in reader.records(from: rootFASTQ) {
                let baseID = normalizedIdentifier(record.identifier)
                let ordinal = occurrencePerBaseID[baseID] ?? 0
                occurrencePerBaseID[baseID] = ordinal + 1

                let key = "\(baseID)#\(ordinal)"
                guard let pos = positions[key] else { continue }
                let trimmed = record.trimmed(from: pos.start, to: pos.end)
                if trimmed.length > 0 {
                    try writer.write(trimmed)
                }
            }
        } else {
            // Legacy plain key mode (SE data or pre-PE-fix bundles)
            for try await record in reader.records(from: rootFASTQ) {
                let key = normalizedIdentifier(record.identifier)
                guard let pos = positions[key] else { continue }
                let trimmed = record.trimmed(from: pos.start, to: pos.end)
                if trimmed.length > 0 {
                    try writer.write(trimmed)
                }
            }
        }
    }
}
