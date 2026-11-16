// RNASeqSoloPlanSubcommand.swift - `lungfish-cli rnaseq solo-plan`, the STARsolo plan of 10x libraries whose reads are
// staged on a Linux machine (Phase 5.3 lane SOLO-PLAN M3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishPortable
import LungfishWorkflow

/// Writes the submit folder of one STARsolo plan a library, as `rnaseq quant --write-plan` writes one a sample. It starts
/// no process and opens no connection, so a person copies the files and submits.
struct RNASeqSoloPlanSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "solo-plan",
        abstract: "Write a plan folder that counts 10x libraries with STARsolo on a Linux machine",
        discussion: """
            Each library gets one plan that runs STAR 2.7.11b in STARsolo mode on its staged reads, each lane's read 2 and \
            then each lane's read 1, on the STAR index of the set that an earlier Linux run built and left in the staging \
            folder. Plan that index with lungfish-cli rnaseq index-plan, with --tenx-filter for a 10x biotype list, run it, \
            and record it with lungfish-cli rnaseq index-adopt. The plan names no GTF, since STARsolo reads its genes \
            through the index, and it states the 10x filter rule, its list, the GTF's SHA-256 and the genes left out, read \
            from the index record.

            The barcode list is the preset's whole 10x list, checked by SHA-256. With no --barcode-list the plan reads the \
            list in the tool image. A list you give is checked here and never copied, so place it in the staging folder \
            where the plan folder's README says. Adopt what a run returns with lungfish-cli import rnaseq <folder> --adopt.
            """
    )

    /// The words of a cancelled run.
    static let cancelledMessage = "The STARsolo plan was cancelled. No plan folder was written."

    @Option(name: .customLong("set"), help: "The id of a reference set under the storage root, or the path of a set folder")
    var setReference: String

    @Option(name: .customLong("preset"), help: ArgumentHelp(
        "The library's chemistry and the matrix counted: tenx-3p-v3, tenx-5p-v2 or tenx-3p-v3-introns",
        discussion: "tenx-3p-v3 counts exons of 10x 3' v3 with the 3M-february-2018 list, tenx-5p-v2 counts exons of 10x 5' v2 "
            + "read 2 with the 737K-august-2016 list, and tenx-3p-v3-introns counts exons and introns of 10x 3' v3 "
            + "(STARsolo GeneFull_Ex50pAS) with the 3M list.", valueName: "preset"))
    var preset: String

    @Option(name: .customLong("barcode-list"), help: ArgumentHelp(
        "The preset's whole 10x barcode list as a file on this Mac, checked by SHA-256 (default: the list in the tool image)",
        valueName: "file"))
    var barcodeList: String?

    @Option(name: .customLong("tenx-filter"), help: "The 10x biotype list of the adopted STARsolo index to map on, mkgtf-3.0.0 or gencode-2020-A. Leave it out for an index with no 10x filter rule")
    var tenxFilter: String?

    @Option(name: .customLong("staged-reads"), help: ArgumentHelp(
        "A tab-separated list of the reads in the staging folder, with each read's absolute path, size in bytes and SHA-256",
        discussion: "The list's first line names the columns file, bytes and sha256, separated by tabs. Lungfish reads none of the reads.",
        valueName: "file"))
    var stagedReads: String

    @Option(name: .customLong("samplesheet"), help: ArgumentHelp(
        "A comma-separated sample sheet with sample, r1 and r2 columns, one row a lane, whose rows of one sample are one library",
        valueName: "file"))
    var samplesheet: String

    @Option(name: .customLong("output"), help: "The new plan folder to write. It must not exist")
    var outputPath: String

    @Option(name: .customLong("staging-folder"), help: "The absolute path of the folder on the Linux machine that holds the image, the executor, the index and the reads")
    var stagingFolder: String

    @Option(name: .customLong("executor-manifest"), help: "The manifest.json beside the Linux lungfish-executor (default: the app's)")
    var executorManifest: String?

    @Option(name: .customLong("image"), help: "The image.json of the container image (default: the app's)")
    var image: String?

    @Option(name: .customLong("image-tool-manifest"), help: "The image's tool manifest, the file image.json pins (default: the app's)")
    var imageToolManifest: String?

    @Option(name: .customLong("expected-cells"), help: "The expected cells of STARsolo's EmptyDrops_CR cell filter (default: 3000)")
    var expectedCells: Int?

    @Option(name: .customLong("request-memory-mib"), help: "Memory each job asks for, in MiB")
    var requestMemoryMiB: Int64?

    @Option(name: .customLong("request-cpus"), help: "CPUs each job asks for, and STAR's threads (default: 8)")
    var requestCPUs: Int?

    @Option(name: .customLong("request-disk-gib"), help: "Disk each job asks for, in GiB")
    var requestDiskGiB: Int?

    @Option(name: .customLong("job-requirements"), help: "The machines the jobs may run on, as one HTCondor requirements expression")
    var jobRequirements: String?

    @Flag(name: .customLong("dry-run"), help: "Make every refusal of the run and write no folder")
    var dryRun: Bool = false

    @Option(name: .customLong("storage-root"), help: "Managed storage root that holds the set and the index records (default: the configured location)")
    var storageRoot: String?

    @OptionGroup var globalOptions: GlobalOptions

    var outputURL: URL { URL(fileURLWithPath: outputPath).standardizedFileURL }

    /// The command the record names, in one fixed order with absolute paths. Parsing it gives equal options.
    func canonicalArgv() -> [String] {
        func absolute(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
        var argv = [CLICommandIdentity.executableName, "rnaseq", "solo-plan", "--set",
                    setReference.contains("/") ? absolute(setReference) : setReference, "--preset", preset]
        if let tenxFilter { argv += ["--tenx-filter", tenxFilter] }
        argv += ["--staged-reads", absolute(stagedReads), "--samplesheet", absolute(samplesheet), "--output", outputURL.path,
                 "--staging-folder", stagingFolder]
        for (flag, value) in [("--barcode-list", barcodeList), ("--executor-manifest", executorManifest), ("--image", image),
                              ("--image-tool-manifest", imageToolManifest), ("--storage-root", storageRoot)] {
            if let value { argv += [flag, absolute(value)] }
        }
        if let expectedCells { argv += ["--expected-cells", "\(expectedCells)"] }
        if let requestMemoryMiB { argv += ["--request-memory-mib", "\(requestMemoryMiB)"] }
        if let requestCPUs { argv += ["--request-cpus", "\(requestCPUs)"] }
        if let requestDiskGiB { argv += ["--request-disk-gib", "\(requestDiskGiB)"] }
        if let jobRequirements { argv += ["--job-requirements", jobRequirements] }
        if dryRun { argv.append("--dry-run") }
        return argv
    }

    func run() async throws {
        let command = self
        let outcome = await runCancellingOnSIGTERM { () async throws -> RNASeqIndexPlanSubcommand.PlanSummary in
            try await command.writePlan()
        }
        switch outcome {
        case .success(let summary):
            if globalOptions.outputFormat == .json {
                print(summary.json)
            } else if !globalOptions.quiet {
                summary.lines.forEach { print($0) }
            }
        case .failure(let error):
            let isCancel = error is CancellationError
            let words = isCancel ? Self.cancelledMessage : CLIFailureWords.describe(error)
            FileHandle.standardError.write(Data((isCancel ? "\(words)\n" : "Error: \(words)\n").utf8))
            if isCancel { throw CLIExitCode.cancelled.exitCode }
            throw (error is CocoaError ? CLIExitCode.workflowError : CLIExitCode.inputError).exitCode
        }
    }
}
