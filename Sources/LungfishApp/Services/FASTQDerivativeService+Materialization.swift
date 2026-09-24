// FASTQDerivativeService+Materialization.swift - Materialization
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {

    // MARK: - Materialization

    func materializeDatasetFASTQ(
        fromBundle bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        let materializer = FASTQCLIMaterializer(runner: runner)
        return try await materializer.materialize(
            bundleURL: bundleURL,
            tempDirectory: tempDirectory,
            progress: progress
        )
    }

    func writeOrientedPreviewFASTQ(
        fromSourceFASTQ sourceFASTQ: URL,
        orientMapURL: URL,
        outputFASTQ: URL,
        readLimit: Int = 1_000
    ) async throws {
        let orientContent = try String(contentsOf: orientMapURL, encoding: .utf8)
        var orderedReadIDs: [String] = []
        var rcReadIDs: Set<String> = []

        for line in orientContent.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let readID = String(fields[0])
            orderedReadIDs.append(readID)
            if fields[1] == "-" {
                rcReadIDs.insert(readID)
            }
            if orderedReadIDs.count >= max(1, readLimit) {
                break
            }
        }

        guard !orderedReadIDs.isEmpty else { return }

        let selectedReadIDs = Set(orderedReadIDs)
        var previewRecords: [String: FASTQRecord] = [:]
        let reader = FASTQReader(validateSequence: false)

        for try await record in reader.records(from: sourceFASTQ) {
            let readID = normalizedIdentifier(record.identifier)
            guard selectedReadIDs.contains(readID) else { continue }

            if rcReadIDs.contains(readID) {
                previewRecords[readID] = record.reverseComplement()
            } else {
                previewRecords[readID] = record
            }

            if previewRecords.count == selectedReadIDs.count {
                break
            }
        }

        let writer = FASTQWriter(url: outputFASTQ)
        try writer.open()
        defer { try? writer.close() }

        for readID in orderedReadIDs {
            if let record = previewRecords[readID] {
                try writer.write(record)
            }
        }
    }

    /// Detects mate number from FASTQ record header for PE-safe trim lookup.
    /// Returns (baseReadID, mate) where mate is 0 (single), 1 (R1), or 2 (R2).
    /// Strips `/1` or `/2` suffix from identifier when present so the returned
    /// readID matches the pipeline's trim map keys.
    func detectMateFromHeader(identifier: String, description: String?) -> (readID: String, mate: Int) {
        // Check /1 or /2 suffix on identifier (legacy FASTQ format)
        if identifier.hasSuffix("/1") {
            return (String(identifier.dropLast(2)), 1)
        }
        if identifier.hasSuffix("/2") {
            return (String(identifier.dropLast(2)), 2)
        }
        // Check Illumina description format: "1:N:0:..." or "2:N:0:..."
        if let desc = description {
            if desc.hasPrefix("1:") { return (identifier, 1) }
            if desc.hasPrefix("2:") { return (identifier, 2) }
        }
        return (identifier, 0)
    }
}
