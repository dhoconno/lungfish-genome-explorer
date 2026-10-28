// Kraken2RunRecordOptions.swift - The options, steps and outputs a Kraken2 run's root record holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// What the root record of a `kraken2 classify` run holds besides what the executor writes itself.
///
/// The facts are the ones the `lungfish.classify` wrapper record held when the command wrote its
/// own record (`ClassifyCommand.writeProvenance` before 2.7), with three changes. `preset` is
/// recorded only when `--preset` was given, and the defaults are one table of the command's real
/// defaults (decision E12, differences D7 and D8). The read-set plan is kept in the resolved
/// options (E13, difference D6). A degraded Bracken profile is `completed` (E4).
public enum Kraken2RunRecordOptions {
    /// The workflow names of the classification pipeline's own record.
    public static let pipelineWorkflowNames: Set<String> = ["Metagenomics Classification", "Metagenomics Profiling"]

    /// The command's defaults, the values an option takes when it is not given. A preset that was
    /// never chosen is not a fact, so the table names none, and the thresholds are the balanced
    /// preset's, which the command runs without one.
    public static var commandDefaults: [String: ParameterValue] {
        let balanced = ClassificationConfig.Preset.balanced.parameters
        return [
            "pairedEnd": .boolean(false),
            "readFormat": .string(Kraken2ReadFormatChoice.auto.rawValue),
            "recursive": .boolean(false),
            "profile": .boolean(false),
            "confidence": .number(balanced.confidence),
            "minimumHitGroups": .integer(balanced.minimumHitGroups),
            "threads": .integer(Kraken2RunRequest.defaultThreads),
            "memoryMapping": .boolean(false),
            "quickMode": .boolean(false),
            "brackenRankRequest": .string("automatic"),
            "brackenReadLength": .integer(BrackenProfileRequest.automaticDefault.readLength),
            "brackenThreshold": .integer(BrackenProfileRequest.automaticDefault.threshold),
            "extraArguments": .array([]),
        ]
    }

    /// The root record's options of a one-folder run.
    public static func rootOptions(
        config: ClassificationConfig,
        outcome: BrackenProfileOutcome,
        request: Kraken2RunRequest,
        argv: [String],
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> AnalysisRootRecordOptions {
        AnalysisRootRecordOptions(
            explicit: explicit(config: config, request: request, argv: argv, originalInputURLs: originalInputURLs),
            defaults: commandDefaults,
            resolved: resolved(
                config: config,
                outcome: outcome,
                request: request,
                argv: argv,
                originalInputURLs: originalInputURLs,
                executionInputURLs: executionInputURLs
            ),
            readSetPlan: AnalysisRootRecordOptions.readSetPlanValue(of: config.readSetPlan)
        )
    }

    /// The options of a batch sample's pipeline record, converged on the root record's rules.
    /// Every default the command's table also names takes the command's value and a preset nobody
    /// gave goes (E12, D8). The pipeline writes the read-set plan under the resolved options
    /// itself (E13, B16), so the explicit and resolved options pass unchanged.
    public static func convergedSampleOptions(_ options: ProvenanceOptions) -> ProvenanceOptions {
        let table = commandDefaults
        var defaults = options.defaults
        for key in Array(defaults.keys) {
            if let value = table[key] { defaults[key] = value }
        }
        defaults["preset"] = nil
        return ProvenanceOptions(explicit: options.explicit, defaults: defaults, resolvedDefaults: options.resolvedDefaults)
    }

    /// The options given on the command line, each with the value the run used.
    static func explicit(
        config: ClassificationConfig,
        request: Kraken2RunRequest,
        argv: [String],
        originalInputURLs: [URL]
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "databaseName": .string(config.databaseName),
            "originalInputs": .array(unique(originalInputURLs).map { .file($0.standardizedFileURL) }),
        ]
        let given = { (names: Set<String>) in argvContainsOption(argv, names: names) }
        if given(["--output-dir", "-o"]) { options["outputDirectory"] = .file(config.outputDirectory) }
        if given(["--preset"]) { options["preset"] = .string(request.preset.rawValue) }
        if given(["--db-digest"]), let digest = request.databaseDigest { options["databaseDigest"] = .string(digest) }
        if given(["--paired"]) { options["pairedEnd"] = .boolean(config.isPairedEnd) }
        // The choice typed, `auto` included. The format the run resolved is a resolved option (SW26 note 2).
        if given(["--read-format"]) { options["readFormat"] = .string(request.readFormat.rawValue) }
        if given(["--recursive"]) { options["recursive"] = .boolean(true) }
        if given(["--profile"]) { options["profile"] = .boolean(true) }
        if given(["--confidence"]) { options["confidence"] = .number(config.confidence) }
        if given(["--min-hit-groups"]) { options["minimumHitGroups"] = .integer(config.minimumHitGroups) }
        if given(["--threads"]) { options["threads"] = .integer(config.threads) }
        if given(["--memory-mapping"]) { options["memoryMapping"] = .boolean(config.memoryMapping) }
        if given(["--quick"]) { options["quickMode"] = .boolean(config.quickMode) }
        if let readLength = argvOptionValue(argv, names: ["--bracken-read-length"]).flatMap(Int.init) {
            options["brackenReadLength"] = .integer(readLength)
        }
        if let level = argvOptionValue(argv, names: ["--bracken-level"]) {
            options["brackenLevel"] = .string(level)
            options["brackenRankRequest"] = .string(BrackenRankRequest.explicit(TaxonomicRank(code: level)).provenanceValue)
        }
        if let threshold = argvOptionValue(argv, names: ["--bracken-threshold"]).flatMap(Int.init) {
            options["brackenThreshold"] = .integer(threshold)
        }
        if given(["--extra-args"]) { options["extraArguments"] = .array(config.extraArguments.map(ParameterValue.string)) }
        if let minutes = argvOptionValue(argv, names: [AnalysisTimeLimit.optionName]).flatMap(Int.init) {
            options[AnalysisTimeLimit.recordKey] = .integer(minutes)
        }
        return options
    }

    /// Every value the run resolved, the database identity and the Bracken outcome.
    static func resolved(
        config: ClassificationConfig,
        outcome: BrackenProfileOutcome,
        request: Kraken2RunRequest,
        argv: [String],
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) -> [String: ParameterValue] {
        let bracken = config.brackenProfileRequest
        let resolution = outcome.resolution ?? bracken.map {
            BrackenDatabaseCapabilities.resolve(
                catalogID: config.databaseCatalogID,
                installationRecipe: config.databaseInstallationRecipe,
                request: $0
            )
        }
        let profileRequested = config.goal == .profile || bracken != nil || outcome.state != .notRequested
        var options: [String: ParameterValue] = [
            "databaseName": .string(config.databaseName),
            "databaseVersion": .string(config.databaseVersion.isEmpty ? "unknown" : config.databaseVersion),
            "databaseDigest": config.databaseDigest.map(ParameterValue.string) ?? .null,
            "databaseCatalogID": config.databaseCatalogID.map(ParameterValue.string) ?? .null,
            "databaseInstallationRecipe": config.databaseInstallationRecipe.map { .string($0.provenanceValue) } ?? .null,
            "databasePath": .file(config.databasePath),
            "inputFormat": .string(config.inputFormat.rawValue),
            "goal": .string(config.goal.rawValue),
            "pairedEnd": .boolean(config.isPairedEnd),
            "readFormat": .string(config.readFormat.rawValue),
            "recursive": .boolean(request.recursive),
            "profile": .boolean(profileRequested),
            "confidence": .number(config.confidence),
            "minimumHitGroups": .integer(config.minimumHitGroups),
            "threads": .integer(config.threads),
            "memoryMapping": .boolean(config.memoryMapping),
            "quickMode": .boolean(config.quickMode),
            "brackenRankRequest": bracken.map { .string($0.rank.provenanceValue) } ?? .string("notRequested"),
            "brackenRequestedReadLength": bracken.map { .integer($0.readLength) } ?? .null,
            "brackenRequestedThreshold": bracken.map { .integer($0.threshold) } ?? .null,
            "brackenResolvedRank": resolution.map { .string($0.rank.code) } ?? .null,
            "brackenResolutionSource": resolution.map { .string($0.source.rawValue) } ?? .null,
            "brackenReadLength": resolution.map { .integer($0.readLength) } ?? .null,
            "brackenThreshold": resolution.map { .integer($0.threshold) } ?? .null,
            "profileState": .string(outcome.state.rawValue),
            "profileReason": outcome.reason.map { .string($0.rawValue) } ?? .null,
            "profileMessage": outcome.message.map(ParameterValue.string) ?? .null,
            "brackenToolVersion": outcome.toolVersion.map(ParameterValue.string) ?? .null,
            "outputDirectory": .file(config.outputDirectory),
            "extraArguments": .array(config.extraArguments.map(ParameterValue.string)),
            "originalInputs": .array(originalInputURLs.map { .file($0.standardizedFileURL) }),
            "executionInputs": .array(executionInputURLs.map { .file($0.standardizedFileURL) }),
        ]
        if argvContainsOption(argv, names: ["--preset"]) {
            options["preset"] = .string(request.preset.rawValue)
        }
        if let bracken, case .explicit(let rank) = bracken.rank {
            options["brackenExplicitRank"] = .string(rank.code)
        }
        if let minutes = argvOptionValue(argv, names: [AnalysisTimeLimit.optionName]).flatMap(Int.init) {
            options[AnalysisTimeLimit.recordKey] = .integer(minutes)
        }
        return options
    }

    // MARK: - Steps

    /// The steps of a one-folder run's root record after the pipeline ran, in the order the
    /// wrapper record held them. The pipeline's kraken2 step comes first, or a step made from the
    /// result when the pipeline left no record of this run, then a Bracken step when the pipeline
    /// recorded none, then every other step of the pipeline's record.
    public static func steps(
        for result: ClassificationResult,
        pipelineEnvelope: ProvenanceEnvelope?,
        executionInputs: [ProvenanceFileDescriptor],
        startedAt: Date,
        endedAt: Date
    ) throws -> [ProvenanceStep] {
        let current = pipelineEnvelope.flatMap { isCurrent($0, result: result) ? $0 : nil }
        let config = result.config
        let krakenArgv = ["kraken2"] + config.kraken2Arguments()
        let kraken = try current?.steps.first { $0.toolName == "kraken2" && $0.exitStatus == 0 }
            ?? ProvenanceStep(
                toolName: "kraken2",
                toolVersion: result.toolVersion,
                argv: krakenArgv,
                reproducibleCommand: krakenArgv.map(shellEscape).joined(separator: " "),
                inputs: executionInputs,
                outputs: [result.reportURL, config.outputURL]
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                    .map { try ProvenanceFileDescriptor.file(url: $0, format: .text, role: .output) },
                exitStatus: 0,
                wallTimeSeconds: result.runtime,
                startedAt: startedAt,
                completedAt: endedAt
            )
        var steps = [kraken]
        if let bracken = try brackenFallbackStep(result: result, currentPipelineEnvelope: current, startedAt: endedAt) {
            steps.append(bracken)
        }
        guard let current else { return steps }
        let made = Dictionary(steps.map { ($0.toolName, $0.id) }, uniquingKeysWith: { first, _ in first })
        let remap = Dictionary(
            current.steps.compactMap { step in made[step.toolName].map { (step.id, $0) } },
            uniquingKeysWith: { _, last in last }
        )
        let preserved = current.steps
            .filter { made[$0.toolName] == nil }
            .map { step in step.with { $0.dependsOn = step.dependsOn.map { remap[$0] ?? $0 } } }
        return steps + preserved
    }

    /// The steps of the pipeline's record of a run that failed after the pipeline started, when
    /// that record was written during this run.
    public static func stepsOfFailedPipeline(in directory: URL, startedAt: Date, endedAt: Date) -> [ProvenanceStep] {
        pipelineRecordOfThisRun(in: directory, startedAt: startedAt, endedAt: endedAt)?.steps ?? []
    }

    /// The pipeline's record in `directory` when it was written between `startedAt` and `endedAt`,
    /// a second of slack on each side, so a record an earlier run left is never read as this run's.
    static func pipelineRecordOfThisRun(in directory: URL, startedAt: Date, endedAt: Date) -> ProvenanceEnvelope? {
        guard let envelope = ProvenanceRecorder.loadEnvelope(from: directory),
              pipelineWorkflowNames.contains(envelope.workflowName),
              envelope.createdAt >= startedAt.addingTimeInterval(-1),
              envelope.createdAt <= endedAt.addingTimeInterval(1) else {
            return nil
        }
        return envelope
    }

    /// The run-level files of a one-folder result that exist, for the root record's outputs.
    public static func outputs(for result: ClassificationResult) -> [AnalysisRunOutput] {
        var outputs: [AnalysisRunOutput] = [
            AnalysisRunOutput(url: result.reportURL, format: .text, role: .report),
            AnalysisRunOutput(url: result.outputURL, format: .text, role: .output),
            AnalysisRunOutput(url: KrakenIndexDatabase.indexURL(for: result.outputURL), format: .unknown, role: .index),
        ]
        if let bracken = result.brackenURL {
            outputs.append(AnalysisRunOutput(url: bracken, format: .text, role: .output))
        }
        outputs.append(AnalysisRunOutput(
            url: result.config.outputDirectory.appendingPathComponent(ClassificationResult.sidecarFilename),
            format: .json,
            role: .report
        ))
        return outputs.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Whether `envelope` is the pipeline's record of the run that wrote `result`.
    static func isCurrent(_ envelope: ProvenanceEnvelope, result: ClassificationResult) -> Bool {
        guard pipelineWorkflowNames.contains(envelope.workflowName) else { return false }
        let paths = Set([result.reportURL.standardizedFileURL.path, result.outputURL.standardizedFileURL.path])
        let recorded = Set((envelope.files + envelope.outputs).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        return !paths.isDisjoint(with: recorded)
    }

    /// A Bracken step for a profile whose pipeline record holds none, made from the result.
    static func brackenFallbackStep(
        result: ClassificationResult,
        currentPipelineEnvelope: ProvenanceEnvelope?,
        startedAt: Date
    ) throws -> ProvenanceStep? {
        guard let brackenURL = result.brackenURL, FileManager.default.fileExists(atPath: brackenURL.path) else {
            return nil
        }
        if currentPipelineEnvelope?.steps.contains(where: { step in
            step.toolName == "bracken" && step.exitStatus == 0 && step.outputs.contains { $0.path == brackenURL.path }
        }) == true {
            return nil
        }
        let config = result.config
        let resolution = result.profileOutcome.resolution ?? config.brackenProfileRequest.map {
            BrackenDatabaseCapabilities.resolve(
                catalogID: config.databaseCatalogID,
                installationRecipe: config.databaseInstallationRecipe,
                request: $0
            )
        }
        let argv = [
            "bracken", "-d", config.databasePath.path, "-i", result.reportURL.path, "-o", brackenURL.path,
            "-r", String(resolution?.readLength ?? BrackenDatabaseCapabilities.supportedReadLength),
            "-l", resolution.flatMap { BrackenDatabaseCapabilities.levelCode(for: $0.rank) } ?? "S",
            "-t", String(resolution?.threshold ?? config.brackenProfileRequest?.threshold ?? 10),
        ]
        return ProvenanceStep(
            toolName: "bracken",
            toolVersion: result.profileOutcome.toolVersion ?? "unknown",
            argv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            inputs: [try ProvenanceFileDescriptor.file(url: result.reportURL, format: .text, role: .input)],
            outputs: [try ProvenanceFileDescriptor.file(url: brackenURL, format: .text, role: .output)],
            exitStatus: 0,
            wallTimeSeconds: 0,
            startedAt: startedAt,
            completedAt: startedAt
        )
    }

    // MARK: - Command line

    /// Whether `argv` gives an option of `names`, as `--name value` or `--name=value`.
    public static func argvContainsOption(_ argv: [String], names: Set<String>) -> Bool {
        argv.contains { argument in
            names.contains(argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? argument)
        }
    }

    /// The value `argv` gives the first option of `names`, or nil.
    public static func argvOptionValue(_ argv: [String], names: Set<String>) -> String? {
        for (index, argument) in argv.enumerated() {
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard names.contains(String(parts[0])) else { continue }
            if parts.count == 2 { return String(parts[1]) }
            return argv.indices.contains(index + 1) ? argv[index + 1] : nil
        }
        return nil
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        urls.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}
