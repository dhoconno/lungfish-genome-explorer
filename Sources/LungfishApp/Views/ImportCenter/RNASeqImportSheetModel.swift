// RNASeqImportSheetModel.swift - The values of the Import Center's two sheets for `lungfish-cli import rnaseq`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.4 lane RS-GLUE. The bulk card and the single-cell card each ask for their inputs in an open panel and then
// open one of the two sheets. A sheet holds the values the command takes (`--name`, `--samples`, `--tx2gene`, `--unit`,
// `--genome`, `--reference-set` and a `--not-host-bam` for each sample), builds the argv in one place
// (`CLIImportRunner.buildRNASeqImportArguments`) and hands it to its launcher, which registers the Operations row with
// that argv and runs it on `CLIImportRunner`. The sheet computes no count. It keeps the CLI's own words when the command
// refuses, so a person can change a value and run again without choosing the inputs twice.

import Foundation
import LungfishCore
import LungfishWorkflow
import Observation

/// Which of the two cards opened the sheet.
enum RNASeqImportKind: Sendable, Equatable {
    /// salmon folders, one count table of genes by samples, or the tables nf-core/rnaseq wrote.
    case bulk
    /// Cell Ranger `outs/` folders or STARsolo run folders.
    case singleCell
}

/// What a sheet hands its launcher. `arguments` is the argv after `lungfish-cli` that runs, and the Operations row
/// records the command built from the same array.
struct RNASeqImportRequest: Sendable, Equatable {
    let arguments: [String]
    let name: String
    let projectURL: URL
}

/// How a run ended, in the words the sheet shows.
enum RNASeqImportOutcome: Sendable, Equatable {
    /// The command made this `.lungfishrnaseq` folder.
    case imported(URL)
    /// The command refused or failed, in its own words.
    case refused(String)
    /// The run was cancelled, and the command removed its stage.
    case cancelled
}

@MainActor
@Observable
final class RNASeqImportSheetModel {
    /// One unit of a count table. A table states none, so the sheet offers all four the command takes and has no default.
    struct UnitChoice: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
    }

    static let unitChoices: [UnitChoice] = [
        UnitChoice(id: "reads", title: "Reads"),
        UnitChoice(id: "pairs", title: "Read pairs"),
        UnitChoice(id: "umis", title: "UMIs"),
        UnitChoice(id: "estimated", title: "Estimated counts"),
    ]

    enum Phase: Equatable {
        case editing
        case running
    }

    let kind: RNASeqImportKind
    let inputs: [URL]
    let projectURL: URL

    var name: String
    var sampleSheet: URL?
    var tx2gene: URL?
    /// The raw value of the chosen unit, nil until a person chooses one.
    var unit: String?
    var genomesText = ""
    var referenceSet: URL?
    /// The BAM chosen for each single-cell input, by the input's position, so two folders of one name stay apart.
    var notHostBAMs: [Int: URL] = [:]

    private(set) var phase: Phase = .editing
    /// The CLI's words after a refusal, or the line that says a cancel imported nothing.
    private(set) var failure: String?
    /// What to do after a refusal, shown under the CLI's words. Nil for a cancel and for every other state.
    private(set) var hint: String?
    private(set) var operationID: UUID?

    /// Registers the row and starts the run. Returns the row's id, or nil when the row was refused and nothing started.
    /// The second argument is called once, on the main actor, when the run ends.
    @ObservationIgnored
    var start: (@MainActor (RNASeqImportRequest, @escaping @MainActor (RNASeqImportOutcome) -> Void) -> UUID?)?
    @ObservationIgnored
    var cancelRun: (@MainActor (UUID) -> Void)?
    @ObservationIgnored
    var onImported: (@MainActor (URL) -> Void)?
    @ObservationIgnored
    var onDismiss: (@MainActor () -> Void)?

    init(kind: RNASeqImportKind, inputs: [URL], projectURL: URL) {
        self.kind = kind
        self.inputs = inputs
        self.projectURL = projectURL
        self.name = Self.defaultName(kind: kind, inputs: inputs)
    }

    // MARK: - What the inputs are

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// One count table, which states no unit and takes no transcript-to-gene table.
    var isCountTable: Bool {
        kind == .bulk && inputs.count == 1 && !Self.isDirectory(inputs[0])
    }

    /// salmon quant folders, whose unit salmon states and whose genes come from the person's table, if one is given.
    var isSalmonFolders: Bool {
        kind == .bulk && !inputs.isEmpty && inputs.allSatisfy(Self.isDirectory)
    }

    /// The sample id the command gives a single-cell folder. `outs/` takes the name of the folder above it. A test
    /// holds this equal to `SingleCellFolderReader.read(folder:).sample`.
    nonisolated static func sampleID(ofSingleCellFolder folder: URL) -> String {
        let name = folder.lastPathComponent
        return name == "outs" ? folder.deletingLastPathComponent().lastPathComponent : name
    }

    var sampleIDs: [String] {
        kind == .singleCell ? inputs.map(Self.sampleID(ofSingleCellFolder:)) : []
    }

    /// The genome prefixes typed in the sheet, split at commas and spaces.
    var genomes: [String] {
        genomesText.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    /// One line that names the inputs, with the first four by name.
    var inputSummary: String {
        let names = inputs.map(\.lastPathComponent)
        let shown = names.prefix(4).joined(separator: ", ")
        let rest = names.count > 4 ? " and \(names.count - 4) more" : ""
        switch kind {
        case .singleCell: return "Cell Ranger or STARsolo folders: \(shown)\(rest)"
        case .bulk: return isCountTable ? "Count table: \(shown)" : "Folders: \(shown)\(rest)"
        }
    }

    nonisolated static func defaultName(kind: RNASeqImportKind, inputs: [URL]) -> String {
        guard let first = inputs.first else { return "RNA-seq counts" }
        if inputs.count == 1, !isDirectory(first) { return first.deletingPathExtension().lastPathComponent }
        let parents = Set(inputs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if kind == .bulk, parents.count == 1, let parent = inputs.first?.deletingLastPathComponent() {
            return parent.lastPathComponent
        }
        return kind == .singleCell ? "Single-cell counts" : "RNA-seq counts"
    }

    // MARK: - What the sheet says about the project

    /// The inputs that sit outside the project. The command records each as `<external>/<name>`, so the recorded
    /// command does not replay (BACKLOG RNASEQ-IMPORT-EXTERNAL-NO-REPLAY).
    var inputsOutsideProject: [URL] {
        let inside = projectURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return inputs.filter { !$0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(inside) }
    }

    var outsideProjectNote: String? {
        let outside = inputsOutsideProject
        guard !outside.isEmpty else { return nil }
        let names = outside.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
        let rest = outside.count > 3 ? " and \(outside.count - 3) more" : ""
        return "Outside this project: \(names)\(rest). The record names each as <external>/<name>, so its command does not replay. "
            + "Copy the input into the project first to keep a command that replays."
    }

    // MARK: - The command

    /// Why Import is not available yet, in words, or nil when the sheet's values make a command.
    var missingChoice: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the result a name." }
        if kind == .bulk, !isCountTable, !isSalmonFolders {
            return "Choose salmon folders, or one count table, and not both."
        }
        if isCountTable, unit == nil { return "A count table states no unit. Choose the unit its numbers are in." }
        if kind == .singleCell, referenceSet != nil {
            let ids = sampleIDs
            if let missing = ids.indices.first(where: { notHostBAMs[$0] == nil }) {
                return "Choose the sorted, indexed BAM of \(ids[missing]), or remove the reference set."
            }
        }
        return nil
    }

    var canImport: Bool { phase == .editing && missingChoice == nil }

    /// The request the sheet's values make, or nil while a value is missing.
    func request() -> RNASeqImportRequest? {
        guard missingChoice == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let countsNotHost = kind == .singleCell && referenceSet != nil
        let bams: [(sample: String, url: URL)] = countsNotHost
            ? sampleIDs.enumerated().compactMap { index, id in notHostBAMs[index].map { (sample: id, url: $0) } }
            : []
        let arguments = CLIImportRunner.buildRNASeqImportArguments(
            inputs: inputs,
            projectDirectory: projectURL,
            name: trimmed,
            samples: sampleSheet,
            tx2gene: isSalmonFolders ? tx2gene : nil,
            unit: isCountTable ? unit : nil,
            genomes: kind == .singleCell ? genomes : [],
            referenceSet: countsNotHost ? referenceSet : nil,
            notHostBAMs: bams
        )
        return RNASeqImportRequest(arguments: arguments, name: trimmed, projectURL: projectURL)
    }

    // MARK: - Actions

    func importClicked() {
        guard canImport, let request = request(), let start else { return }
        failure = nil
        phase = .running
        operationID = start(request) { [weak self] outcome in self?.finish(outcome) }
        if operationID == nil {
            // `begin` refused, and the Operations panel shows the refused row. Nothing was launched.
            phase = .editing
            failure = "The Operations panel shows why the import could not start."
        }
    }

    /// Cancel stops a run in progress. The command removes its stage, so the project is as it was. With no run it
    /// closes the sheet.
    func cancelClicked() {
        if phase == .running, let operationID {
            cancelRun?(operationID)
        } else {
            onDismiss?()
        }
    }

    func finish(_ outcome: RNASeqImportOutcome) {
        operationID = nil
        phase = .editing
        switch outcome {
        case .imported(let url):
            failure = nil
            onImported?(url)
            onDismiss?()
        case .refused(let words):
            failure = words
        case .cancelled:
            failure = "The import was cancelled. Nothing was imported."
        }
    }
}
