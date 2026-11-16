// SalmonPlan+Reads.swift - A sample's reads for the salmon plan, from a FASTQ bundle or the staging folder (Phase 5.3
// lane EX-PLAN-SALMON)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishPortable

extension SalmonPlan {
    /// One FASTQ bundle read as the Mac route reads it (`SalmonQuantRoute.reads(of:resolver:)`), each file pinned by its
    /// size and SHA-256 with the Mac file as its source. A file the resolver had to write, for a virtual bundle, is no
    /// file of the bundle and is refused, and so is a pair held interleaved in one file, since the Mac route splits it in
    /// its own process and no tool of the image does that. `scratch` is a folder the resolver may write into.
    package static func sample(bundle: URL, scratch: URL) async throws -> SalmonPlanSample {
        let bundle = bundle.standardizedFileURL
        let route = SalmonQuantRoute(storageRoot: scratch, host: RunFitHostFacts(physicalMemoryBytes: 0))
        let reads = try await route.reads(of: bundle, resolver: ReadSetResolver(materializationDirectory: scratch))
        let name = bundle.lastPathComponent
        func pinned(_ url: URL) throws -> SalmonPlanRead {
            guard url.standardizedFileURL.path.hasPrefix(bundle.path + "/") else {
                throw SalmonPlanError("\(name) holds no read file of its own, so a plan cannot pin its reads. Materialize the "
                    + "bundle first, then write the plan again.")
            }
            let measured = try ExecutorPlanSourceFile.measuring(url)
            return SalmonPlanRead(name: url.lastPathComponent, sha256: measured.sha256, size: measured.size, source: url)
        }
        var pairs: [SalmonPlanSample.Pair] = []
        for pair in reads.pairs {
            guard case .separate(let r1, let r2) = pair.files else {
                throw SalmonPlanError("\(name) holds its read pairs interleaved in one file, which a plan does not split, since "
                    + "only the Mac route splits such a file. Quantify it on this Mac with lungfish-cli rnaseq quant, or import "
                    + "its R1 and R2 as two files.")
            }
            pairs.append(SalmonPlanSample.Pair(r1: try pinned(r1), r2: try pinned(r2)))
        }
        let duplicates = duplicatesWords(payloads: reads.payloads, bundle: bundle)
        return SalmonPlanSample(
            name: reads.id, pairs: pairs, singles: try reads.singles.map(pinned), instrument: instrument(payloads: reads.payloads),
            duplicates: duplicates.words, duplicatesSource: duplicates.source)
    }

    /// One sample of reads that are in the staging folder already, each named by its absolute path there with the size and
    /// SHA-256 the person's list gives (C6 ruling STAGED). LGE reads none of them, so `duplicates` reads Not recorded and the
    /// instrument is the sample sheet's, never inferred.
    package static func stagedSample(
        name: String, pairs: [(r1: SalmonPlanStagedRead, r2: SalmonPlanStagedRead)], singles: [SalmonPlanStagedRead] = [],
        model: String? = nil
    ) -> SalmonPlanSample {
        func read(_ staged: SalmonPlanStagedRead) -> SalmonPlanRead {
            SalmonPlanRead(name: (staged.path as NSString).lastPathComponent, sha256: staged.sha256, size: staged.size, source: nil)
        }
        let paths = pairs.flatMap { [$0.r1.path, $0.r2.path] } + singles.map(\.path)
        return SalmonPlanSample(
            name: name, pairs: pairs.map { SalmonPlanSample.Pair(r1: read($0.r1), r2: read($0.r2)) }, singles: singles.map(read),
            stagedPaths: paths, instrument: model.map { PlanSampleInstrument(model: $0, inferred: false) },
            duplicates: duplicatesNotRecorded, duplicatesSource: .default)
    }

    /// The `duplicates` entry of a bundle's reads: the steps its import removed duplicates by, with source `recipe`, kept
    /// for an import with a record and no such step, and Not recorded for a bundle with no import record.
    static func duplicatesWords(payloads: [URL], bundle: URL) -> (words: String, source: ImportSettingSource) {
        if !SalmonQuantRecordLines.deduplicatingSteps(payloads: payloads).isEmpty {
            return (SalmonQuantRecordLines.duplicatesLine(payloads: payloads), .recipe)
        }
        let recorded = payloads.contains { FASTQMetadataStore.load(for: $0)?.ingestion != nil }
            || SalmonQuantRecordLines.importRecord(of: bundle) != nil
        return recorded ? (SalmonQuantRecordLines.duplicates, .default) : (duplicatesNotRecorded, .default)
    }

    /// The instrument of the reads' sidecar, with `inferred` when LGE read the model from the read names. The sidecar
    /// holds one model an instrument id, so each model is named once, and `Unknown`, for an id the table does not know,
    /// is no model. A sidecar with no known model leaves `instrument` out, as the page says when none is known.
    static func instrument(payloads: [URL]) -> PlanSampleInstrument? {
        guard let found = payloads.lazy.compactMap({ FASTQMetadataStore.load(for: $0)?.sequencerInstrument }).first,
              found.nameForm != .notRecorded else { return nil }
        var seen = Set<String>()
        let named = found.models.filter { $0 != SequencerInstrument.unknownModel && seen.insert($0).inserted }
        guard !named.isEmpty else { return nil }
        return PlanSampleInstrument(model: named.joined(separator: " and "), inferred: found.modelsAreInferred)
    }
}

/// One read already in the staging folder: its absolute path there and the size and SHA-256 the person's list gives.
package struct SalmonPlanStagedRead: Sendable, Equatable {
    package var path: String
    package var size: Int64
    package var sha256: String

    package init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}
