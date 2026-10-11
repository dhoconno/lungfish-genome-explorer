// MetagenomicsSampleReadPlans.swift - Read plans for grouped metagenomics samples
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// The Kraken2 read format chosen for one grouped sample. Separate R1/R2
/// files run `paired`. A single file or bundle is classified by
/// ``FASTQReadLayoutClassifier`` as ``EsVirituSampleReadPlan`` does. A bundle
/// with separate pairs, merged or single reads gets its read set from
/// ``KrakenReadSetPlanner`` at run time, as `conda classify` does (`readSet`).
struct ClassificationSampleReadPlan: Equatable, Sendable {
    let format: ClassificationConfig.ReadFormat
    let layout: FASTQReadLayoutClassification?
    var readSet: KrakenReadSetPreview? = nil

    var plansReadSet: Bool { readSet?.plansReadSet ?? false }

    var label: String {
        readSet?.inputLabel ?? ClassificationConfig.ReadFormat.inputLabel(format: format, layout: layout?.layout)
    }

    /// Compact tag for the batch sample list.
    var shortLabel: String {
        if plansReadSet { return readSet == .pairs(withSingleReads: false) ? "PE" : "PE + merged" }
        switch format {
        case .paired: return "PE"
        case .interleaved: return "interleaved PE"
        case .unpaired: return layout?.layout == .mixedInterleaved ? "mixed, run as SE" : "SE"
        }
    }

    static func plan(
        for sample: MetagenomicsSampleInput,
        classify: (URL) -> FASTQReadLayoutClassification = { FASTQReadLayoutClassifier.classify(inputURL: $0) }
    ) -> ClassificationSampleReadPlan {
        if sample.isPairedEnd {
            return ClassificationSampleReadPlan(format: .paired, layout: nil)
        }
        let layout = classify(sample.fastq1)
        return ClassificationSampleReadPlan(format: .forSingleFile(layout.layout), layout: layout)
    }

    /// The plan with the bundle's read set read from its metadata.
    static func planned(for sample: MetagenomicsSampleInput) async -> ClassificationSampleReadPlan {
        var plan = plan(for: sample)
        guard let bundle = KrakenReadSetPlanner.plannableInput(sample.inputFiles) else { return plan }
        plan.readSet = await KrakenReadSetPlanner.preview(bundle: bundle)
        return plan
    }
}

/// The EsViritu read format chosen for one grouped sample.
///
/// Separate R1/R2 files run `paired`. A single file or bundle is classified
/// by ``FASTQReadLayoutClassifier``: strictly interleaved input runs
/// `interleaved`; mixed pairs plus merged reads and true single-end input
/// run `unpaired`. A bundle that holds separate R1 and R2 files, mixes pairs
/// with single reads or holds several files of single reads is decided by
/// ``SamplesheetReadSetPlanner`` when the run starts, which the recorded
/// command names with `--read-format auto` (`plansReadSet`).
struct EsVirituSampleReadPlan: Equatable, Sendable {
    let format: EsVirituReadFormat
    let layout: FASTQReadLayoutClassification?
    /// What the read-set planner will do for the sample's input.
    var readSet: SamplesheetReadSetPreview = .singleReads

    /// Whether the recorded command must plan the input (`--read-format auto`).
    var plansReadSet: Bool { readSet.plansReadSet }

    var label: String {
        switch readSet {
        case .pairs(withSingleReads: true):
            return EsVirituReadFormat.inputLabel(format: .unpaired, layout: .mixedInterleaved)
        case .severalFiles:
            return "Several read files (joined, run as single-end)"
        case .decidedAtRunTime:
            return "Read layout is decided when the run starts"
        default:
            return EsVirituReadFormat.inputLabel(format: format, layout: layout?.layout)
        }
    }

    /// Compact tag for the batch sample list.
    var shortLabel: String {
        switch readSet {
        case .pairs(withSingleReads: true): return "mixed, run as SE"
        case .severalFiles: return "joined, SE"
        case .decidedAtRunTime: return "decided at run"
        default: break
        }
        switch format {
        case .paired: return "PE"
        case .interleaved: return "interleaved PE"
        case .unpaired: return layout?.layout == .mixedInterleaved ? "mixed, run as SE" : "SE"
        }
    }

    static func plan(
        for sample: MetagenomicsSampleInput,
        classify: (URL) -> FASTQReadLayoutClassification = { FASTQReadLayoutClassifier.classify(inputURL: $0) }
    ) -> EsVirituSampleReadPlan {
        if sample.isPairedEnd {
            return EsVirituSampleReadPlan(format: .paired, layout: nil)
        }
        let layout = classify(sample.fastq1)
        return EsVirituSampleReadPlan(format: .forSingleFile(layout.layout), layout: layout)
    }

    /// ``plan(for:classify:)`` with what the read-set planner will do for the
    /// sample's bundle or file. Separate R1 and R2 files in a deinterleaved
    /// bundle run `paired`. Any other input the planner decides keeps the
    /// classified format, and the planner sets the files when the run starts.
    static func planned(
        for sample: MetagenomicsSampleInput,
        classify: (URL) -> FASTQReadLayoutClassification = { FASTQReadLayoutClassifier.classify(inputURL: $0) },
        preview: (URL) async -> SamplesheetReadSetPreview = { await SamplesheetReadSetPlanner.preview(input: $0) }
    ) async -> EsVirituSampleReadPlan {
        let classified = plan(for: sample, classify: classify)
        guard !sample.isPairedEnd else { return classified }
        let readSet = await preview(sample.fastq1)
        if case .pairs(withSingleReads: false) = readSet {
            return EsVirituSampleReadPlan(format: .paired, layout: nil, readSet: readSet)
        }
        return EsVirituSampleReadPlan(format: classified.format, layout: classified.layout, readSet: readSet)
    }
}
