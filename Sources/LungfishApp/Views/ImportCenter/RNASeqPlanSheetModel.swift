// RNASeqPlanSheetModel.swift - The values, words and argv of the two RNA-seq plan sheets (Phase 5.4 lane EX-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The bulk plan sheet runs `lungfish-cli rnaseq quant --write-plan` and the 10x plan sheet runs `lungfish-cli rnaseq
// solo-plan`. Each sheet holds the values the command takes, shows the command's own defaults, builds the argv in one
// place and hands it to its launcher, which registers the Operations row with that argv and runs it. The sheet computes no
// number and writes no file. Its Check button runs the same argv with `--dry-run`, which makes every refusal of the command
// and writes no folder. A refusal comes back in the command's words and the sheet keeps its values.

import Foundation
import LungfishCore
import LungfishWorkflow
import Observation

/// Which of the two plan sheets a card opens.
enum RNASeqPlanKind: Sendable, Equatable {
    /// `lungfish-cli rnaseq quant --write-plan`, bulk counts on a Linux machine.
    case bulk
    /// `lungfish-cli rnaseq solo-plan`, 10x counts with STARsolo on a Linux machine.
    case tenX
}

/// What a plan sheet hands its launcher. `arguments` is the argv after `lungfish-cli` that runs, and the Operations row
/// records the command built from the same array.
struct RNASeqPlanRequest: Sendable, Equatable {
    let kind: RNASeqPlanKind
    let arguments: [String]
    let planFolder: URL
    let dryRun: Bool
}

/// How a plan run ended, in the words the sheet shows.
enum RNASeqPlanOutcome: Sendable, Equatable {
    /// The command wrote this plan folder.
    case written(URL)
    /// A `--dry-run` passed every check of the command and wrote nothing.
    case checked
    /// The command refused or failed, in its own words.
    case refused(String)
    /// The run was cancelled and no plan folder was written.
    case cancelled
}

/// The words of the two plan sheets and of the adopt card. The words of the 10x barcode list and of the presets are the
/// CLI's own (`SoloPlanBarcodes`, `SoloPlanPreset`), so a sheet and a plan folder say one thing.
enum RNASeqPlanWords {
    static let nothingRuns = "Nothing runs here and nothing is submitted. Copy the plan folder to the Linux machine and submit it there."
    static let checkLine = "Check runs every check that Write Plan runs, and writes no folder."
    static let stagedReadsHelp = "A tab-separated list of the reads already in the staging folder, with each read's absolute path, "
        + "size in bytes and SHA-256. Lungfish reads none of the reads."
    static let bulkSampleSheetHelp = "A comma-separated sheet with sample, r1 and r2 columns. Leave r2 empty for single-end reads."
    static let tenXSampleSheetHelp = "A comma-separated sheet with sample, r1 and r2 columns, one row a lane. The rows of one sample are one library."
    static let appFilesLine = "The executor, image and tool manifest of this app are used unless you choose others. A run you adopt as a "
        + "result takes the manifest.json of the executor you built, since the plan pins it."
    static let tenXSetHelp = "The id of a reference set whose STARsolo index an earlier Linux run built and left in the staging folder."
    static let tenXFilterHelp = "The 10x biotype list of the adopted STARsolo index to map on. Leave it out for an index with no 10x filter rule."
    static let adoptIntro = "Adopts the counts a Linux run returned, as one result in this project. The folder is checked in full before "
        + "anything is written, and a refused adopt writes nothing."
    static let adoptNameHelp = "The name of the result."
    static let adoptStorageRootHelp = "Optional. The storage root that holds the plan's reference set (default: the configured location)."

    /// The CLI's sentence after the plan of the introns preset (`RNASeqSoloPlanSubcommand+Write.swift`).
    static let introsAdopt = "import rnaseq --adopt reads Solo.out/Gene only, so it refuses the folder this plan returns. Read its "
        + "Solo.out/GeneFull_Ex50pAS files from the folder, or keep the exon matrix Solo.out/Gene with lungfish-cli import "
        + "rnaseq <result folder>/solo."

    /// What a preset counts, in the words of its plan record. The introns preset approximates Cell Ranger 7's counting and
    /// is never called a match for it (prog:158, CR7-4).
    static func presetWords(_ preset: SoloPlanPreset) -> String {
        var words = "\(preset.name). It counts \(preset.counts)."
        if preset == .threePrimeV3Introns { words += " " + introsAdopt }
        return words
    }

    /// Where the plan gets the barcode list. A list the person gives is said to be supplied by the person and is checked by
    /// SHA-256, and a list from the image is named with its source.
    static func barcodeListWords(preset: SoloPlanPreset, supplied: URL?) -> String {
        let list = preset.barcodeList
        guard let supplied else {
            return "Barcode list: \(list.name) for \(list.chemistry), SHA-256 \(list.sha256). Source: the \(SoloPlanBarcodes.fromImage)."
        }
        return "Barcode list: \(supplied.lastPathComponent), supplied by you. The command checks it by SHA-256 against the whole "
            + "list of this preset, \(list.name), and records it as a \(SoloPlanBarcodes.supplied). It never copies the file, so "
            + "place it in the staging folder where the plan folder's README says."
    }
}

@MainActor
@Observable
final class RNASeqPlanSheetModel {
    enum ReadsSource: Equatable, Sendable {
        /// FASTQ bundles of a project, one sample each.
        case bundles
        /// Reads already in the staging folder, named by a staged-reads list and a sample sheet.
        case staged
    }

    enum Phase: Equatable {
        case editing
        case running
    }

    /// The chains `rnaseq quant --write-plan --chain` takes, in the order of its help. A test holds them equal to the CLI's.
    static let chains = [
        "salmon", "star-salmon", "star-salmon-errormodel", "star-2.7.11b-genecounts", "star-2.7.3a-genecounts",
        "star-2.7.11b-featurecounts",
    ]
    /// The `--tenx-filter` values of `rnaseq solo-plan`.
    static let tenXFilters = ["mkgtf-3.0.0", "gencode-2020-A"]
    /// The CPUs a job asks for when `--request-cpus` is left out, which the help of both commands states.
    static let defaultRequestCPUs = SoloPlan.defaultThreads
    static let defaultExpectedCells = SoloPlan.defaultExpectedCells

    let kind: RNASeqPlanKind
    /// Whether this app holds an executor, an image and a tool manifest of its own, the defaults of the command.
    let appHasFiles: Bool

    var setID = ""
    var reads: ReadsSource = .bundles
    var bundles: [URL] = []
    var stagedReads: URL?
    var sampleSheet: URL?
    /// The chain of a bulk plan. Nil leaves `--chain` out, which is the command's `salmon`.
    var chain: String?
    var preset: SoloPlanPreset = .threePrimeV3
    var barcodeList: URL?
    var tenXFilter: String?
    var stagingFolder = ""
    var executorManifest: URL?
    var image: URL?
    var imageToolManifest: URL?
    var requestMemoryMiB = ""
    var requestCPUs = String(RNASeqPlanSheetModel.defaultRequestCPUs)
    var requestDiskGiB = ""
    var jobRequirements = ""
    var expectedCells = String(RNASeqPlanSheetModel.defaultExpectedCells)
    var planFolder: URL?

    private(set) var phase: Phase = .editing
    /// The command's words after a refusal.
    private(set) var failure: String?
    /// A line that is not a refusal: a passed check or a cancel.
    private(set) var note: String?
    private(set) var operationID: UUID?

    /// Registers the row and starts the run. Returns the row's id, or nil when the row was refused and nothing started.
    /// The second argument is called once, on the main actor, when the run ends.
    @ObservationIgnored
    var start: (@MainActor (RNASeqPlanRequest, @escaping @MainActor (RNASeqPlanOutcome) -> Void) -> UUID?)?
    @ObservationIgnored
    var cancelRun: (@MainActor (UUID) -> Void)?
    @ObservationIgnored
    var onWritten: (@MainActor (URL) -> Void)?
    @ObservationIgnored
    var onDismiss: (@MainActor () -> Void)?

    init(
        kind: RNASeqPlanKind,
        appHasFiles: Bool = FASTQPlanSheetModel.executorManifest(inFolder: FASTQPlanSheetModel.bundledExecutorFolder()) != nil
            && FASTQPlanSheetModel.bundledImageFiles() != nil
    ) {
        self.kind = kind
        self.appHasFiles = appHasFiles
        self.reads = kind == .tenX ? .staged : .bundles
    }

    // MARK: - What the sheet says

    var title: String {
        kind == .bulk ? "Plan RNA-seq Counts for a Linux Machine" : "Plan 10x Counts for a Linux Machine"
    }

    var introduction: String {
        let what = kind == .bulk
            ? "Writes the files that count bulk RNA-seq reads on a Linux machine or cluster, one plan a sample."
            : "Writes the files that count 10x libraries with STARsolo on a Linux machine or cluster, one plan a library."
        return what + " " + RNASeqPlanWords.nothingRuns
    }

    /// The words under the 10x preset: what it counts, from the plan's own record line.
    var presetWords: String { RNASeqPlanWords.presetWords(preset) }
    /// The words under the 10x barcode list: its source.
    var barcodeListWords: String { RNASeqPlanWords.barcodeListWords(preset: preset, supplied: barcodeList) }

    // MARK: - The command

    private static func wholeNumber(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 >= 1 ? $0 : nil }
    }

    private static func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Why Check and Write Plan are not available yet, in words, or nil when the sheet's values make a command.
    var missingChoice: String? {
        if Self.blank(setID) { return "Give the id of the reference set." }
        switch (kind, reads) {
        case (.bulk, .bundles):
            if bundles.isEmpty { return "Choose the FASTQ bundles to plan." }
        case (_, _):
            if stagedReads == nil { return "Choose the list of the staged reads." }
            if sampleSheet == nil { return "Choose the sample sheet." }
        }
        if !FASTQPlanSheetModel.isStagingFolder(stagingFolder) {
            return "Give the absolute path of the staging folder on the Linux machine."
        }
        if !appHasFiles && (executorManifest == nil || image == nil || imageToolManifest == nil) {
            return executorManifest == nil
                ? FASTQPlanSheetModel.noExecutorSentence
                : "This build of Lungfish has no tool image, so choose the image.json and the tool manifest it pins."
        }
        if Self.wholeNumber(requestCPUs) == nil { return "CPUs each job asks for is a whole number from 1." }
        if !Self.blank(requestMemoryMiB), Self.wholeNumber(requestMemoryMiB) == nil { return "Memory is a whole number of MiB from 1, or empty." }
        if !Self.blank(requestDiskGiB), Self.wholeNumber(requestDiskGiB) == nil { return "Disk is a whole number of GiB from 1, or empty." }
        if kind == .tenX, Self.wholeNumber(expectedCells) == nil { return "Expected cells is a whole number from 1." }
        if planFolder == nil { return "Name the new plan folder." }
        return nil
    }

    var canRun: Bool { phase == .editing && missingChoice == nil }

    /// The options the two commands share, in the order of their help: the executor files, the request values and the
    /// job requirements. A file left unchosen is left out, so the command's own default, the app's, applies.
    private func commonArguments() -> [String] {
        var arguments: [String] = []
        for (flag, file) in [("--executor-manifest", executorManifest), ("--image", image), ("--image-tool-manifest", imageToolManifest)] {
            if let file { arguments += [flag, file.standardizedFileURL.path] }
        }
        return arguments
    }

    private func requestArguments() -> [String] {
        var arguments: [String] = []
        if !Self.blank(requestMemoryMiB) { arguments += ["--request-memory-mib", requestMemoryMiB.trimmingCharacters(in: .whitespacesAndNewlines)] }
        arguments += ["--request-cpus", requestCPUs.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !Self.blank(requestDiskGiB) { arguments += ["--request-disk-gib", requestDiskGiB.trimmingCharacters(in: .whitespacesAndNewlines)] }
        if !Self.blank(jobRequirements) { arguments += ["--job-requirements", jobRequirements.trimmingCharacters(in: .whitespacesAndNewlines)] }
        return arguments
    }

    /// The argv after `lungfish-cli` of the sheet's values, `rnaseq quant --write-plan` or `rnaseq solo-plan`, ending in
    /// `--format json` so the command prints its summary on one line. `dryRun` adds `--dry-run`, the Check button.
    func arguments(planFolder folder: URL, dryRun: Bool) -> [String] {
        var arguments: [String]
        let staging = stagingFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .bulk:
            arguments = ["rnaseq", "quant"]
            if reads == .bundles { arguments += bundles.map { $0.standardizedFileURL.path } }
            arguments += ["--set", setID.trimmingCharacters(in: .whitespacesAndNewlines), "--write-plan", folder.standardizedFileURL.path]
            if let chain { arguments += ["--chain", chain] }
            if reads == .staged, let stagedReads, let sampleSheet {
                arguments += ["--staged-reads", stagedReads.standardizedFileURL.path, "--samplesheet", sampleSheet.standardizedFileURL.path]
            }
            arguments += ["--staging-folder", staging]
            arguments += commonArguments() + requestArguments()
        case .tenX:
            arguments = ["rnaseq", "solo-plan", "--set", setID.trimmingCharacters(in: .whitespacesAndNewlines), "--preset", preset.rawValue]
            if let barcodeList { arguments += ["--barcode-list", barcodeList.standardizedFileURL.path] }
            if let tenXFilter { arguments += ["--tenx-filter", tenXFilter] }
            if let stagedReads, let sampleSheet {
                arguments += ["--staged-reads", stagedReads.standardizedFileURL.path, "--samplesheet", sampleSheet.standardizedFileURL.path]
            }
            arguments += ["--output", folder.standardizedFileURL.path, "--staging-folder", staging]
            arguments += commonArguments()
            arguments += ["--expected-cells", expectedCells.trimmingCharacters(in: .whitespacesAndNewlines)]
            arguments += requestArguments()
        }
        if dryRun { arguments.append("--dry-run") }
        return arguments + ["--format", "json"]
    }

    /// The request the sheet's values make, or nil while a value is missing.
    func request(dryRun: Bool) -> RNASeqPlanRequest? {
        guard missingChoice == nil, let planFolder else { return nil }
        return RNASeqPlanRequest(
            kind: kind, arguments: arguments(planFolder: planFolder, dryRun: dryRun), planFolder: planFolder, dryRun: dryRun
        )
    }

    // MARK: - Actions

    func checkClicked() { run(dryRun: true) }

    func writeClicked() { run(dryRun: false) }

    private func run(dryRun: Bool) {
        guard canRun, let request = request(dryRun: dryRun), let start else { return }
        failure = nil
        note = nil
        phase = .running
        operationID = start(request) { [weak self] outcome in self?.finish(outcome) }
        if operationID == nil {
            // `begin` refused, and the Operations panel shows the refused row. Nothing was launched.
            phase = .editing
            failure = "The Operations panel shows why the plan could not start."
        }
    }

    /// Cancel stops a run in progress, and the command writes no folder. With no run it closes the sheet.
    func cancelClicked() {
        if phase == .running, let operationID {
            cancelRun?(operationID)
        } else {
            onDismiss?()
        }
    }

    func finish(_ outcome: RNASeqPlanOutcome) {
        operationID = nil
        phase = .editing
        switch outcome {
        case .written(let folder):
            failure = nil
            note = nil
            onWritten?(folder)
            onDismiss?()
        case .checked:
            failure = nil
            note = "Checked. Every check passed and no folder was written. Choose Write Plan to write the plan."
        case .refused(let words):
            failure = words
            note = nil
        case .cancelled:
            failure = nil
            note = "The plan was cancelled. No plan folder was written."
        }
    }
}
