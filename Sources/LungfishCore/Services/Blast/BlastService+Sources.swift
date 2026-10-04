// BlastService+Sources.swift - BLAST verification requests read from every source file of a Kraken2 result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

private let logger = Logger(subsystem: LogSubsystem.core, category: "BlastService")

extension BlastService {
    /// Shared implementation: samples fragments, picks the evidence-carrying
    /// mate of each, extracts sequences, and builds the request.
    ///
    /// Sampling happens on fragment IDs before any sequence is read, so
    /// neither read length nor position in the FASTQ can bias it.
    func extractSequencesAndBuild(
        taxonName: String,
        taxId: Int,
        matchingReadIds: Set<String>,
        sourceURL: URL,
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

        let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path)
        let isGzip = sourceURL.pathExtension.lowercased() == "gz"
        logger.info("buildVerificationRequest: source FASTQ exists=\(sourceExists, privacy: .public) gzip=\(isGzip, privacy: .public)")

        // Extract sequences from FASTQ, with retry for gzip subprocess failures.
        let records = try await extractMatchingSequences(
            from: sourceURL,
            matchingReadIds: sampledSet,
            isGzip: isGzip
        )

        // Group records by fragment and number the mates. An explicit /1, /2
        // or CASAVA marker wins. Otherwise order of appearance decides, which
        // is how an interleaved file stores a pair.
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
