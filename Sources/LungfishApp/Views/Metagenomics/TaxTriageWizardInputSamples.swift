// TaxTriageWizardInputSamples.swift - The samples the TaxTriage dialog makes of the inputs it is handed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// One sample the TaxTriage dialog makes of its inputs, before a person edits it.
struct TaxTriageWizardInputSample: Equatable, Sendable {
    var sampleId: String
    var fastq1: URL
    var fastq2: URL?
    /// The role the sample's own FASTQ bundle records, or a test sample.
    var sampleRole: SampleRole = .testSample
    /// The bundle's own sample name, when it differs from `sampleId`.
    var metadataLabel: String?
}

extension TaxTriageWizardSheet {
    /// The samples `populateFromInitialFiles` lists for `urls`, the inputs the dialog is handed (S1 row
    /// TAXTRIAGE-BUNDLE-NAMES-PAIRED, BIO verdict PRODUCT-4 items 3 and 4, ruling BIO-TT-PAIR question 1).
    ///
    /// - Each `.lungfishfastq` bundle is one sample, named by its whole stem as `taxtriage run` names it.
    ///   Two bundles are never mates, whatever their names.
    /// - Two loose files make one paired sample only when `MatePairFileNaming` names them the R1 and R2 of
    ///   one stem and no other loose file shares that stem. R1 is the file with the R1 ending.
    /// - Every other input is a sample of its own, so no input is left out.
    /// - Each sample takes the role and name its own bundle records.
    ///
    /// The samples are listed by name, and samples of one name in input order.
    nonisolated static func inputSamples(from urls: [URL]) -> [TaxTriageWizardInputSample] {
        var paired = Set<Int>()
        var made: [(order: Int, sample: TaxTriageWizardInputSample)] = []
        let looseIndices = urls.indices.filter { !FASTQBundle.isBundleURL(urls[$0]) }
        let looseByStem = Dictionary(grouping: looseIndices) { MatePairFileNaming.stemAndRole(of: urls[$0]).stem }
        for (stem, indices) in looseByStem {
            guard let pair = MatePairFileNaming.matePair(in: indices.map { urls[$0] }) else { continue }
            paired.formUnion(indices)
            made.append((indices[0], withBundleMetadata(TaxTriageWizardInputSample(sampleId: stem, fastq1: pair.r1, fastq2: pair.r2))))
        }
        for index in urls.indices where !paired.contains(index) {
            let sample = TaxTriageWizardInputSample(sampleId: wholeStem(of: urls[index]), fastq1: urls[index])
            made.append((index, withBundleMetadata(sample)))
        }
        return made.sorted { ($0.sample.sampleId, $0.order) < ($1.sample.sampleId, $1.order) }.map(\.sample)
    }

    /// The name `taxtriage run` gives `url` when it names the input itself.
    private nonisolated static func wholeStem(of url: URL) -> String {
        TaxTriageAnalysisRunTool.sampleID(for: url, explicitSampleID: nil, totalSampleCount: 1)
    }

    /// `sample` with the role and name its FASTQ bundle records: the bundle `fastq1` names, or the bundle
    /// its file lies in.
    private nonisolated static func withBundleMetadata(_ sample: TaxTriageWizardInputSample) -> TaxTriageWizardInputSample {
        let parent = sample.fastq1.deletingLastPathComponent()
        let bundle = FASTQBundle.isBundleURL(sample.fastq1) ? sample.fastq1 : (FASTQBundle.isBundleURL(parent) ? parent : nil)
        guard let bundle, let csvMeta = FASTQBundleCSVMetadata.load(from: bundle) else { return sample }
        let meta = FASTQSampleMetadata(from: csvMeta, fallbackName: sample.sampleId)
        var loaded = sample
        loaded.sampleRole = meta.sampleRole
        loaded.metadataLabel = meta.sampleName != sample.sampleId ? meta.sampleName : nil
        return loaded
    }

    /// The file lines a sample row shows under its Sample ID. A paired row labels R1 first, then R2.
    nonisolated static func sampleFileLines(fastq1: URL?, fastq2: URL?) -> [String] {
        let first = fastq1?.lastPathComponent ?? "No R1 file"
        guard let fastq2 else { return [first] }
        return ["R1: \(first)", "R2: \(fastq2.lastPathComponent)"]
    }

    /// The line under a paired row's files. Only two loose files the dialog paired by name make such a row.
    nonisolated static func pairedByNamesLine(fastq2: URL?) -> String? {
        fastq2 == nil ? nil : "Paired by their names as the two reads of one sample."
    }

    /// One line under the sample list for each two FASTQ bundles named like the R1 and R2 of one sample,
    /// with both names, R1 first, and the way on. Run stays on (BIO-TT-PAIR question 1, fourth line).
    nonisolated static func bundleMateNotices(_ urls: [URL]) -> [String] {
        let bundles = urls.filter { FASTQBundle.isBundleURL($0) }
        let byStem = Dictionary(grouping: bundles) { MatePairFileNaming.stemAndRole(of: $0).stem }
        return byStem.values.compactMap { group -> (r1: String, r2: String)? in
            let mates = group.filter { MatePairFileNaming.stemAndRole(of: $0).role != .single }
            guard let pair = MatePairFileNaming.matePair(in: mates) else { return nil }
            return (wholeStem(of: pair.r1), wholeStem(of: pair.r2))
        }
        .sorted { $0.r1 < $1.r1 }
        .map {
            "\($0.r1) and \($0.r2) run as two samples, since each FASTQ bundle is one sample. "
                + "To run them as the two reads of one sample, import the two files together as a pair."
        }
    }
}
