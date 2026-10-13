// TaxTriageRunRequest.swift - What one taxtriage run asks for, the services its tool runs with, and its refusals
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A2 (decisions T5, T8, T9 and N4, 2.8 T2 and T4). The types take `package` access, so the
// module map gains no public type (N3).

import Foundation
import LungfishIO

/// The options of one `lungfish-cli taxtriage run`, as the command parsed them.
///
/// ``TaxTriageAnalysisRunTool`` turns them into units in its plan. The inputs stay as they were typed,
/// so the plan expands a folder, reads a samplesheet and each bundle, and pairs `--input2` itself,
/// before any folder exists. Every other choice of the command travels in ``settings``.
package struct TaxTriageRunRequest: Sendable {
    /// Each `--input` as typed, in the order given, a FASTQ file, a `.lungfishfastq` bundle or a folder of
    /// them. Empty with `--samplesheet`. The app hands several bundles this way, each one sample (2.10 T6).
    package var inputs: [String]
    /// `--input2` as typed, the R2 file of the pair whose R1 is the one `--input`.
    package var input2: String?
    /// `--recursive`, which also takes the reads in the subfolders of an `--input` folder.
    package var recursive: Bool
    /// `--sample`, the name of the sample one `--input` names. The inputs of a folder, and several inputs,
    /// take it as a prefix.
    package var sampleID: String?
    /// `--samplesheet` as typed.
    package var samplesheet: String?
    /// Each `--negative-control` as typed, the names of the samples the user marks as negative controls,
    /// beside those their bundles' sample roles mark (2.10 T4). Each sample's configuration keeps its mark,
    /// which never reaches Nextflow.
    package var negativeControls: [String]
    /// `--revision` as typed, or nil to run the commit the lock pins (N4, A16 M1 review ruling 1). The
    /// repository always comes from the lock.
    package var revision: String?
    /// `--extra-args` as typed. The plan parses it, so a malformed value refuses the run before any
    /// folder exists.
    package var extraArguments: String
    /// Every other choice of the command, `--platform`, `--db`, `--confidence`, `--top-hits`, `--rank`,
    /// the assembly and Krona switches, `--remove-taxids`, `--max-memory`, `--max-cpus` and
    /// `--nf-profile`. The plan sets the samples, output folder, revision and extra arguments of each
    /// launch, so the values this configuration holds for those four are never read.
    package var settings: TaxTriageConfig
    /// Why the flags that name the result's place cannot run together, such as `--project` with
    /// `--output`, which the plan refuses first, before any folder exists. Nil for none.
    package var usageConflict: String?
    /// Whether the result goes to a project with `--project`, whose completed samples then record the run
    /// in their source bundles, as Kraken2's do (B30 ruling Q2).
    package var destinationIsProject: Bool

    package init(
        inputs: [String] = [],
        input2: String? = nil,
        recursive: Bool = false,
        sampleID: String? = nil,
        samplesheet: String? = nil,
        negativeControls: [String] = [],
        revision: String? = nil,
        extraArguments: String = "",
        settings: TaxTriageConfig,
        usageConflict: String? = nil,
        destinationIsProject: Bool = false
    ) {
        self.inputs = inputs
        self.input2 = input2
        self.recursive = recursive
        self.sampleID = sampleID
        self.samplesheet = samplesheet
        self.negativeControls = negativeControls
        self.revision = revision
        self.extraArguments = extraArguments
        self.settings = settings
        self.usageConflict = usageConflict
        self.destinationIsProject = destinationIsProject
    }

    /// A request of one `--input`, or of none when `input` is nil, as the command took it before 2.10 T6.
    package init(
        input: String?,
        input2: String? = nil,
        recursive: Bool = false,
        sampleID: String? = nil,
        samplesheet: String? = nil,
        revision: String? = nil,
        extraArguments: String = "",
        settings: TaxTriageConfig,
        usageConflict: String? = nil
    ) {
        self.init(
            inputs: input.map { [$0] } ?? [],
            input2: input2,
            recursive: recursive,
            sampleID: sampleID,
            samplesheet: samplesheet,
            revision: revision,
            extraArguments: extraArguments,
            settings: settings,
            usageConflict: usageConflict
        )
    }
}

/// Why a TaxTriage plan refused a request before any folder exists, with the code the command exits
/// with. The codes equal `CLIExitCode` in LungfishCLI, as ``Kraken2RunRefusal``'s do.
package struct TaxTriageRunRefusal: Error, LocalizedError, AnalysisRunExitCoding, Equatable, Sendable {
    /// `CLIExitCode.inputError`.
    package static let inputErrorCode: Int32 = 3
    /// `CLIExitCode.dependency`.
    package static let dependencyCode: Int32 = 126
    /// The words of a run without `--db`. TaxTriage v3.3.x refuses a run with neither `--db` nor
    /// `--download_db` deep inside Nextflow, so the plan refuses it first. The command's text mode
    /// prints its two hints after these words.
    package static let missingDatabaseMessage = "A Kraken2 database is required: pass --db <path>"

    package let message: String
    package let analysisRunExitCode: Int32

    package init(message: String, exitCode: Int32) {
        self.message = message
        self.analysisRunExitCode = exitCode
    }

    package var errorDescription: String? { message }

    /// A request the inputs or options make impossible.
    package static func input(_ message: String) -> TaxTriageRunRefusal {
        TaxTriageRunRefusal(message: message, exitCode: inputErrorCode)
    }

    /// Something the run depends on that is missing.
    package static func dependency(_ message: String) -> TaxTriageRunRefusal {
        TaxTriageRunRefusal(message: message, exitCode: dependencyCode)
    }

    /// T8. An `--input` folder that holds mates, which the folder route would run as two half samples.
    /// `read1` and `read2` name one such pair as the folder holds them.
    package static func folderHoldsPairedReads(folder: String, read1: String, read2: String) -> TaxTriageRunRefusal {
        .input("The folder \(folder) holds paired reads, such as \(read1) and \(read2). Use --samplesheet to pair them.")
    }

    /// 2.10 T6. `--input2` beside several `--input`, whose R1 it cannot name.
    package static let input2WithSeveralInputs = TaxTriageRunRefusal.input(
        "--input2 pairs with one --input. Give the pairs of several samples in a --samplesheet."
    )

    /// 2.10 T6. The samples of one pooled launch record different platforms. The launch runs one
    /// configuration, whose platform its record and its analysis entry name, so the run is refused
    /// rather than run with a platform some of its samples did not come from.
    package static func mixedPlatforms(_ samples: [TaxTriageSample]) -> TaxTriageRunRefusal {
        let platforms = listing(samples.map { "\($0.sampleId) as \($0.platform.displayName)" }, joinedBy: "and")
        return .input(
            "These samples record different platforms, \(platforms), and one Nextflow run takes one platform. Add --batch to run each sample alone on its own platform."
        )
    }

    /// 2.10 T4. `--negative-control` names a sample the run does not have.
    package static func unknownNegativeControls(_ names: [String], sampleIDs: [String]) -> TaxTriageRunRefusal {
        .input(
            "This run has no sample named \(listing(names, joinedBy: "or")), which --negative-control names. Its samples are \(listing(sampleIDs, joinedBy: "and"))."
        )
    }

    /// `items` as a sentence lists them, `a`, `a and b` or `a, b and c`.
    static func listing(_ items: [String], joinedBy word: String) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(word) \(last)"
    }
}

/// What ``TaxTriageAnalysisRunTool`` runs with besides its request, so a test can stand in for the
/// pipeline, the folder expansion, the materializer and the lock.
package struct TaxTriageRunServices: Sendable {
    /// Makes the pipeline a unit runs, as `TaxTriageCommand.RunSubcommand.makePipeline` does today.
    package var makePipeline: @Sendable () -> TaxTriagePipeline
    /// Expands `--input` as typed into files and bundles. The command line expands a folder.
    package var expandInputs: @Sendable (_ arguments: [String], _ recursive: Bool) throws -> [URL]
    /// Materializes a virtual bundle before TaxTriage reads it.
    package var materializer: any CLISequenceInputMaterializing & Sendable
    /// The lock the plan reads TaxTriage's pin from. A test passes a lock with no TaxTriage pin to see
    /// the run refused (N4), and the pipeline's run takes the same lock in milestone 2.
    package var lock: ManagedToolLock
    /// Whether a cancel was asked for, such as a SIGTERM the command's `SIGTERMCancellation` counted,
    /// the same source the executor's `cancelRequested` reads (S2).
    package var cancelRequested: @Sendable () -> Bool
    /// What a person reading text sees beside the events. The command line fills it in for text
    /// and leaves it empty for `--format json`.
    package var presentation: TaxTriageRunPresentation

    package init(
        makePipeline: @escaping @Sendable () -> TaxTriagePipeline = { TaxTriagePipeline.shared },
        expandInputs: @escaping @Sendable ([String], Bool) throws -> [URL] = TaxTriageRunServices.literalInputs,
        materializer: any CLISequenceInputMaterializing & Sendable = FASTQCLIMaterializer(runner: NativeToolRunner.shared),
        lock: ManagedToolLock = .bundled,
        cancelRequested: @escaping @Sendable () -> Bool = { false },
        presentation: TaxTriageRunPresentation = .none
    ) {
        self.makePipeline = makePipeline
        self.expandInputs = expandInputs
        self.materializer = materializer
        self.lock = lock
        self.cancelRequested = cancelRequested
        self.presentation = presentation
    }

    /// Each argument as one input, without expanding a folder.
    package static let literalInputs: @Sendable ([String], Bool) throws -> [URL] = { arguments, _ in
        arguments.map { URL(fileURLWithPath: $0) }
    }
}

/// What a TaxTriage run shows a person reading text, beside its events, as `Kraken2RunPresentation`
/// does for Kraken2.
package struct TaxTriageRunPresentation: Sendable {
    /// Called once per unit with the configuration its launch is about to run, its inputs resolved.
    package var configured: (@Sendable (TaxTriageConfig) -> Void)?

    package init(configured: (@Sendable (TaxTriageConfig) -> Void)? = nil) {
        self.configured = configured
    }

    package static let none = TaxTriageRunPresentation()
}
