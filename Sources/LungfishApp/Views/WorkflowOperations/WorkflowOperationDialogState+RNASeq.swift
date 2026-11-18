// WorkflowOperationDialogState+RNASeq.swift - The export and pseudobulk rows of the Workflow Operations dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow
import Observation

/// The export row's settings, held beside the dialog state so the state file carries one property. The cutoff and the fold-change
/// bar are text, so the cutoff field shows the CLI's own 0.05 and an empty bar means none.
@MainActor
@Observable
final class RNASeqExportDialogModel {
    var resultURLs: [URL] = []
    var sampleSheetURL: URL?
    /// Design terms, separated by commas. The last one is the tested factor.
    var designText = ""
    /// `FACTOR:NUMERATOR:DENOMINATOR`, one contrast a line or separated by commas.
    var contrastsText = ""
    var cutoffText = String(RNASeqExportDefaults.padjCutoff)
    var lfcBarText = ""
    var batchText = ""
    var batchCorrection: RNASeqExportRunRequest.BatchCorrection = .none

    /// The entries of a list field, trimmed and in order, split on lines and commas.
    static func entries(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A number as typed, or `nil` for empty text, words and a value that is not finite.
    static func number(from text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        return value
    }

    var design: [String] { Self.entries(of: designText) }
    var contrasts: [String] { Self.entries(of: contrastsText) }
    var cutoff: Double? { Self.number(from: cutoffText) }
    var lfcBar: Double? { Self.number(from: lfcBarText) }
    /// An empty bar is valid (none). Text that is not a number is not, and neither is a number below 0, which the CLI refuses.
    var lfcBarIsValid: Bool {
        lfcBarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (lfcBar.map { $0 >= 0 } ?? false)
    }
}

/// The pseudobulk row's settings, held beside the dialog state for the same reason.
@MainActor
@Observable
final class RNASeqPseudobulkDialogModel {
    var resultURL: URL?
    var labelsURL: URL?
}

extension WorkflowOperationDialogState {
    /// The text `isRunEnabled` waits for. `readinessText` ends with it for every tool that is ready.
    static let rnaSeqReadyText = "Ready to run."

    /// The folder of a pseudobulk result is the name with the extension the CLI requires, added once.
    static func pseudobulkFolderName(for name: String) -> String {
        let suffix = ".lungfishrnaseq"
        return name.lowercased().hasSuffix(suffix) ? name : name + suffix
    }

    var selectedToolIsRNASeq: Bool {
        switch selectedTool?.kind {
        case .rnaSeqExport, .rnaSeqPseudobulk: return true
        default: return false
        }
    }

    private var rnaSeqTrimmedOutputName: String {
        outputName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The header line of the dialog for the two rows, which take results and not FASTQ bundles. `nil` for any other tool.
    var rnaSeqDatasetLabel: String? {
        switch selectedTool?.kind {
        case .rnaSeqExport:
            let urls = rnaSeqExport.resultURLs
            if urls.isEmpty { return "No RNA-seq results selected" }
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) RNA-seq results selected"
        case .rnaSeqPseudobulk:
            return rnaSeqPseudobulk.resultURL?.lastPathComponent ?? "No RNA-seq result selected"
        default:
            return nil
        }
    }

    /// The words that say why Run is off for the two rows, `Ready to run.` when it is on, and `nil` for any other tool. The design,
    /// the animals and the batch stay the CLI's to refuse, so each of those refusals reaches the Operations row in the CLI's own
    /// words. The three argument checks of `RNASeqExportSubcommand.validate()` are mirrored here (the range of the cutoff, the sign
    /// of the fold-change bar and the shape of a contrast), because the CLI answers them in terminal text, a usage line on a
    /// one-line row. `testTheReadinessAgreesWithTheCLIsArgumentCheck` holds the two together.
    var rnaSeqReadinessText: String? {
        switch selectedTool?.kind {
        case .rnaSeqExport:
            if rnaSeqExport.resultURLs.isEmpty { return "Select one or more RNA-seq results." }
            if outputDirectoryURL == nil { return "Choose where the export folder goes." }
            if rnaSeqTrimmedOutputName.isEmpty { return "Enter a name for the export folder." }
            guard let cutoff = rnaSeqExport.cutoff, cutoff > 0, cutoff <= 1 else {
                return "Enter the cutoff as a number above 0 and at most 1, such as 0.05."
            }
            if !rnaSeqExport.lfcBarIsValid { return "Enter the fold-change bar as 0 or more, such as 1, or leave it empty for none." }
            if let bad = rnaSeqExport.contrasts.first(where: {
                $0.split(separator: ":", omittingEmptySubsequences: false).filter { !$0.isEmpty }.count != 3
            }) {
                return "Write the contrast \(bad) as FACTOR:NUMERATOR:DENOMINATOR, such as group:TB:HIV."
            }
            return Self.rnaSeqReadyText
        case .rnaSeqPseudobulk:
            if rnaSeqPseudobulk.resultURL == nil { return "Select a single-cell RNA-seq result." }
            if rnaSeqPseudobulk.labelsURL == nil { return "Choose a labels table." }
            if outputDirectoryURL == nil { return "Choose where the pseudobulk result goes." }
            if rnaSeqTrimmedOutputName.isEmpty { return "Enter a name for the pseudobulk result." }
            return Self.rnaSeqReadyText
        default:
            return nil
        }
    }

    /// The export request of the pane. The folder is `<output directory>/<name>`.
    func makeRNASeqExportRequest() throws -> RNASeqExportRunRequest {
        guard rnaSeqReadinessText == Self.rnaSeqReadyText,
              let outputDirectoryURL,
              let cutoff = rnaSeqExport.cutoff else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        let batch = rnaSeqExport.batchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return RNASeqExportRunRequest(
            resultURLs: rnaSeqExport.resultURLs,
            outputURL: outputDirectoryURL.appendingPathComponent(rnaSeqTrimmedOutputName, isDirectory: true),
            sampleSheetURL: rnaSeqExport.sampleSheetURL,
            design: rnaSeqExport.design,
            contrasts: rnaSeqExport.contrasts,
            padjCutoff: cutoff,
            lfcBar: rnaSeqExport.lfcBar,
            batch: batch.isEmpty ? nil : batch,
            batchCorrection: rnaSeqExport.batchCorrection)
    }

    /// The pseudobulk request of the pane. The folder is `<output directory>/<name>.lungfishrnaseq`.
    func makeRNASeqPseudobulkRequest() throws -> RNASeqPseudobulkRunRequest {
        guard rnaSeqReadinessText == Self.rnaSeqReadyText,
              let outputDirectoryURL,
              let resultURL = rnaSeqPseudobulk.resultURL,
              let labelsURL = rnaSeqPseudobulk.labelsURL else {
            throw WorkflowOperationError.incompleteConfiguration(readinessText)
        }
        return RNASeqPseudobulkRunRequest(
            resultURL: resultURL,
            labelsURL: labelsURL,
            outputURL: outputDirectoryURL.appendingPathComponent(
                Self.pseudobulkFolderName(for: rnaSeqTrimmedOutputName), isDirectory: true))
    }

    /// The two rows, from their Workflow Library items. A `.core` item is always enabled, so both are available in a fresh install.
    static func rnaSeqTools(enablementStore: WorkflowLibraryEnablementStore) -> [WorkflowOperationTool] {
        let rows: [(id: String, kind: WorkflowOperationToolKind)] = [
            (WorkflowLibraryCatalog.rnaSeqExportID, .rnaSeqExport),
            (WorkflowLibraryCatalog.rnaSeqPseudobulkID, .rnaSeqPseudobulk),
        ]
        return rows.compactMap { row in
            guard let item = WorkflowLibraryCatalog.item(id: row.id) else { return nil }
            return WorkflowOperationTool(
                id: row.id,
                title: item.title,
                subtitle: item.subtitle,
                kind: row.kind,
                availability: enablementStore.isWorkflowEnabled(item) ? .available : .disabled(reason: "Enable in Library"))
        }
    }
}
