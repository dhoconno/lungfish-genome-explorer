// ImportRNASeqAdoptOptions.swift - `import rnaseq <result folder> --adopt`, the import of the counts a Linux run of a
// schema 2 plan returned (Phase 5.3 lane EX-ADOPT M2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// `lungfish-cli import rnaseq <result folder> --adopt --project <project> --name <name>`. The one input names a plan
/// folder that `lungfish-executor run --plan` returned, or a batch of them, and the result is `ExecutorRunAdoption`'s
/// counts adopt. The plan fixed every setting, so each option that sets a count is refused by name.
struct ImportRNASeqAdoptOptions: ParsableArguments {
    @Flag(
        name: .customLong("adopt"),
        help: ArgumentHelp(
            "Adopt the counts a Linux run of lungfish-executor returned, as one result",
            discussion: """
            The one input names the returned plan folder, which holds plan.json, run-record.json and the run's salmon \
            files, or a returned batch folder, which holds one such folder a sample as <sample>/. A batch gives one \
            result of all its samples, and when any sample is refused nothing is imported. Gene sums use the table of \
            the reference set the plan names, in the storage root. The plan fixed every setting, so no option that \
            sets a count is taken with --adopt. A refused adopt writes nothing.
            """
        )
    )
    var adopt = false

    @Flag(name: .customLong("dry-run"), help: "With --adopt, run every check and read and write nothing")
    var dryRun = false

    @Option(name: .customLong("storage-root"), help: "With --adopt, the storage root that holds the plan's reference set (default: the configured location)")
    var storageRoot: String?

    /// The refusal of an adopt option given without `--adopt`.
    var refusalWithoutAdopt: String? {
        guard !adopt else { return nil }
        if dryRun { return "--dry-run is used with --adopt only." }
        if storageRoot != nil { return "--storage-root is used with --adopt only." }
        return nil
    }
}

extension ImportCommand.RNASeqSubcommand {
    /// Each option `--adopt` refuses, in the order the help lists it, with whether it was given and why it is refused.
    var adoptRefusedOptions: [(option: String, given: Bool, reason: String)] {
        let fixed = "the plan the run followed fixed it"
        return [
            ("--tx2gene", tx2genePath != nil, "the adopt sums genes through the table of the plan's reference set"),
            ("--samples", samplesPath != nil, "the plan names each sample"),
            ("--unit", unit != nil, "salmon states its own unit"),
            ("--genome", !genomes.isEmpty, fixed),
            ("--reference-set", referenceSetPath != nil, "the plan names its reference set, which the adopt reads in the storage root"),
            ("--not-host-bam", !notHostBAMValues.isEmpty, fixed),
        ]
    }

    /// The one sentence that refuses the first option `--adopt` does not take, or a count of inputs other than one.
    var adoptRefusal: String? {
        if let refused = adoptRefusedOptions.first(where: \.given) {
            return "\(refused.option) cannot be used with --adopt, because \(refused.reason)."
        }
        guard inputPaths.count == 1 else {
            return "--adopt takes one returned plan folder or batch folder, and \(inputPaths.count) inputs were given."
        }
        return nil
    }

    /// The adopt: each refusal before any file, then one result, with the import's events under `--format json`.
    /// SIGTERM cancels the read and the write on the run's own task, and the writer removes its stage.
    func runAdopt(emitter: ImportCLIEventEmitter, eventsOn: Bool) async throws {
        let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
        let folder = URL(fileURLWithPath: inputPaths.first ?? "").standardizedFileURL
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        let words = adoptRefusal
            ?? (FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? nil : "Project directory not found: \(projectURL.path)")
            ?? (trimmedName.isEmpty ? "--name cannot be empty" : nil)
        if let words {
            emitter.emitFailed(words)
            throw CLIExitCode.inputError.exitCode
        }
        let storageRoot = adoptOptions.storageRoot.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        let startedAt = Date()
        let dryRun = adoptOptions.dryRun
        let outcome = await ImportCancellation.run { () async throws -> String in
            emitter.emitProgress(0.1, message: "Checking \(folder.lastPathComponent)...")
            if dryRun {
                return try ExecutorRunAdoption.dryRunCounts(
                    resultFolder: folder, projectDirectory: projectURL, name: trimmedName, storageRoot: storageRoot)
            }
            return try ExecutorRunAdoption.adoptCounts(
                resultFolder: folder, projectDirectory: projectURL, name: trimmedName, storageRoot: storageRoot, eventsOn: eventsOn
            ).path
        }
        switch outcome {
        case .success(let made) where dryRun:
            printHumanLine("\(folder.lastPathComponent) passed every check and would be adopted as \(made). Nothing was imported.", eventsOn: eventsOn)
        case .success(let path):
            let resultURL = URL(fileURLWithPath: path, isDirectory: true)
            emitter.emitComplete(bundle: resultURL, kind: BundleKindID(rawValue: RNASeqResultManifest.kindName))
            if !globalOptions.quiet { printHumanLine("Adopted \(folder.lastPathComponent) as \(resultURL.path)", eventsOn: eventsOn) }
        case .failure(let error) where error is CancellationError:
            throw await ImportCancellation.finish(
                emitter: emitter, command: "import rnaseq",
                parameters: ["inputs": .array([ParameterValue.file(folder)]), "project": .file(projectURL)],
                recordDirectory: projectURL, startedAt: startedAt)
        case .failure(let exitCode as ExitCode):
            throw exitCode
        case .failure(let refusal as ExecutorAdoptRefusal):
            emitter.emitFailed(refusal.reason)
            throw CLIExitCode.inputError.exitCode
        case .failure(let batch as ExecutorBatchAdoptError):
            emitter.emitFailed([batch.message, batch.detail].compactMap { $0 }.joined(separator: "\n"))
            if case .refused = batch { throw CLIExitCode.inputError.exitCode }
            if case .notABatch = batch { throw CLIExitCode.inputError.exitCode }
            throw CLIExitCode.workflowError.exitCode
        case .failure(let error):
            emitter.emitFailed(CLIFailureWords.describe(error))
            let isInput = error is RNASeqImportError || error is ReferenceSetError || error is RNASeqResultWriterError
            throw (isInput ? CLIExitCode.inputError : CLIExitCode.formatError).exitCode
        }
    }
}
