// Kraken2AnalysisRunTool.swift - Kraken2 and Bracken as an analysis run tool, and its plan (phase P0)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Kraken2 classification, with an optional Bracken profile, under the analysis run executor
/// (2.7 A8). `lungfish-cli kraken2 classify` and `conda classify` run it, and the app's route
/// runs that command.
///
/// One unit is one sample. Without `--batch` every input is one sample in one folder, as the
/// command has always run them. With `--batch` the inputs are grouped into samples by
/// ``MetagenomicsSampleGrouper`` (decision E8) and each sample gets its own folder in a batch root.
/// A unit materializes virtual inputs into `<root>/.lungfish-classify-inputs/` and keeps them (E3),
/// plans the read set with ``KrakenReadSetPlanner`` and runs ``ClassificationPipeline``. A degraded
/// Bracken profile completes the unit with a warning (E4).
public struct Kraken2AnalysisRunTool: AnalysisRunTool {
    /// The workflow name of the root record, as the command has always recorded it.
    public static let workflowName = "lungfish.classify"

    public let request: Kraken2RunRequest
    public let services: Kraken2RunServices

    public init(request: Kraken2RunRequest, services: Kraken2RunServices = Kraken2RunServices()) {
        self.request = request
        self.services = services
    }

    public var identity: AnalysisRunIdentity {
        AnalysisRunIdentity(toolID: .kraken2, workflowName: Self.workflowName)
    }

    /// A failed sample of a batch is a warning while another sample completes, as the app's batch
    /// has always ended. A run of one sample fails with it.
    public var terminalPolicy: AnalysisRunTerminalPolicy { .warnOnFailedUnits }

    /// Phase P0. Every refusal of the request, before any folder exists.
    public func plan(
        _ runRequest: AnalysisRunRequest,
        context: AnalysisRunPlanningContext
    ) async throws -> AnalysisRunPlan<Kraken2RunUnit> {
        guard ScientificProvenancePolicy.cliCommand(path: request.commandPath) != nil else {
            throw Kraken2RunRefusal(
                message: "No provenance policy names `\(request.commandPath.joined(separator: " "))`.",
                exitCode: AnalysisRunExitCode.workflowError
            )
        }
        if let confidence = request.confidence, !(0.0...1.0).contains(confidence) {
            throw Kraken2RunRefusal.input("Confidence must be between 0.0 and 1.0, got \(confidence)")
        }
        let inputURLs = try services.expandInputs(request.inputArguments, request.recursive).map(\.standardizedFileURL)
        guard !inputURLs.isEmpty else {
            throw Kraken2RunRefusal.input("No eligible FASTQ or FASTA inputs found.")
        }
        // A demultiplexed group bundle is a container with no reads of its own. It is refused
        // before the read format, the database and the output are looked at, with the input
        // error code and in the words `esviritu detect` uses, so no folder or record is touched
        // (2.7 row 421).
        for url in inputURLs {
            if let message = CLISequenceInputMaterialization.unsupportedSequenceInputMessage(for: url, operationName: "classification") {
                throw Kraken2RunRefusal.input(message)
            }
        }
        let samples = try Self.samples(of: inputURLs, request: request, batch: runRequest.groupsSamples)
        let inputFormat = try Kraken2RunRequest.inferInputFormat(from: inputURLs)
        let (database, databasePath, recordInputs) = try await resolveDatabase()
        let extraArguments: [String]
        do {
            extraArguments = try AdvancedCommandLineOptions.parse(request.extraArguments)
        } catch {
            throw Kraken2RunRefusal.input(error.localizedDescription)
        }
        for url in inputURLs {
            if !CLISequenceInputMaterialization.requiresMaterialization(url),
               SequenceInputResolver.resolvePrimarySequenceURL(for: url) == nil {
                throw CLISequenceInputMaterializationError.unreadableSequenceInput(url.path)
            }
        }
        if case .directory(let directory) = runRequest.destination {
            try await refuseInputsInsideEarlierOutputs(inputURLs, directory: directory, databasePath: databasePath)
        }

        let batch = runRequest.groupsSamples
        let units = samples.map { sample in
            AnalysisRunPlannedUnit(
                label: sample.label,
                value: Kraken2RunUnit(
                    request: sample.request,
                    inputURLs: sample.inputURLs,
                    readFormat: sample.readFormat,
                    inputFormat: inputFormat,
                    database: database,
                    databasePath: databasePath,
                    extraArguments: extraArguments,
                    commandLine: runRequest.commandLine,
                    handsFactsToRoot: !batch,
                    destinationIsProject: runRequest.destination.isProject,
                    sampleDisplayName: batch ? sample.label : inputURLs.first?.deletingPathExtension().lastPathComponent
                )
            )
        }
        var options = AnalysisRootRecordOptions()
        if batch, let first = units.first?.value {
            options = batchOptions(first: first, allInputs: inputURLs, destination: runRequest.destination)
        }
        return AnalysisRunPlan(
            layout: batch ? .batchRoot : .singleFolder,
            units: units,
            options: options,
            recordInputs: recordInputs
        )
    }

    // MARK: - Samples

    struct PlannedSample {
        let label: String
        let inputURLs: [URL]
        let request: Kraken2RunRequest
        let readFormat: Kraken2ResolvedReadFormat
    }

    /// One sample of every input, or under `--batch` the grouper's samples, each paired by its R1
    /// and R2 file names.
    static func samples(of inputURLs: [URL], request: Kraken2RunRequest, batch: Bool) throws -> [PlannedSample] {
        guard batch else {
            let readFormat = try request.resolveReadFormat(inputURLs: inputURLs)
            if readFormat.format == .paired, inputURLs.count != 2 {
                throw Kraken2RunRefusal.input("Paired-end mode requires exactly 2 input files, got \(inputURLs.count).")
            }
            if readFormat.format == .interleaved, inputURLs.count != 1 {
                throw Kraken2RunRefusal.input("Interleaved mode requires exactly 1 input file, got \(inputURLs.count).")
            }
            let label = inputURLs.first?.deletingPathExtension().lastPathComponent ?? "sample"
            return [PlannedSample(label: label, inputURLs: inputURLs, request: request, readFormat: readFormat)]
        }
        if request.pairedEnd || !request.unpairedArguments.isEmpty || request.readFormat == .paired {
            throw Kraken2RunRefusal.input(
                "--batch pairs R1 and R2 files by their names, so it takes no --paired, --unpaired or --read-format paired."
            )
        }
        return try MetagenomicsSampleGrouper.group(inputURLs).map { sample in
            var sampleRequest = request
            sampleRequest.inputArguments = sample.inputFiles.map(\.path)
            sampleRequest.pairedEnd = sample.isPairedEnd
            return PlannedSample(
                label: sample.sampleId,
                inputURLs: sample.inputFiles,
                request: sampleRequest,
                readFormat: try sampleRequest.resolveReadFormat(inputURLs: sample.inputFiles)
            )
        }
    }

    // MARK: - Database

    /// The registry entry and folder of `--db`, refused when it is unknown or not ready, and the
    /// verified install receipt when `--db-digest` asks for one (decision E9). No database folder
    /// is hashed, the receipt's own digest is checked against the files it lists.
    func resolveDatabase() async throws -> (MetagenomicsDatabaseInfo, URL, [ProvenanceFileDescriptor]) {
        let name = request.databaseName
        guard let info = try await services.database(name) else {
            let available = ((try? await services.availableDatabases()) ?? [])
                .filter(\.isDownloaded)
                .map { "\($0.name) [\($0.status.rawValue)]" }
            let listed = available.isEmpty ? "" : " Available databases: \(available.joined(separator: ", "))."
            throw Kraken2RunRefusal.input("Database '\(name)' not found in registry.\(listed)")
        }
        guard let path = info.path, info.status == .ready else {
            let hint = info.isDownloaded ? "" : " Download it first: the database has not been installed."
            throw Kraken2RunRefusal.dependency("Database '\(name)' is not ready (status: \(info.status.rawValue)).\(hint)")
        }
        guard let given = request.databaseDigest else { return (info, path, []) }
        guard let wanted = Kraken2DatabaseReceipt.normalizedSHA256(given) else {
            throw Kraken2RunRefusal.input("--db-digest must be a SHA-256 of 64 hexadecimal digits, got \(given).")
        }
        guard let reference = Kraken2DatabaseReceipt.verifiedReference(databasePath: path, registryDigest: info.payloadDigest) else {
            throw Kraken2RunRefusal.dependency(
                "Database '\(name)' has no install receipt that checks out, so --db-digest cannot be confirmed."
            )
        }
        guard reference.checksumSHA256 == wanted else {
            throw Kraken2RunRefusal.dependency(
                "Database '\(name)' holds digest \(reference.checksumSHA256 ?? "none"), not the --db-digest \(wanted)."
            )
        }
        return (info, path, [reference])
    }

    /// Refuses an input inside an output an earlier run left in the named folder, which the
    /// pipeline would remove before it runs, so the earlier run keeps its folder and its record.
    func refuseInputsInsideEarlierOutputs(_ inputURLs: [URL], directory: URL, databasePath: URL) async throws {
        let provisional = ClassificationConfig(
            goal: request.profile ? .profile : .classify,
            inputFiles: inputURLs,
            isPairedEnd: false,
            databaseName: request.databaseName,
            databasePath: databasePath,
            outputDirectory: directory.standardizedFileURL
        )
        let inputs = inputURLs + request.unpairedArguments.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for output in await ClassificationPipeline.shared.knownClassificationOutputURLs(config: provisional) {
            do {
                try OutputReplacementCheck.refuseInputs(inputs, inside: output)
            } catch {
                throw Kraken2RunRefusal.input(error.localizedDescription)
            }
        }
    }

    // MARK: - Options

    /// The root record options of a batch, the values every sample shares. Each sample's own
    /// record keeps the values of its sample, such as its read format and Bracken outcome.
    func batchOptions(first: Kraken2RunUnit, allInputs: [URL], destination: AnalysisRunDestination) -> AnalysisRootRecordOptions {
        let config = request.applyingThresholdOverrides(to: request.makeConfig(
            inputURLs: first.inputURLs,
            readFormat: first.readFormat,
            databaseInfo: first.database,
            databasePath: first.databasePath,
            inputFormat: first.inputFormat,
            outputDirectory: destination.url,
            extraArguments: first.extraArguments
        ))
        var options = Kraken2RunRecordOptions.rootOptions(
            config: config,
            outcome: .notRequested,
            request: request,
            argv: first.commandLine,
            originalInputURLs: allInputs,
            executionInputURLs: []
        )
        for key in ["outputDirectory", "executionInputs", "readFormat", "pairedEnd", "profileState", "profileReason", "profileMessage", "brackenToolVersion"] {
            options.resolved[key] = nil
        }
        options.explicit["batch"] = .boolean(true)
        options.readSetPlan = nil
        return options
    }
}

/// One sample of a Kraken2 run, as the plan made it.
public struct Kraken2RunUnit: Sendable {
    /// The request as it applies to this sample. In a batch its inputs and pairing are the sample's.
    public let request: Kraken2RunRequest
    /// The sample's inputs, files or bundles, before materialization.
    public let inputURLs: [URL]
    public let readFormat: Kraken2ResolvedReadFormat
    public let inputFormat: SequenceFormat
    public let database: MetagenomicsDatabaseInfo?
    public let databasePath: URL
    public let extraArguments: [String]
    /// The command that runs the request, the root record's argv.
    public let commandLine: [String]
    /// Whether the unit's folder is the result folder, so the root record replaces the pipeline's
    /// record and the unit hands every fact of it to the root record.
    public let handsFactsToRoot: Bool
    /// Whether the run made its folder in a project (`--project`), which also gets the viewer index
    /// and the source bundle record.
    public let destinationIsProject: Bool
    public let sampleDisplayName: String?
}

/// What a completed Kraken2 unit hands to the finalize.
public struct Kraken2UnitResult: Sendable {
    public let result: ClassificationResult
    /// The `.lungfishfastq` or reference bundle the sample was read from, which records the run in
    /// its analysis history.
    public let sourceBundle: URL?
    /// The sample's inputs before materialization.
    public let inputURLs: [URL]
    public let destinationIsProject: Bool
}

extension AnalysisRunDestination {
    /// Whether the destination is a project, where the executor makes a new folder.
    var isProject: Bool {
        if case .project = self { return true }
        return false
    }

    /// The project or the named folder.
    var url: URL {
        switch self {
        case .project(let url), .directory(let url): return url.standardizedFileURL
        }
    }
}
