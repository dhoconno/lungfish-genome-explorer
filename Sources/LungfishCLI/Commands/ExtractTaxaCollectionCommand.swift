// ExtractTaxaCollectionCommand.swift - extract taxa-collection, one read file per taxon of a collection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// A refusal of `extract taxa-collection` before it writes anything, which exits 3 and names the fix.
struct ExtractTaxaCollectionRefusal: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What a run of `extract taxa-collection` wrote, which its `complete` event names.
struct ExtractTaxaCollectionOutcome: Sendable {
    let outputs: [String]
    let collectionName: String

    /// The `complete` event's message, the words the Operations row ends with.
    var message: String { "Extracted \(outputs.count) taxa from \(collectionName)" }
}

/// Extracts the reads of every taxon of a taxa collection from a Kraken2 classification result, one
/// gzip FASTQ file per taxon (Phase 2.11 lane A66). It is the command behind the Extract button of the
/// taxa collections drawer, which writes into `extracted-<collection id>` beside the result. The files
/// are the ones `TaxonomyExtractionPipeline.extractBatch` writes, so a result that holds several read
/// files gives each taxon one file with the pairs together (decisions D7d and D7e of Phase 2.10).
///
/// ```
/// lungfish-cli extract taxa-collection --result Analyses/kraken2-run \
///     --collection-id respiratory-viruses --collection-name "Respiratory Viruses" \
///     --target "11320,children,Influenza A virus" --target "12814,exact,RSV" \
///     --output-dir Analyses/kraken2-run/extracted-respiratory-viruses
/// ```
struct ExtractTaxaCollectionSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "taxa-collection",
        abstract: "Extract the reads of each taxon of a collection from a Kraken2 result",
        discussion: """
        Writes one gzip FASTQ file per taxon into --output-dir, named after the taxon's display name and \
        tax ID, as the Extract button of the taxa collections drawer does. Each --target gives one taxon \
        as <taxId>,<children|exact>,<display name>. A taxon with children also takes the reads of its \
        descendants, which needs the report of the result. A taxon without reads in the result is \
        skipped. When the result holds several read files, a taxon's file holds each pair together.

        With --format json standard output holds only the event lines. SIGTERM cancels the run, which \
        is recorded as cancelled, and the command exits 125.
        """
    )

    @Option(name: .customLong("result"), help: "Kraken2 classification result folder")
    var result: String

    @Option(name: .customLong("collection-id"), help: "Identifier of the collection")
    var collectionID: String

    @Option(name: .customLong("collection-name"), help: "Name of the collection, used in messages")
    var collectionName: String

    @Option(
        name: .customLong("target"),
        help: "A taxon as <taxId>,<children|exact>,<display name>. Repeat for each taxon of the collection."
    )
    var targets: [String] = []

    @Option(name: .customLong("output-dir"), help: "Folder for the per-taxon files")
    var outputDirectory: String

    @OptionGroup var globalOptions: GlobalOptions

    static let startMessage = "Extracting taxa of a collection…"
    static let cancelledMessage = "Taxa collection extraction cancelled."

    func validate() throws {
        guard !targets.isEmpty else {
            throw ValidationError("At least one --target is required")
        }
        for target in targets {
            _ = try Self.parseTarget(target)
        }
    }

    /// One `--target` value as a taxon of the collection.
    static func parseTarget(_ text: String) throws -> TaxonTarget {
        let parts = text.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let taxId = Int(parts[0].trimmingCharacters(in: .whitespaces)), taxId > 0,
              ["children", "exact"].contains(parts[1].trimmingCharacters(in: .whitespaces)),
              !parts[2].isEmpty else {
            throw ValidationError("--target must be <taxId>,<children|exact>,<display name>, not '\(text)'")
        }
        return TaxonTarget(name: parts[2], taxId: taxId, includeChildren: parts[1].trimmingCharacters(in: .whitespaces) == "children")
    }

    // MARK: - Execution

    func run() async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        events.emitStart(Self.startMessage)
        let startedAt = Date()
        switch await extractCancellingOnSIGTERM(events: events) {
        case .success(let outcome):
            events.emitComplete(outputs: outcome.outputs, message: outcome.message)
            printHumanLine(outcome.message, eventsOn: eventsOn)
            for path in outcome.outputs { printHumanLine("  \(path)", eventsOn: eventsOn) }
        case .failure(let error) where error is CancellationError:
            await recordCancelledRun(startedAt: startedAt)
            events.emitFailed(Self.cancelledMessage)
            printHumanLine(Self.cancelledMessage, eventsOn: eventsOn)
            throw CLIExitCode.cancelled.exitCode
        case .failure(let refusal as ExtractTaxaCollectionRefusal):
            events.emitFailed(refusal.message)
            printHumanLine(TerminalFormatter(useColors: globalOptions.useColors).error(refusal.message), eventsOn: eventsOn)
            throw CLIExitCode.inputError.exitCode
        case .failure(let error):
            events.emitFailed(error.localizedDescription)
            throw error
        }
    }

    /// The batch of ``extractBatch``, taxon by taxon, with its progress as events.
    func extract(events: CLIEventEmitter) async throws -> ExtractTaxaCollectionOutcome {
        let resultURL = URL(fileURLWithPath: result, isDirectory: true)
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            throw ExtractTaxaCollectionRefusal("Classification result not found: \(result)")
        }
        let classification: ClassificationResult
        do {
            classification = try ClassificationResult.load(from: resultURL)
        } catch {
            throw ExtractTaxaCollectionRefusal("\(result) is not a Kraken2 classification result: \(error.localizedDescription)")
        }
        let collection = TaxaCollection(
            id: collectionID, name: collectionName, description: "", sfSymbol: "circle",
            taxa: try targets.map(Self.parseTarget)
        )
        let outputs = try await TaxonomyExtractionPipeline().extractBatch(
            collection: collection,
            classificationResult: classification,
            tree: classification.tree,
            outputDirectory: URL(fileURLWithPath: outputDirectory, isDirectory: true),
            progress: { fraction, message in events.emitProgress(fraction, message: message) }
        )
        return ExtractTaxaCollectionOutcome(outputs: outputs.map(\.path), collectionName: collectionName)
    }

    /// Runs `extract(events:)` so that SIGTERM cancels it instead of ending the command. The command
    /// listens before the task starts, so a SIGTERM caught before then cancels the task as soon as it
    /// exists, and a second SIGTERM ends the command at once.
    private func extractCancellingOnSIGTERM(events: CLIEventEmitter) async -> Result<ExtractTaxaCollectionOutcome, any Error> {
        let pendingCancel = PendingTaskCancel<Result<ExtractTaxaCollectionOutcome, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        defer { termination.end() }
        let command = self
        let task = Task { () -> Result<ExtractTaxaCollectionOutcome, any Error> in
            do {
                return .success(try await command.extract(events: events))
            } catch {
                // A tool stopped by the cancel fails with its own error, which is the cancel.
                return .failure(Task.isCancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        return await task.value
    }

    /// The words the process was started with when it runs `extract taxa-collection`, so the record's
    /// argv is the command the row recorded, `--format json` included.
    private static func observedArguments() -> [String]? {
        let raw = CommandLine.arguments
        guard let executable = raw.first else { return nil }
        let arguments = Array(raw.dropFirst())
        let normalized = LungfishCLI.normalizedArgumentsForParsing(arguments)
        guard normalized.starts(with: ["extract", "taxa-collection"]) else { return nil }
        return [executable] + arguments
    }

    /// The command as the record names it.
    func provenanceCommand() -> [String] {
        Self.observedArguments()
            ?? ([CLICommandIdentity.executableName, "extract", "taxa-collection", "--result", result,
                 "--collection-id", collectionID, "--collection-name", collectionName]
                + targets.flatMap { ["--target", $0] }
                + ["--output-dir", outputDirectory]
                + (globalOptions.outputFormat == .json ? ["--format", "json"] : []))
    }

    /// Records a run that a cancel stopped as cancelled, in the folder its files go to. A failure
    /// to write it does not hide the cancel.
    private func recordCancelledRun(startedAt: Date) async {
        let folder = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try? await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish extract taxa-collection",
            parameters: [
                "result": .file(URL(fileURLWithPath: result)),
                "collectionID": .string(collectionID),
                "collectionName": .string(collectionName),
                "targets": .array(targets.map(ParameterValue.string)),
            ],
            toolName: "lungfish extract taxa-collection",
            toolVersion: WorkflowRun.currentAppVersion,
            command: provenanceCommand(),
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.exitCode.rawValue,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: Self.cancelledMessage,
            status: .cancelled,
            outputDirectory: folder,
            writeFileSidecars: false
        )
    }
}
