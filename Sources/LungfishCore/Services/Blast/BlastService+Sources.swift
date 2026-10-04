// BlastService+Sources.swift - BLAST verification requests read from every source file of a Kraken2 result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastService")

/// One file a BLAST verification reads sequences from (D8, Phase 1.5 lane A3).
///
/// A Kraken2 result's reads can sit in several files: the R1 and R2 files
/// of pairs, merged reads and single reads. A fragment whose evidence is on
/// mate 2, or a merged fragment, is found only by reading them all.
public struct BlastReadSource: Sendable, Equatable {
    public let url: URL
    /// The mate a record of this file is when its header names none: 1 in
    /// the R1 file and 2 in the R2 file of a pair of files. Nil for any other
    /// file, whose unmarked records are numbered in the order they appear.
    public let unmarkedMate: Int?

    public init(url: URL, unmarkedMate: Int? = nil) {
        self.url = url
        self.unmarkedMate = unmarkedMate
    }
}

extension BlastService {

    /// Builds a BLAST verification request from pre-fetched read IDs, reading
    /// `sources` in order, R1, then R2, then single reads.
    ///
    /// The parameters are those of
    /// ``buildVerificationRequestFromReadIds(taxonName:taxId:matchingReadIds:sourceURL:readCount:targetTaxIds:classificationOutputURL:acceptedTaxonNames:taxonomyContext:seed:)``,
    /// with every source file of the result in place of one.
    public func buildVerificationRequestFromReadIds(
        taxonName: String,
        taxId: Int,
        matchingReadIds: Set<String>,
        sources: [BlastReadSource],
        readCount: Int = 20,
        targetTaxIds: Set<Int> = [],
        classificationOutputURL: URL? = nil,
        acceptedTaxonNames: [String] = [],
        taxonomyContext: BlastTaxonomyContext? = nil,
        seed: UInt64 = 0
    ) async throws -> BlastVerificationRequest {
        logger.info("buildVerificationRequestFromReadIds: taxon=\(taxonName, privacy: .public) taxId=\(taxId, privacy: .public) matchingReadIds=\(matchingReadIds.count, privacy: .public) readCount=\(readCount, privacy: .public)")
        logger.info("buildVerificationRequestFromReadIds: sources=\(sources.map(\.url.path).joined(separator: ", "), privacy: .public)")

        guard !matchingReadIds.isEmpty else {
            logger.error("buildVerificationRequestFromReadIds: no matching read IDs provided")
            throw BlastServiceError.noSequences
        }

        return try await extractSequencesAndBuild(
            taxonName: taxonName,
            taxId: taxId,
            matchingReadIds: Set(matchingReadIds.map { Self.normalizeFragmentId($0).id }),
            sources: sources,
            readCount: readCount,
            targetTaxIds: targetTaxIds.isEmpty ? [taxId] : targetTaxIds,
            classificationOutputURL: classificationOutputURL,
            acceptedTaxonNames: acceptedTaxonNames,
            taxonomyContext: taxonomyContext,
            seed: seed
        )
    }

    /// Builds a BLAST verification request by scanning the Kraken2 per-read
    /// output, reading `sources` in order, R1, then R2, then single reads.
    ///
    /// The parameters are those of
    /// ``buildVerificationRequest(taxonName:taxId:targetTaxIds:classificationOutputURL:sourceURL:readCount:acceptedTaxonNames:taxonomyContext:seed:)``,
    /// with every source file of the result in place of one.
    public func buildVerificationRequest(
        taxonName: String,
        taxId: Int,
        targetTaxIds: Set<Int>,
        classificationOutputURL: URL,
        sources: [BlastReadSource],
        readCount: Int = 20,
        acceptedTaxonNames: [String] = [],
        taxonomyContext: BlastTaxonomyContext? = nil,
        seed: UInt64 = 0
    ) async throws -> BlastVerificationRequest {
        logger.info("buildVerificationRequest: taxon=\(taxonName, privacy: .public) taxId=\(taxId, privacy: .public) targetTaxIds=\(targetTaxIds.count, privacy: .public) readCount=\(readCount, privacy: .public)")
        logger.info("buildVerificationRequest: classificationOutput=\(classificationOutputURL.path, privacy: .public)")
        logger.info("buildVerificationRequest: sources=\(sources.map(\.url.path).joined(separator: ", "), privacy: .public)")

        // Scan Kraken2 output for matching read IDs
        var matchingReadIds = Set<String>()
        let classificationExists = FileManager.default.fileExists(atPath: classificationOutputURL.path)
        logger.info("buildVerificationRequest: classification file exists=\(classificationExists, privacy: .public)")

        if classificationExists {
            let scanResult = try scanKrakenClassificationOutput(
                classificationOutputURL,
                targetTaxIds: targetTaxIds
            )
            matchingReadIds = scanResult.matchingReadIds
            logger.info("buildVerificationRequest: scanned \(scanResult.totalClassified, privacy: .public) classified reads, \(matchingReadIds.count, privacy: .public) match target taxIds")
        } else {
            logger.error("buildVerificationRequest: classification output file not found at \(classificationOutputURL.path, privacy: .public)")
        }

        guard !matchingReadIds.isEmpty else {
            logger.error("buildVerificationRequest: no matching read IDs found — cannot proceed with BLAST")
            throw BlastServiceError.noSequences
        }

        return try await extractSequencesAndBuild(
            taxonName: taxonName,
            taxId: taxId,
            matchingReadIds: matchingReadIds,
            sources: sources,
            readCount: readCount,
            targetTaxIds: targetTaxIds.isEmpty ? [taxId] : targetTaxIds,
            classificationOutputURL: classificationOutputURL,
            acceptedTaxonNames: acceptedTaxonNames,
            taxonomyContext: taxonomyContext,
            seed: seed
        )
    }

    /// Shared implementation: samples fragments, picks the evidence-carrying
    /// mate of each, extracts sequences, and builds the request.
    ///
    /// Sampling happens on fragment IDs before any sequence is read, so
    /// neither read length nor position in the FASTQ can bias it.
    func extractSequencesAndBuild(
        taxonName: String,
        taxId: Int,
        matchingReadIds: Set<String>,
        sources: [BlastReadSource],
        readCount: Int,
        targetTaxIds: Set<Int>,
        classificationOutputURL: URL?,
        acceptedTaxonNames: [String],
        taxonomyContext: BlastTaxonomyContext?,
        seed: UInt64
    ) async throws -> BlastVerificationRequest {
        let sampledIds = sampleFragmentIds(matchingReadIds, count: readCount, seed: seed)
        let sampledSet = Set(sampledIds)
        logger.info("extractSequencesAndBuild: sampled \(sampledIds.count, privacy: .public) of \(matchingReadIds.count, privacy: .public) fragments (seed \(seed, privacy: .public))")

        // Hit strings decide which mate of a pair carries the taxon's evidence.
        var hitStrings: [String: String] = [:]
        if let classificationOutputURL,
           FileManager.default.fileExists(atPath: classificationOutputURL.path) {
            do {
                hitStrings = try lookupKrakenHitStrings(classificationOutputURL, fragmentIds: sampledSet)
            } catch {
                logger.warning("extractSequencesAndBuild: could not read Kraken hit strings: \(error.localizedDescription, privacy: .public); submitting mate 1")
            }
        }

        // Extract sequences from every source file in order, with retry for
        // gzip subprocess failures. A record whose header names no mate takes
        // its file's mate, so a record of the R2 file is mate 2 (D8).
        var records: [(id: String, mate: Int?, sequence: String)] = []
        for source in sources {
            let sourceExists = FileManager.default.fileExists(atPath: source.url.path)
            let isGzip = source.url.pathExtension.lowercased() == "gz"
            logger.info("buildVerificationRequest: source FASTQ \(source.url.lastPathComponent, privacy: .public) exists=\(sourceExists, privacy: .public) gzip=\(isGzip, privacy: .public)")
            let found = try await extractMatchingSequences(
                from: source.url,
                matchingReadIds: sampledSet,
                isGzip: isGzip
            )
            records += found.map { (id: $0.id, mate: $0.mate ?? source.unmarkedMate, sequence: $0.sequence) }
        }

        // Group records by fragment and number the mates. An explicit /1, /2
        // or CASAVA marker wins, then the mate of the file the record came
        // from. Otherwise order of appearance decides, which is how an
        // interleaved file stores a pair.
        var matesById: [String: [Int: String]] = [:]
        for record in records {
            var mates = matesById[record.id, default: [:]]
            let mate = record.mate ?? ((mates.keys.max() ?? 0) + 1)
            if mates[mate] == nil {
                mates[mate] = record.sequence
            }
            matesById[record.id] = mates
        }

        logger.info("extractSequencesAndBuild: extracted \(records.count, privacy: .public) FASTQ records for \(matesById.count, privacy: .public) sampled fragments")

        var sequences: [(id: String, sequence: String)] = []
        var sequenceMates: [String: Int] = [:]
        for id in sampledIds {
            guard let mates = matesById[id], !mates.isEmpty else { continue }
            var mate = 1
            if let hitString = hitStrings[id] {
                mate = KrakenMateEvidence(hitString: hitString, targetTaxIds: targetTaxIds).preferredMate
            }
            if mates[mate] == nil {
                mate = mates.keys.min() ?? 1
            }
            guard let sequence = mates[mate] else { continue }
            sequences.append((id: id, sequence: sequence))
            if mates.count > 1 || hitStrings[id]?.contains("|:|") == true {
                sequenceMates[id] = mate
            }
        }

        guard !sequences.isEmpty else {
            logger.error("extractSequencesAndBuild: found \(matchingReadIds.count, privacy: .public) matching read IDs but 0 sequences in FASTQ — source file may be missing or read IDs may not match")
            throw BlastServiceError.noSequences
        }

        let mate2Count = sequenceMates.values.filter { $0 == 2 }.count
        logger.info("buildVerificationRequest: submitting \(sequences.count, privacy: .public) reads (\(mate2Count, privacy: .public) as mate 2)")

        let context = taxonomyContext ?? BlastTaxonomyContext(
            cladeTaxIds: targetTaxIds,
            cladeNames: acceptedTaxonNames
        )
        return BlastVerificationRequest(
            taxonName: taxonName,
            taxId: taxId,
            sequences: sequences,
            entrezQuery: nil,
            sequenceMates: sequenceMates,
            acceptedTaxIds: context.cladeTaxIds,
            acceptedTaxonNames: context.cladeNames,
            relatedTaxIds: context.relatedTaxIds,
            relatedTaxonNames: context.relatedNames
        )
    }
}
