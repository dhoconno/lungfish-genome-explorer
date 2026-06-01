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

    // MARK: - Trim Position Extraction

    /// Extracts trim positions by diffing original vs trimmed FASTQ records.
    ///
    /// For each read that appears in both files (matched by identifier), computes
    /// the trim boundaries by finding where the trimmed sequence aligns within
    /// the original sequence.
    ///
    /// For interleaved PE data where R1/R2 share the same base ID, uses a
    /// positional index to disambiguate (e.g., "SRR123.456#0" for R1,
    /// "SRR123.456#1" for R2). Since fastp with `--interleaved_in` preserves
    /// read order and drops both mates together, the positional correspondence
    /// between original and trimmed files is maintained.
    func extractTrimPositions(
        originalFASTQ: URL,
        trimmedFASTQ: URL
    ) async throws -> [FASTQTrimRecord] {
        // Build a lookup by base ID in a single pass.
        // Dictionary of arrays handles PE reads with same base ID (R1/R2).
        var trimmedByBaseID: [String: [(index: Int, record: FASTQRecord)]] = [:]
        var idx = 0
        let trimmedReader = FASTQReader(validateSequence: false)
        for try await record in trimmedReader.records(from: trimmedFASTQ) {
            let baseID = normalizedIdentifier(record.identifier)
            trimmedByBaseID[baseID, default: []].append((index: idx, record: record))
            idx += 1
        }

        // Stream through original and compute positions.
        // Track consumption index per base ID so we match R1→R1, R2→R2 in order.
        var consumedPerBaseID: [String: Int] = [:]
        let originalReader = FASTQReader(validateSequence: false)
        var records: [FASTQTrimRecord] = []
        var originalIndex = 0
        for try await original in originalReader.records(from: originalFASTQ) {
            let baseID = normalizedIdentifier(original.identifier)
            defer { originalIndex += 1 }

            // Find the next unconsumed trimmed record with this base ID
            let consumed = consumedPerBaseID[baseID] ?? 0
            guard let entries = trimmedByBaseID[baseID],
                  consumed < entries.count else { continue }
            let trimmed = entries[consumed].record
            consumedPerBaseID[baseID] = consumed + 1

            // Use positional key for the trim record to ensure uniqueness
            let pairOrdinal = consumed  // 0 = first occurrence (R1), 1 = second (R2), etc.
            let trimKey = "\(baseID)#\(pairOrdinal)"

            let trimStart: Int
            let trimEnd: Int

            if trimmed.sequence.isEmpty {
                continue
            } else if trimmed.sequence.count == original.sequence.count {
                trimStart = 0
                trimEnd = original.length
            } else {
                let origLen = original.sequence.count
                let trimLen = trimmed.sequence.count

                if original.sequence.hasSuffix(trimmed.sequence) {
                    trimStart = origLen - trimLen
                    trimEnd = origLen
                } else if original.sequence.hasPrefix(trimmed.sequence) {
                    trimStart = 0
                    trimEnd = trimLen
                } else {
                    var fivePrimeTrim = 0
                    let origChars = Array(original.sequence.utf8)
                    let trimChars = Array(trimmed.sequence.utf8)
                    let maxOffset = origLen - trimLen
                    for offset in 1...maxOffset {
                        if origChars[offset] == trimChars[0] &&
                           origChars[offset + trimLen - 1] == trimChars[trimLen - 1] {
                            var match = true
                            for i in 0..<trimLen {
                                if origChars[offset + i] != trimChars[i] {
                                    match = false
                                    break
                                }
                            }
                            if match {
                                fivePrimeTrim = offset
                                break
                            }
                        }
                    }
                    trimStart = fivePrimeTrim
                    trimEnd = fivePrimeTrim + trimLen
                }
            }

            records.append(FASTQTrimRecord(readID: trimKey, trimStart: trimStart, trimEnd: trimEnd))
        }
        return records
    }

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
