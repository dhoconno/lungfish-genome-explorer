// TaxTriageAnalysisRunTool.swift - TaxTriage on the analysis run executor, its plan (phase P0) and its units
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A2 (decisions T5, T8, T9 and N4, 2.8 T2 and T4). The types take `package` access, so the
// module map gains no public type (N3).

import Foundation
import LungfishIO

/// TaxTriage under the analysis run executor. `lungfish-cli taxtriage run` runs it from the lane's
/// second milestone, and the app's TaxTriage launch keeps its own route until 2.10 (T1).
///
/// The plan refuses what can be refused before any folder exists. It takes the pipeline's commit and
/// tag from the lock its services hold and refuses a lock with no usable TaxTriage pin, with no
/// fallback revision (N4). It refuses an `--input` folder that holds mates, which the folder route
/// would split into half samples (T8). It lays the run out by decision T5, which keeps 2.8 T2 and T4.
///
/// | Request | Layout | Units |
/// |---|---|---|
/// | `--output` | ``AnalysisRunLayout/singleFolder`` | one launch of every sample, pooled as today |
/// | `--project` with one sample | ``AnalysisRunLayout/sharedBatchRoot`` | one launch writing into `taxtriage-batch-<ts>` itself, as the app's does |
/// | `--project` with several samples, or `--batch` | ``AnalysisRunLayout/batchRoot`` | one launch per sample, in a folder the one sanitizer names |
///
/// A sample keeps the name its user gave it in the samplesheet its launch writes, and only its folder
/// takes the name of the one sanitizer, `AnalysesFolder.batchSampleDirectory(named:in:)` (T9). So
/// `S.1`, `S 1` and `S__1` run in the folders `S_1`, `S_1-2` and `S_1-3`.
package struct TaxTriageAnalysisRunTool: AnalysisRunTool {
    package typealias Unit = TaxTriageRunUnit
    package typealias UnitResult = TaxTriageUnitResult

    /// The workflow name of the root record, in the form of `EsVirituAnalysisRunTool.workflowName`.
    package static let workflowName = "lungfish.taxtriage.run"
    /// The id of TaxTriage's entry in the lock's `pipelines`, the registry's `.lockedPipeline` id.
    /// Milestone 2 reads the pin through `NextflowWorkflowDescriptor.taxTriage.resolvePin(in:)` instead.
    static let lockPipelineID = "taxtriage"

    package let request: TaxTriageRunRequest
    package let services: TaxTriageRunServices

    package init(request: TaxTriageRunRequest, services: TaxTriageRunServices = TaxTriageRunServices()) {
        self.request = request
        self.services = services
    }

    package var identity: AnalysisRunIdentity {
        AnalysisRunIdentity(toolID: .taxtriage, workflowName: Self.workflowName)
    }

    /// A failed sample of a batch is a warning while another sample completes, as the app's batch has
    /// always ended. A run of one launch fails with it.
    package var terminalPolicy: AnalysisRunTerminalPolicy { .warnOnFailedUnits }

    /// Phase P0. Every refusal of the request, before any folder exists. It reads the samplesheet and
    /// lists an `--input` folder, and it writes nothing.
    package func plan(
        _ runRequest: AnalysisRunRequest,
        context: AnalysisRunPlanningContext
    ) async throws -> AnalysisRunPlan<TaxTriageRunUnit> {
        let pin = try resolvePin()
        let revision = try launchRevision(pin: pin)
        let samples = try plannedSamples()
        try refuseMissingDatabase()
        let extraArguments: [String]
        do {
            extraArguments = try AdvancedCommandLineOptions.parse(request.extraArguments)
        } catch {
            throw TaxTriageRunRefusal.input(error.localizedDescription)
        }

        let layout = Self.layout(
            for: runRequest.destination,
            groupsSamples: runRequest.groupsSamples,
            sampleCount: samples.count
        )
        let launches = layout == .batchRoot ? samples.map { [$0] } : [samples]
        let units = try launches.map { launchSamples in
            var config = request.settings
            config.samples = launchSamples
            config.outputDirectory = runRequest.destination.url
            config.revision = revision
            config.extraArguments = extraArguments
            try Self.refuseInvalidSettings(of: config)
            return AnalysisRunPlannedUnit(
                label: Self.label(of: launchSamples),
                value: TaxTriageRunUnit(
                    config: config,
                    revision: revision,
                    githubReleaseVersion: Self.releaseVersion(of: revision, pin: pin),
                    handsFactsToRoot: layout != .batchRoot
                )
            )
        }
        return AnalysisRunPlan(layout: layout, units: units)
    }

    // MARK: - The pin (N4)

    /// TaxTriage's pin in the lock the services hold.
    ///
    /// - Throws: ``TaxTriageRunRefusal/noPinnedVersion(of:)`` with exit code 126 when the lock has no
    ///   entry for TaxTriage, or its entry names no repository or no revision. Nothing runs then, and
    ///   no fallback revision such as `main` takes the pin's place (N4).
    func resolvePin() throws -> PipelineSpec {
        guard let spec = services.lock.pipeline(id: Self.lockPipelineID),
              !spec.repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !spec.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TaxTriageRunRefusal.noPinnedVersion(of: identity.displayName)
        }
        return spec
    }

    /// The revision a launch passes as `-r`, the `--revision` given or else the commit the lock pins.
    /// A blank `--revision` is refused, never read as the pin.
    func launchRevision(pin: PipelineSpec) throws -> String {
        guard let given = request.revision else { return pin.revision }
        guard !given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaxTriageRunRefusal.input(
                "--revision is blank. Name a TaxTriage commit or tag, or leave out --revision to run the pinned version."
            )
        }
        return given
    }

    /// The release tag of the revision a launch runs, by the rule of
    /// `TaxTriageConfig.githubReleaseVersion(for:)` with the pin in place of the bundled lock, so the
    /// record names the tag today's record names. It is the pin's tag for the pin's commit or tag, the
    /// revision itself when it starts with `v`, and nil otherwise. A2 M2 replaces it with that function
    /// once the function takes the pin (A16 M1 review ruling 1).
    static func releaseVersion(of revision: String, pin: PipelineSpec) -> String? {
        let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == pin.revision || trimmed == pin.releaseVersion {
            return pin.releaseVersion
        }
        return trimmed.hasPrefix("v") ? trimmed : nil
    }

    // MARK: - Samples

    /// The samples of the request in input order, from the samplesheet or from `--input`, with the
    /// refusals the command made before it ran the pipeline.
    func plannedSamples() throws -> [TaxTriageSample] {
        let samples: [TaxTriageSample]
        switch (request.input, request.samplesheet) {
        case (nil, nil):
            throw TaxTriageRunRefusal.input("Provide either --input (with --sample) or --samplesheet")
        case (.some, .some):
            throw TaxTriageRunRefusal.input("Cannot use both --input and --samplesheet")
        case (nil, .some(let samplesheet)):
            samples = try samplesheetSamples(samplesheet)
        case (.some(let input), nil):
            samples = try inputSamples(input)
        }
        guard !samples.isEmpty else {
            throw TaxTriageRunRefusal.input(TaxTriageConfigError.noSamples.localizedDescription)
        }
        return samples
    }

    /// One sample per row of the samplesheet, each file read as it is named, as the command reads a
    /// samplesheet today. A row's platform falls back to `--platform`.
    func samplesheetSamples(_ path: String) throws -> [TaxTriageSample] {
        let sheetURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: sheetURL.path) else {
            throw TaxTriageRunRefusal.input("Samplesheet not found: \(path)")
        }
        let entries: [TaxTriageSampleEntry]
        do {
            entries = try TaxTriageSamplesheet.parse(url: sheetURL)
        } catch {
            throw TaxTriageRunRefusal.input(error.localizedDescription)
        }
        let samples = entries.map { entry in
            TaxTriageSample(
                sampleId: entry.sampleId,
                fastq1: URL(fileURLWithPath: entry.fastq1Path),
                fastq2: entry.fastq2Path.map { URL(fileURLWithPath: $0) },
                platform: TaxTriageConfig.Platform(rawValue: entry.platform) ?? request.settings.platform
            )
        }
        for sample in samples {
            try Self.refuseUnreadableFiles(of: sample)
        }
        return samples
    }

    /// The samples `--input` names. With `--input2` it is one pair. Otherwise every input is one sample,
    /// a file or a bundle planned whole by the unit, and a folder that holds mates is refused (T8).
    func inputSamples(_ inputPath: String) throws -> [TaxTriageSample] {
        let platform = request.settings.platform
        let inputs: [URL]
        do {
            inputs = try services.expandInputs([inputPath], request.recursive)
        } catch {
            throw TaxTriageRunRefusal.input(error.localizedDescription)
        }
        guard !inputs.isEmpty else {
            throw TaxTriageRunRefusal.input("No eligible FASTQ inputs found in \(inputPath)")
        }

        if let input2Path = request.input2 {
            guard inputs.count == 1 else {
                throw TaxTriageRunRefusal.input("--input2 cannot be combined with a directory containing multiple inputs")
            }
            let read2 = URL(fileURLWithPath: input2Path)
            guard FileManager.default.fileExists(atPath: read2.path) else {
                throw TaxTriageRunRefusal.input("Input R2 file not found: \(input2Path)")
            }
            return [TaxTriageSample(
                sampleId: request.sampleID ?? Self.stem(of: inputs[0]),
                fastq1: inputs[0],
                fastq2: read2,
                platform: platform
            )]
        }

        let folder = URL(fileURLWithPath: inputPath).standardizedFileURL
        if Self.isFolder(folder), let mates = Self.firstMatePair(in: inputs) {
            throw TaxTriageRunRefusal.folderHoldsPairedReads(
                folder: folder.path,
                read1: Self.name(of: mates.read1, in: folder),
                read2: Self.name(of: mates.read2, in: folder)
            )
        }
        return inputs.map { url in
            TaxTriageSample(
                sampleId: Self.sampleID(for: url, explicitSampleID: request.sampleID, totalSampleCount: inputs.count),
                fastq1: url,
                platform: platform
            )
        }
    }

    /// T8. The first pair of mates by name among the loose files, by the grouper's R1 and R2 names, or
    /// nil. A `.lungfishfastq` bundle is one sample whatever its name, so a folder of bundles is never
    /// refused, and no file is renamed or regrouped, because the refusal only names the fix.
    static func firstMatePair(in inputs: [URL]) -> (read1: URL, read2: URL)? {
        let looseFiles = inputs.filter { !FASTQBundle.isBundleURL($0) }
        for sample in MetagenomicsSampleGrouper.group(looseFiles) {
            if let read2 = sample.fastq2 {
                return (sample.fastq1, read2)
            }
        }
        return nil
    }

    /// Whether `url` is a folder of inputs, a directory that is not a `.lungfishfastq` bundle.
    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !FASTQBundle.isBundleURL(url)
    }

    /// `file` as the folder holds it, its path below `folder`, or its whole path when it lies elsewhere.
    static func name(of file: URL, in folder: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : filePath
    }

    /// The sample name of one input, as `taxtriage run` has always named it. `--sample` names the one
    /// input, and prefixes each input's stem when a folder holds several.
    static func sampleID(for url: URL, explicitSampleID: String?, totalSampleCount: Int) -> String {
        let base = stem(of: url)
        guard let explicitSampleID, !explicitSampleID.isEmpty else {
            return base
        }
        return totalSampleCount == 1 ? explicitSampleID : "\(explicitSampleID)-\(base)"
    }

    /// The file name without its last two extensions, so `S1.fastq.gz` gives `S1`.
    static func stem(of url: URL) -> String {
        url.deletingPathExtension().deletingPathExtension().lastPathComponent
    }

    // MARK: - Settings

    /// The Kraken2 database `--db` names, which TaxTriage v3.3.x needs, since it refuses a run with
    /// neither `--db` nor `--download_db` deep inside Nextflow.
    func refuseMissingDatabase() throws {
        guard let database = request.settings.kraken2DatabasePath else {
            throw TaxTriageRunRefusal.input("A Kraken2 database is required: pass --db <path>")
        }
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw TaxTriageRunRefusal.input("Database not found: \(database.path)")
        }
    }

    /// The checks of `TaxTriageConfig.validate()` that need no input resolved, with its words, for one
    /// launch. The pipeline repeats them when it runs.
    static func refuseInvalidSettings(of config: TaxTriageConfig) throws {
        let ids = config.samples.map(\.sampleId)
        if ids.contains(where: \.isEmpty) {
            throw refusal(.emptySampleId)
        }
        let duplicates = Dictionary(grouping: ids, by: { $0 })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        guard duplicates.isEmpty else {
            throw refusal(.duplicateSampleIds(duplicates))
        }
        guard config.k2Confidence >= 0.0 && config.k2Confidence <= 1.0 else {
            throw refusal(.invalidK2Confidence(config.k2Confidence))
        }
        guard config.topHitsCount > 0 else {
            throw refusal(.invalidTopHitsCount(config.topHitsCount))
        }
        if let removeTaxids = config.removeTaxids {
            let invalid = TaxTriageConfig.invalidTaxIDTokens(in: removeTaxids)
            guard invalid.isEmpty else {
                throw refusal(.invalidRemoveTaxids(invalid))
            }
        }
    }

    /// The files of a samplesheet row exist and are files, as `TaxTriageConfig.validate()` checks them.
    static func refuseUnreadableFiles(of sample: TaxTriageSample) throws {
        for file in sample.allFiles {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
                throw refusal(.inputFileNotFound(sampleId: sample.sampleId, path: file))
            }
            if isDirectory.boolValue {
                throw refusal(.inputPathIsDirectory(sampleId: sample.sampleId, path: file))
            }
        }
    }

    static func refusal(_ error: TaxTriageConfigError) -> TaxTriageRunRefusal {
        .input(error.localizedDescription)
    }

    // MARK: - Layout (T5)

    /// The layout of a run, decision T5. A plain `--output` pools every sample into one launch in the
    /// folder it names (2.8 T2). A one-sample `--project` run writes into `taxtriage-batch-<ts>`
    /// itself, as the app's run does (2.8 T4). Several samples of a `--project` run, and the samples of
    /// a `--batch` run, each get their own launch and folder.
    static func layout(
        for destination: AnalysisRunDestination,
        groupsSamples: Bool,
        sampleCount: Int
    ) -> AnalysisRunLayout {
        switch destination {
        case .project:
            return sampleCount == 1 ? .sharedBatchRoot : .batchRoot
        case .directory:
            return groupsSamples ? .batchRoot : .singleFolder
        }
    }

    /// The label of a launch, its sample's name, or the count of the samples it pools.
    static func label(of samples: [TaxTriageSample]) -> String {
        samples.count == 1 ? samples[0].sampleId : "\(samples.count) samples"
    }
}

/// One TaxTriage launch as the plan made it, every sample of a plain `--output` run or one sample of a
/// `--project` or `--batch` run (T5).
package struct TaxTriageRunUnit: Sendable {
    /// The launch's configuration. Its samples keep the names their user gave them (T9), its revision
    /// is the `-r` the launch passes, and its output folder is the destination as the plan knows it,
    /// which the unit's run replaces with the folder the executor made for it.
    package let config: TaxTriageConfig
    /// The revision the launch runs as `-r`, the `--revision` given or else the commit the lock pins,
    /// which the step records as its version (R1, A16 M1 review ruling 1). It is never the pin's commit
    /// when another revision runs.
    package let revision: String
    /// The release tag of that revision, which the step records as `githubReleaseVersion` (R1). It is
    /// the lock's tag when the launch runs the pinned commit or tag, and nil when the revision names no tag.
    package let githubReleaseVersion: String?
    /// Whether the unit's folder is the result folder, a `.singleFolder` or `.sharedBatchRoot` run, so
    /// the root record replaces the pipeline's record and the unit hands every fact of it to the root
    /// record, as `Kraken2RunUnit.handsFactsToRoot` says.
    package let handsFactsToRoot: Bool

    package init(config: TaxTriageConfig, revision: String, githubReleaseVersion: String?, handsFactsToRoot: Bool) {
        self.config = config
        self.revision = revision
        self.githubReleaseVersion = githubReleaseVersion
        self.handsFactsToRoot = handsFactsToRoot
    }
}

/// What a completed TaxTriage launch hands to the finalize.
package struct TaxTriageUnitResult: Sendable {
    package let result: TaxTriageResult

    package init(result: TaxTriageResult) {
        self.result = result
    }
}
