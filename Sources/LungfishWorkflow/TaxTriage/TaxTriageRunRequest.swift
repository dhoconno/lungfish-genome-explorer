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
/// so the plan expands a folder, reads a samplesheet and pairs `--input2` itself, before any folder
/// exists. Every other choice of the command travels in ``settings``.
package struct TaxTriageRunRequest: Sendable {
    /// `--input` as typed, a FASTQ file, a `.lungfishfastq` bundle or a folder of them. Nil with
    /// `--samplesheet`.
    package var input: String?
    /// `--input2` as typed, the R2 file of the pair whose R1 is `--input`.
    package var input2: String?
    /// `--recursive`, which also takes the reads in the subfolders of an `--input` folder.
    package var recursive: Bool
    /// `--sample`, the name of the sample `--input` names. The inputs of a folder take it as a prefix.
    package var sampleID: String?
    /// `--samplesheet` as typed.
    package var samplesheet: String?
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

    package init(
        input: String? = nil,
        input2: String? = nil,
        recursive: Bool = false,
        sampleID: String? = nil,
        samplesheet: String? = nil,
        revision: String? = nil,
        extraArguments: String = "",
        settings: TaxTriageConfig
    ) {
        self.input = input
        self.input2 = input2
        self.recursive = recursive
        self.sampleID = sampleID
        self.samplesheet = samplesheet
        self.revision = revision
        self.extraArguments = extraArguments
        self.settings = settings
    }
}

/// Why a TaxTriage plan refused a request before any folder exists, with the code the command exits
/// with. The codes equal `CLIExitCode` in LungfishCLI, as ``Kraken2RunRefusal``'s do.
package struct TaxTriageRunRefusal: Error, LocalizedError, AnalysisRunExitCoding, Equatable, Sendable {
    /// `CLIExitCode.inputError`.
    package static let inputErrorCode: Int32 = 3
    /// `CLIExitCode.dependency`.
    package static let dependencyCode: Int32 = 126

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

    /// N4. The lock has no usable pin for the workflow, so nothing runs and no fallback revision takes
    /// the pin's place. The words and the code are those of `NextflowDescriptorRefusal.noPinnedVersion(of:)`,
    /// which takes over this refusal once the plan reads the pin through the descriptor (A2 M2).
    package static func noPinnedVersion(of workflowName: String) -> TaxTriageRunRefusal {
        .dependency("LGE's tool lock has no pinned version of \(workflowName), so LGE will not run it.")
    }

    /// T8. An `--input` folder that holds mates, which the folder route would run as two half samples.
    /// `read1` and `read2` name one such pair as the folder holds them.
    package static func folderHoldsPairedReads(folder: String, read1: String, read2: String) -> TaxTriageRunRefusal {
        .input("The folder \(folder) holds paired reads, such as \(read1) and \(read2). Use --samplesheet to pair them.")
    }

    /// The refusal of every unit and of the finalize while the lane's first milestone plans TaxTriage on
    /// the executor without running it. Milestone 2 deletes it with the stubs that throw it.
    package static let notRunnableYet = TaxTriageRunRefusal(
        message: "This build plans a TaxTriage run on the analysis run executor but cannot run it yet.",
        exitCode: AnalysisRunExitCode.workflowError
    )
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

    package init(
        makePipeline: @escaping @Sendable () -> TaxTriagePipeline = { TaxTriagePipeline.shared },
        expandInputs: @escaping @Sendable ([String], Bool) throws -> [URL] = TaxTriageRunServices.literalInputs,
        materializer: any CLISequenceInputMaterializing & Sendable = FASTQCLIMaterializer(runner: NativeToolRunner.shared),
        lock: ManagedToolLock = .bundled,
        cancelRequested: @escaping @Sendable () -> Bool = { false }
    ) {
        self.makePipeline = makePipeline
        self.expandInputs = expandInputs
        self.materializer = materializer
        self.lock = lock
        self.cancelRequested = cancelRequested
    }

    /// Each argument as one input, without expanding a folder.
    package static let literalInputs: @Sendable ([String], Bool) throws -> [URL] = { arguments, _ in
        arguments.map { URL(fileURLWithPath: $0) }
    }
}
