// RNASeqQuantSubcommand+STARPlan.swift - The chain of `rnaseq quant --write-plan` and the STAR chains' jobs (Phase 5.3
// lane EX-PLAN-STAR)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishPortable
import LungfishWorkflow

/// The chain each plan of `rnaseq quant --write-plan` runs after the trim steps. salmon counts the reads on the index this
/// Mac published. Each STAR chain maps on the STAR index of its version that an earlier Linux run built and left in the
/// staging folder, which `rnaseq index-plan` plans and `rnaseq index-adopt` records, and never builds one.
enum RNASeqQuantPlanChain: String, CaseIterable, ExpressibleByArgument {
    case salmon
    case starSalmon = "star-salmon"
    case starSalmonErrorModel = "star-salmon-errormodel"
    case star2711bGeneCounts = "star-2.7.11b-genecounts"
    case star273aGeneCounts = "star-2.7.3a-genecounts"
    case star2711bFeatureCounts = "star-2.7.11b-featurecounts"

    /// The STAR chain, the STAR version of its index and salmon's alignment scoring, or nil for salmon on the reads.
    var star: (chain: STARPlanChain, version: STARIndexVersion, scoring: STARPlanAlignmentScoring)? {
        switch self {
        case .salmon: return nil
        case .starSalmon: return (.starSalmon, .v2_7_11b, .none)
        case .starSalmonErrorModel: return (.starSalmon, .v2_7_11b, .errorModel)
        case .star2711bGeneCounts: return (.geneCounts, .v2_7_11b, .none)
        case .star273aGeneCounts: return (.geneCounts, .v2_7_3a, .none)
        case .star2711bFeatureCounts: return (.featureCounts, .v2_7_11b, .none)
        }
    }
}

/// The jobs of one plan folder, whichever chain wrote them, with the index key the summary names.
struct RNASeqQuantPlanJobs {
    var key: String
    var jobs: [ExecutorPlanBatchJob]
    var samples: [(name: String, figures: SalmonPlanSubmit.Figures)]
}

extension RNASeqCommand.QuantSubcommand {
    /// The one adopted index of the set at `version` that is no STARsolo variant, read from the records `rnaseq index-adopt`
    /// wrote, pinned once for every sample. A set with none, or with more than one, is refused in words.
    static func adoptedIndex(
        setID: String, version: STARIndexVersion, storageRoot: URL, star: PlanToolPin, layout: ExecutorPlanStagingLayout
    ) throws -> ExecutorPlanStagedIndex {
        let store = STARIndexRecordStore(storageRoot: storageRoot)
        let folder = storageRoot.appendingPathComponent(STARIndexRecordStore.folderName, isDirectory: true)
            .appendingPathComponent(setID, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let keys = try names.filter { name in
            guard let record = try store.find(setID: setID, key: name) else { return false }
            return record.tool.version == version.rawValue && record.key.gtfFilter == nil
        }
        guard let key = keys.first, keys.count == 1 else {
            if keys.isEmpty {
                throw STARPlanError("The set \(setID) has no adopted STAR \(version.rawValue) index in this storage root, and a plan "
                    + "never builds one. Plan it with lungfish-cli rnaseq index-plan --set \(setID) --star \(version.rawValue), run "
                    + "that plan on the Linux machine, record the run with lungfish-cli rnaseq index-adopt, then write the plan again.")
            }
            throw STARPlanError("The set \(setID) has adopted STAR \(version.rawValue) indexes \(keys.joined(separator: " and ")) "
                + "under \(folder.path), and a plan pins one. Keep the record of the index to map on there, then write the plan again.")
        }
        return try ExecutorPlanStagedIndex.pin(setID: setID, key: key, store: store, star: star, layout: layout)
    }

    /// The STAR chain's plan of each sample on the adopted index, with the request rule's figures.
    func starPlanJobs(
        _ star: (chain: STARPlanChain, version: STARIndexVersion, scoring: STARPlanAlignmentScoring),
        setFolder: URL, root: URL, manifest: ReferenceSetManifest, layout: ExecutorPlanStagingLayout,
        image: RNASeqQuantImageFiles, samples staged: [SalmonPlanSample]
    ) async throws -> RNASeqQuantPlanJobs {
        let options = planOptions
        let pins = try STARPlanPins(
            executor: image.executor, executorBuild: image.executorBuild, imageManifest: image.pin, toolManifest: image.tools,
            star: star.version)
        // The index is pinned once for every sample, so a missing one is refused before any read is hashed.
        let index = try Self.adoptedIndex(setID: manifest.id, version: star.version, storageRoot: root, star: pins.star, layout: layout)
        let samples = try await bundleSamples(or: staged)
        let trimChoice: SalmonQuantTrim = trim ? .trimGalore(polyG: polyGTrimming == "on") : .none
        var result = RNASeqQuantPlanJobs(key: index.record.key.folderName, jobs: [], samples: [])
        for sample in samples {
            try Task.checkCancellation()
            let made = try STARPlan.make(STARPlanRequest(
                setFolder: setFolder, sample: sample, pins: pins, chain: star.chain, index: index, trim: trimChoice,
                threads: options.requestCPUs ?? STARPlan.defaultThreads, multimapNmax: options.starMultimapNmax,
                alignmentScoring: star.scoring))
            let figures = try STARPlanSubmit.figures(
                for: manifest, made: made, memoryMiB: options.requestMemoryMiB, cpus: options.requestCPUs, diskGiB: options.requestDiskGiB)
            result.jobs.append(STARPlanSubmit.job(made, figures: figures))
            result.samples.append((sample.name, figures))
        }
        return result
    }

    /// The staged samples, or else one sample a bundle, read through a scratch folder that goes when the call ends.
    func bundleSamples(or staged: [SalmonPlanSample]) async throws -> [SalmonPlanSample] {
        guard staged.isEmpty else { return staged }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rnaseq-quant-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var samples: [SalmonPlanSample] = []
        for bundle in bundles {
            try Task.checkCancellation()
            samples.append(try await SalmonPlan.sample(bundle: URL(fileURLWithPath: bundle, isDirectory: true), scratch: scratch))
        }
        return samples
    }
}
