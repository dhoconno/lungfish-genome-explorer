// TwelveSAmpliconMatchingWorkflow+Inputs.swift - The inputs a 12S matching run reads, one sample each
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each named path is planned where it lies (`ReadSetNamedInput`). A bundle
// is planned whole, a file named inside a bundle is that file alone, as the
// FASTQ subcommands and TaxTriage read it, and the preview of a virtual
// bundle stands for its bundle (Phase 2.1 round F4, review A S1).

import Foundation
import LungfishCore
import LungfishIO

extension TwelveSAmpliconMatchingWorkflow {

    /// Plans each input through the read-set resolver, one input one sample.
    /// Pairs reach the count as pairs and a mixed stream is split by name
    /// into the scratch folder (docs/contracts/READ-PAIRING.md).
    func resolveInputs(
        _ inputURLs: [URL],
        scratchDirectory: URL,
        progressHandler: ProgressHandler?
    ) async throws -> [ResolvedInput] {
        let resolver = ReadSetResolver(
            materializationDirectory: scratchDirectory.appendingPathComponent("read-sets", isDirectory: true)
        )
        var resolved: [ResolvedInput] = []
        for inputURL in inputURLs {
            let named = ReadSetNamedInput(inputURL)
            if let note = named.note {
                progressHandler?(0.25, note)
            }
            do {
                let plan = try await resolver.plan(for: named, capability: Self.readPairingCapability)
                resolved.append(ResolvedInput(sourceURL: inputURL, plan: plan))
            } catch ReadSetResolverError.noReads(let path) {
                throw TwelveSAmpliconMatchingError.noReadsInInput(path)
            }
        }
        return resolved
    }

    /// Refuses two inputs that would be one sample, before anything is
    /// written. A result holds each sample once and its tables are keyed by
    /// the sample, so two such inputs used to stop the run on a trap after
    /// `--force` had removed the earlier output (review A, N1).
    static func refuseDuplicateSampleIDs(_ inputURLs: [URL]) throws {
        var firstInputs: [String: URL] = [:]
        for inputURL in inputURLs {
            let sampleID = Self.sampleID(for: inputURL)
            if let earlier = firstInputs[sampleID] {
                throw TwelveSAmpliconMatchingError.duplicateSampleID(
                    sampleID: sampleID,
                    first: earlier.path,
                    second: inputURL.path
                )
            }
            firstInputs[sampleID] = inputURL
        }
    }
}
