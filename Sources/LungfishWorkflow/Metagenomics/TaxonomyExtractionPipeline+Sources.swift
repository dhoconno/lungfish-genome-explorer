// TaxonomyExtractionPipeline+Sources.swift - A taxon's reads from every read file of a Kraken2 result, pairs first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension TaxonomyExtractionPipeline {

    /// One taxon's reads from every file of `files`, one output per file in
    /// order (``extractEachSource(config:tree:matePairStarts:progress:)``).
    /// Each R1 file and the R2 file after it are read in step, as kraken2
    /// read them, and every other file with seqkit grep. `config` gives the
    /// taxa, the classification output, and the folder and base name of the
    /// outputs. Its source files are `files`. `check` says whether every read
    /// the selection names was found with the length kraken2 recorded
    /// (``checkReads(_:of:named:matching:)``, BIO-READ-IDENTITY 4.1).
    func extractEachFile(
        config: TaxonomyExtractionConfig,
        files: [KrakenResultReadSources.File],
        tree: TaxonTree,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> (outputs: [URL?], taxIds: Set<Int>, readCount: Int, check: KrakenReadCheck) {
        for (index, file) in files.enumerated() where file.role == .r1 {
            guard index + 1 < files.count, files[index + 1].role == .r2 else {
                throw ClassifierExtractionError.kraken2SourceMissing
            }
        }
        let matePairStarts = files.indices.filter { files[$0].role == .r1 }
        let extraction = try await extractEachSource(
            config: TaxonomyExtractionConfig(
                taxIds: config.taxIds,
                includeChildren: config.includeChildren,
                sourceFiles: files.map(\.url),
                outputFiles: files.indices.map { _ in config.outputFile },
                classificationOutput: config.classificationOutput,
                taxonomyReport: config.taxonomyReport,
                keepReadPairs: config.keepReadPairs
            ),
            tree: tree,
            matePairStarts: matePairStarts,
            readLengths: true,
            progress: progress
        )
        let pairedRun = KrakenResultReadSources.classifiedPairs(in: config.classificationOutput)
        let check = try Self.checkReads(
            extraction.outputs, of: files, named: extraction.named,
            matching: config.keepReadPairs || pairedRun ? .fragmentName : .firstWord
        )
        return (extraction.outputs, extraction.taxIds, extraction.readCount, check)
    }

    /// Writes a taxon's reads, extracted file by file from `files`
    /// (``extractEachFile(config:files:tree:progress:)``): the pairs of each
    /// R1 and R2 file, each R1 record followed by its R2 record, to `pairs`,
    /// then the reads of every other file, in file order and unchanged, to
    /// `reads` (D7d). One handle may be both, since every pair of files comes
    /// before the other files. Returns the number of pairs.
    static func writeExtractedReads(
        _ outputs: [URL?],
        of files: [KrakenResultReadSources.File],
        pairs: FileHandle,
        reads: FileHandle
    ) throws -> Int {
        try writeExtractedReads(
            outputs,
            of: files,
            pairs: { try pairs.write(contentsOf: $0) },
            reads: { try reads.write(contentsOf: $0) }
        )
    }

    /// ``writeExtractedReads(_:of:pairs:reads:)`` into the stage files of two
    /// ``DurableReplace`` publications, so a failed write is a thrown error and
    /// each file is named only when it is whole and synced (Phase 2.10 lane
    /// S31).
    static func writeExtractedReads(
        _ outputs: [URL?],
        of files: [KrakenResultReadSources.File],
        pairs: DurableReplace.StageWriter,
        reads: DurableReplace.StageWriter
    ) throws -> Int {
        try writeExtractedReads(
            outputs,
            of: files,
            pairs: { chunk in try chunk.withUnsafeBytes { try pairs.write($0) } },
            reads: { chunk in try chunk.withUnsafeBytes { try reads.write($0) } }
        )
    }

    private static func writeExtractedReads(
        _ outputs: [URL?],
        of files: [KrakenResultReadSources.File],
        pairs: ([UInt8]) throws -> Void,
        reads: ([UInt8]) throws -> Void
    ) throws -> Int {
        var pairCount = 0
        for (index, file) in files.enumerated() {
            switch file.role {
            case .r1:
                guard let output = outputs[index] else { continue }
                pairCount += try copyRecords(of: output, into: pairs) / 2
            case .r2:
                continue
            case .adjacentMates, .reads:
                guard let output = outputs[index] else { continue }
                _ = try copyRecords(of: output, into: reads)
            }
        }
        return pairCount
    }

    /// Passes `file` to `write` unchanged, chunk by chunk, and returns its
    /// record count.
    private static func copyRecords(of file: URL, into write: ([UInt8]) throws -> Void) throws -> Int {
        let reader = try FASTQRawLineReader(url: file)
        defer { reader.close() }
        var lines = 0
        while let chunk = try reader.readChunk() {
            lines += chunk.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
            try write(chunk)
        }
        return lines / 4
    }

    /// How an extracted FASTQ pairs (D7d), counted over the whole file by
    /// the layout scan's pairing rule: interleaved when it holds only pairs,
    /// single-end with roles in the form a merge recipe records when it mixes
    /// pairs with single reads, and single-end when it holds no pair.
    static func extractedLayout(
        of fastqURL: URL,
        singleReadRole: ReadClassification.FileRole
    ) throws -> (mode: IngestionMetadata.PairingMode, roles: ReadClassification?) {
        let counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: fastqURL)
        guard counts.pairs > 0 else { return (.singleEnd, nil) }
        guard counts.singles > 0 else { return (.interleaved, nil) }
        let roles = FASTQMixedLayoutHint.classification(
            pairs: counts.pairs,
            singles: counts.singles,
            singleRole: singleReadRole,
            filename: fastqURL.lastPathComponent
        )
        return (.singleEnd, roles)
    }
}

extension KrakenResultReadSources {

    /// The role a mix of these files' pairs and single reads records for its
    /// single reads: merged when any file holds merged reads, else unpaired.
    static func singleReadFileRole(of files: [File]) -> ReadClassification.FileRole {
        files.contains { $0.singleReadRole == .merged || $0.singleReadRole == .mergedOrOrphan } ? .merged : .unpaired
    }
}
