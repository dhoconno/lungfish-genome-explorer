// RNASeqCellMapImportRun.swift - The words and the end of the Import Embedding row (Phase 5.5 lane CM-IMPORT-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The row runs `lungfish-cli rnaseq cell-map import` on `RNASeqLeafRoute` (`RNASeqWorkflowRuns.swift`). This file holds what the
// app says about it. A refusal comes from the CLI in words that name a flag, which a person using the pane cannot type, so the
// alert says which control of the pane to turn on and keeps the CLI's counts and cause. The CLI's own words stay in the row's
// detail and log, since the runner settles the row with them. When the leaf exits 0 the app reads the new result off the main
// actor with `RNASeqResultBundle.load(from:)` before it opens the result, and a read that fails shows its words and opens nothing.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

/// The words of the Import Embedding pane and row. The control names are the pane's own, and `RNASeqCellMapImportRefusal` in
/// LungfishWorkflow is the CLI's side of each pair, which `RNASeqPseudobulkDialogTests` pins.
enum RNASeqCellMapImportWords {
    static let title = "Import Embedding"
    static let dropControl = "Drop “-1” from each barcode"
    static let addControl = "Add “-1” to each barcode"
    static let skipControl = "Leave out barcodes the result does not hold"
    static let otherCountsControl = "The embedding was computed on other counts"

    /// One common cause of barcodes that do not match, as the plan's words give it (UX U-A5).
    static let notHeldCause = "One common cause is a merged Seurat object, which puts the sample name before each barcode."

    /// The stage lines of the row, in the order the leaf works. The row's detail starts at the first.
    static func stageLines(coordinates: [URL], clusters: [URL], result: URL, output: URL) -> [String] {
        (coordinates + clusters).map { "Reading \($0.lastPathComponent)" }
            + ["Checking barcodes against \(result.lastPathComponent)", "Writing \(output.lastPathComponent)"]
    }

    /// The CLI's refusal with the sentence that names a flag rewritten to name the pane's control. The counts and the cause the
    /// CLI states stay. `nil` for words that name no flag of the import, which the alert then shows as they are.
    static func paneWords(forCLIWords message: String) -> String? {
        let rewrites: [(String, String)] = [
            ("To drop -1 from every given barcode, run again with --barcode-suffix drop.",
             "Turn on \(dropControl), then import again."),
            ("To add -1 to every given barcode, run again with --barcode-suffix add.",
             "Turn on \(addControl), then import again."),
            ("Barcodes match as given unless --barcode-suffix changed them,",
             "Barcodes match as given unless the Barcodes setting of the pane changed them,"),
            ("To leave them out and import the rest, run again with --skip-barcodes-not-held, and the record counts them.",
             "Turn on \(skipControl), then import again. The record counts them. \(notHeldCause)"),
            ("To import it all the same, run again with --other-counts, and the record and the view then say computed on other counts.",
             "Turn on \(otherCountsControl), then import again. The record and the view then say computed on other counts."),
        ]
        var words = message
        var changed = false
        for (cli, pane) in rewrites where words.contains(cli) {
            words = words.replacingOccurrences(of: cli, with: pane)
            changed = true
        }
        return changed ? words : nil
    }

    /// What the alert says when the leaf wrote the cell map and the app could not read it back.
    static func loadFailedWords(name: String, reason: String) -> String {
        "The cell map \(name) was written, but LGE could not read it back, so it was not opened. \(reason)"
    }
}

/// How an import ended, after the row settled and the app did the rest.
enum RNASeqCellMapImportEnd: Equatable, Sendable {
    /// The leaf exited 0, the new result loaded, and the app opened it.
    case opened(URL)
    /// The leaf exited 0 and the new result loaded, but no window showed it.
    case notOpened(URL)
    /// The leaf exited 0 and the new result did not load. The words say why and nothing opened.
    case loadFailed(String)
    /// The leaf refused or failed. The words are the alert's, naming the pane's control when the CLI's did name a flag.
    case refused(String)
    /// The person cancelled. The row reads Cancelled, no alert shows and the leaf left no folder.
    case cancelled
}

/// What a launched import hands back, so a caller can wait for the whole run, the open and the alert included.
struct RNASeqCellMapImportLaunch {
    let operationID: UUID
    let task: Task<RNASeqCellMapImportEnd, Never>
}

@MainActor
enum RNASeqCellMapImportRun {
    /// Reads the folder the way the viewer's surface does, and writes nothing.
    static let loadResult: @Sendable (URL) throws -> Void = { url in _ = try RNASeqResultBundle.load(from: url) }

    /// Opens the finished row's result in the sidebar and the viewer, as the Results button of the Operations panel does.
    static let openResult: @MainActor (UUID) async -> Bool = { operationID in
        guard let item = OperationCenter.shared.items.first(where: { $0.id == operationID }) else { return false }
        return await OperationResultNavigation.navigate(to: item)
    }

    /// The alert, as a sheet of the key window when there is one.
    static let showAlert: @MainActor (String, String) -> Void = { title, message in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Ends one import from how the runner ended it. The runner has settled the row already, so a refusal's row keeps the
    /// CLI's words and a cancelled row reads Cancelled. Only a leaf that exited 0 reaches the load, and only a load that
    /// succeeds reaches the open.
    static func finish(
        _ outcome: CLIViewerExportRunner.Outcome,
        operationID: UUID,
        load: @escaping @Sendable (URL) throws -> Void,
        open: @MainActor (UUID) async -> Bool,
        report: @MainActor (String, String) -> Void
    ) async -> RNASeqCellMapImportEnd {
        switch outcome {
        case .cancelled:
            return .cancelled
        case .failed(let failure):
            let words = RNASeqCellMapImportWords.paneWords(forCLIWords: failure.message) ?? failure.message
            report(RNASeqCellMapImportWords.title, words)
            return .refused(words)
        case .completed(let url):
            do {
                try await Task.detached(priority: .userInitiated) { try load(url) }.value
            } catch {
                let words = RNASeqCellMapImportWords.loadFailedWords(
                    name: url.lastPathComponent, reason: error.localizedDescription)
                OperationCenter.shared.log(id: operationID, level: .error, message: words)
                report(RNASeqCellMapImportWords.title, words)
                return .loadFailed(words)
            }
            return await open(operationID) ? .opened(url) : .notOpened(url)
        }
    }
}
