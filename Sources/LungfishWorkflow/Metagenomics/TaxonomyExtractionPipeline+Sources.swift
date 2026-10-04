// TaxonomyExtractionPipeline+Sources.swift - A taxon's reads from every read file of a Kraken2 result, pairs first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension TaxonomyExtractionPipeline {

    /// Writes a taxon's reads, extracted file by file from `files`
    /// (``extractEachSource(config:tree:progress:)``): each pair's R1 record
    /// followed by its R2 record to `pairs`, then the reads of every other
    /// file, in file order and unchanged, to `reads` (D7d). One handle may be
    /// both, since every pair of files comes before the other files. Returns
    /// the number of pairs.
    static func writeExtractedReads(
        _ outputs: [URL?],
        of files: [KrakenResultReadSources.File],
        pairs: FileHandle,
        reads: FileHandle
    ) throws -> Int {
        var pairCount = 0
        for (index, file) in files.enumerated() {
            switch file.role {
            case .r1:
                pairCount += try interleaveMates(of: files, at: index, outputs: outputs, into: pairs)
            case .r2:
                continue
            case .adjacentMates, .reads:
                guard let output = outputs[index] else { continue }
                let reader = try FASTQRawLineReader(url: output)
                defer { reader.close() }
                while let chunk = try reader.readChunk() {
                    try reads.write(contentsOf: chunk)
                }
            }
        }
        return pairCount
    }

    /// Writes the reads extracted from the pair of files at `index` (R1)
    /// and `index + 1` (R2), each R1 record followed by its R2 record, and
    /// returns the number of pairs. The two outputs come from files whose
    /// records correspond by position, filtered by one ID set, so they hold
    /// the same fragments in the same order. Names are checked record by
    /// record, and files out of step throw rather than mis-pair (D7d).
    static func interleaveMates(
        of files: [KrakenResultReadSources.File],
        at index: Int,
        outputs: [URL?],
        into handle: FileHandle
    ) throws -> Int {
        guard index + 1 < files.count, files[index + 1].role == .r2 else {
            throw ClassifierExtractionError.kraken2SourceMissing
        }
        let r1Source = files[index].url.lastPathComponent
        let r2Source = files[index + 1].url.lastPathComponent
        switch (outputs[index], outputs[index + 1]) {
        case (nil, nil):
            return 0
        case (let r1?, let r2?):
            do {
                return try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle, requireMates: true).r1Records
            } catch FASTQPairInterleaver.InterleaveError.mateNameMismatch(let record, _, let r1Name, _, let r2Name) {
                throw FASTQPairInterleaver.InterleaveError.mateNameMismatch(
                    recordNumber: record, r1File: r1Source, r1Name: r1Name, r2File: r2Source, r2Name: r2Name
                )
            } catch FASTQPairInterleaver.InterleaveError.mateCountMismatch(_, let r1Records, _, let r2Records) {
                throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                    r1File: r1Source, r1Records: r1Records, r2File: r2Source, r2Records: r2Records
                )
            }
        case (let r1?, nil):
            throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                r1File: r1Source, r1Records: try FASTQPairInterleaver.countRecords(in: r1), r2File: r2Source, r2Records: 0
            )
        case (nil, let r2?):
            throw FASTQPairInterleaver.InterleaveError.mateCountMismatch(
                r1File: r1Source, r1Records: 0, r2File: r2Source, r2Records: try FASTQPairInterleaver.countRecords(in: r2)
            )
        }
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

    /// One taxon's reads from every file of `files` in one gzip FASTQ, the
    /// file a one-file extraction writes for `config.outputFile`: each pair's
    /// R1 record followed by its R2 record, then the reads of every other
    /// file (D7d, D7e). A mix of pairs and single reads records its roles
    /// beside it. The provenance counts the records of that one file.
    func extractIntoOneFile(
        config: TaxonomyExtractionConfig,
        files: [KrakenResultReadSources.File],
        scratch: URL,
        tree: TaxonTree,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        let startTime = Date()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let baseName = config.outputFile.deletingPathExtension().lastPathComponent
        let perFile = TaxonomyExtractionConfig(
            taxIds: config.taxIds,
            includeChildren: config.includeChildren,
            sourceFiles: files.map(\.url),
            outputFiles: files.indices.map { scratch.appendingPathComponent("\(baseName)_R\($0 + 1).fastq") },
            classificationOutput: config.classificationOutput,
            taxonomyReport: config.taxonomyReport,
            keepReadPairs: config.keepReadPairs
        )
        let extraction = try await extractEachSource(config: perFile, tree: tree, progress: progress)

        let plain = scratch.appendingPathComponent("\(baseName).fastq")
        fileManager.createFile(atPath: plain.path, contents: nil)
        let handle = try FileHandle(forWritingTo: plain)
        do {
            _ = try Self.writeExtractedReads(extraction.outputs, of: files, pairs: handle, reads: handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let output = config.outputFile.deletingLastPathComponent()
            .appendingPathComponent("\(ExtractionBundleNaming.sanitizeFilename(baseName)).fastq.gz")
        try KrakenOutputCompactor.gzipCopy(source: plain, destination: output)
        if files.contains(where: { $0.role != .reads }),
           let roles = try Self.extractedLayout(of: plain, singleReadRole: KrakenResultReadSources.singleReadFileRole(of: files)).roles {
            FASTQMixedLayoutHint.write(
                ReadClassification(files: roles.files.map { .init(filename: output.lastPathComponent, role: $0.role, readCount: $0.readCount) }),
                beside: output
            )
        }

        let records = try FASTQPairInterleaver.countRecords(in: plain)
        try await recordProvenance(
            config: TaxonomyExtractionConfig(
                taxIds: config.taxIds,
                includeChildren: config.includeChildren,
                sourceFiles: files.map(\.url),
                outputFiles: [output],
                classificationOutput: config.classificationOutput,
                taxonomyReport: config.taxonomyReport,
                keepReadPairs: config.keepReadPairs
            ),
            resolvedTaxIds: extraction.taxIds,
            outputURLs: [output],
            extractedCount: records,
            runtime: Date().timeIntervalSince(startTime),
            commandPrefix: ["LungfishWorkflow", "extract-taxon-reads"]
        )
        return output
    }
}

extension KrakenResultReadSources {

    /// The role a mix of these files' pairs and single reads records for its
    /// single reads: merged when any file holds merged reads, else unpaired.
    static func singleReadFileRole(of files: [File]) -> ReadClassification.FileRole {
        files.contains { $0.singleReadRole == .merged || $0.singleReadRole == .mergedOrOrphan } ? .merged : .unpaired
    }
}
