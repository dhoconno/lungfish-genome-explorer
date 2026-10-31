// ClassifierResultActions.swift - The shared actions of the classifier result viewers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane 3E (program task 3e, review R14). Each classifier viewer repeated its bar wiring, its BLAST results
// pane with its open state, the reasons of its greyed buttons and its hand-off to the extraction dialog, so a fix
// reached one copy at a time. This component holds them once, in the words of UX-3E-LABELS (approved as O86): the
// action bar, the BLAST Results button (U-3E-1), the BLAST results pane, the reason a greyed button gives, and the
// extraction request that the App answers with its dialog. TaxTriage adopts it first. Each later viewer migration
// adopts it for its own classifier.

import AppKit
import LungfishCore
import LungfishWorkflow

/// What a classifier viewer asks to extract. The App wires ``ClassifierResultActions/onExtractionRequested`` to its
/// extraction dialog, so a viewer names no App type (layering rule 1).
public struct ClassifierExtractionRequest: Sendable, Equatable {
    /// The classifier the dialog is scoped to.
    public var tool: ClassifierTool
    /// The classifier's result file or folder.
    public var resultPath: URL
    /// One selector for each sample the selection reaches.
    public var selectors: [ClassifierRowSelector]
    /// The bundle name the save panel offers, short and tool-prefixed.
    public var suggestedName: String
    /// Table rows the selection stands for, when there are fewer selectors than rows. Nil counts the selectors.
    public var selectedRowCount: Int?
    /// A line the dialog shows under its selection label, such as the rows the extraction leaves out.
    public var leftOutNotice: String?

    public init(
        tool: ClassifierTool,
        resultPath: URL,
        selectors: [ClassifierRowSelector],
        suggestedName: String,
        selectedRowCount: Int? = nil,
        leftOutNotice: String? = nil
    ) {
        self.tool = tool
        self.resultPath = resultPath
        self.selectors = selectors
        self.suggestedName = suggestedName
        self.selectedRowCount = selectedRowCount
        self.leftOutNotice = leftOutNotice
    }
}

/// The words of the shared classifier actions, as UX-3E-LABELS rules them. A reason is a sentence that leads the
/// tooltip and the VoiceOver hint of the greyed button it belongs to. The numbers are the ruling's rows.
public enum ClassifierActionWords {
    /// R1, BLAST with no row picked.
    public static let selectRowToVerify = "Select a row to verify it with BLAST."
    /// R2, BLAST with more than one row picked.
    public static let selectOneRowToVerify = "Select one row to verify it with BLAST."
    /// R3, BLAST while a TaxTriage batch shows several samples.
    public static let chooseOneSampleToVerify = "Choose one sample to verify its rows with BLAST."
    /// R4, Extract with no row picked.
    public static let selectRowsToExtract = "Select one or more rows to extract their reads."
    /// R5, Extract while the result's database is still opening.
    public static let extractWaitsForTheResult = "Extract Reads is ready once this result finishes opening."
    /// R5, BLAST while the result's database is still opening.
    public static let verifyWaitsForTheResult = "Verify with BLAST is ready once this result finishes opening."
    /// R6, Extract when the result's database is missing.
    public static let extractNeedsTheDatabase =
        "Extract Reads needs this result's database, which is missing. Import the result again to extract reads."
    /// R6, BLAST when the result's database is missing.
    public static let verifyNeedsTheDatabase =
        "Verify with BLAST needs this result's database, which is missing. Import the result again to use BLAST."
    /// R7, the fallback when a copied Kraken2 result cannot reach its reads and the copy receipt gives no reason.
    public static let sourceReadsMissing =
        "LGE can't find the reads this result came from, so they can't be extracted or checked with BLAST."
    /// R8, a CZ-ID import, for both buttons and the two greyed menu items.
    public static let czIdHasNoReadIDs =
        "CZ-ID results don't include read IDs, so reads can't be extracted or checked with BLAST. "
        + "To work with reads, classify the FASTQ in LGE."
    /// R10, in the BLAST results pane, when the alignment file is missing.
    public static let alignmentFileMissing =
        "This result's alignment file (BAM) is missing, so no reads were sent to BLAST. "
        + "Run the classifier again or import the full result folder."
    /// R11, in the BLAST results pane, when the row names no reference.
    public static let noReferenceAccession =
        "This row has no reference accession, so LGE can't find its reads for BLAST. Choose a row that names a reference."
    /// R15, the title of the alert when extraction fails.
    public static let extractionFailedTitle = "The reads could not be extracted."
    /// R15, the next step after the error's own words.
    public static let extractionFailedNextStep = "Choose Extract Reads to try again."

    /// The BLAST Results button's title and VoiceOver label.
    public static let blastResultsTitle = "BLAST Results"
    /// The BLAST Results button's tooltip.
    public static let blastResultsTooltip = "Show or hide the BLAST results below the table."
    /// The BLAST Results button's VoiceOver hint.
    public static let blastResultsHint = "Shows or hides the BLAST results below the table."

    /// The rows picked, in the bar.
    public static func rowsSelected(_ count: Int) -> String {
        count == 1 ? "1 row selected" : "\(count) rows selected"
    }

    /// R16, in the extraction dialog when the read count could not be estimated.
    public static func readCountFailed(_ errorWords: String) -> String {
        "LGE could not count the reads for this selection. \(sentence(errorWords)) Cancel, then choose Extract Reads again."
    }

    /// R15, the text of the alert when extraction fails.
    public static func extractionFailedText(_ errorWords: String) -> String {
        "\(sentence(errorWords)) \(extractionFailedNextStep)"
    }

    /// `words` trimmed, with a period added when they end without a mark.
    static func sentence(_ words: String) -> String {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}

/// The action bar, the BLAST Results button and the BLAST results pane of one classifier viewer.
///
/// The viewer lays out ``bar`` and ``blastDrawer``, gives the bar its own Export, provenance and custom buttons,
/// and animates the pane's space in ``onBlastDrawerOpenChanged``. The component keeps the pane's open state, the
/// words of the greyed buttons and the extraction hand-off.
@MainActor
public final class ClassifierResultActions: NSObject {

    /// The bar along the bottom of the viewer.
    public let bar: ClassifierActionBar
    /// Shows or hides the BLAST results below the table. It sits after Extract Reads in the bar.
    public let blastResultsButton: NSButton
    /// The BLAST results pane.
    public let blastDrawer: BlastResultsDrawerTab
    /// Whether the BLAST results pane is open.
    public private(set) var isBlastDrawerOpen = false
    /// The last BLAST result the pane showed, which Run Again repeats.
    public private(set) var lastBlastResult: BlastVerificationResult?

    /// The App opens its extraction dialog for the request.
    public var onExtractionRequested: (@MainActor (ClassifierExtractionRequest) -> Void)?
    /// The viewer opens or closes the pane's space.
    public var onBlastDrawerOpenChanged: (@MainActor (Bool) -> Void)?

    public override init() {
        bar = ClassifierActionBar()
        blastDrawer = BlastResultsDrawerTab()
        blastResultsButton = Self.makeBlastResultsButton()
        super.init()
        blastResultsButton.target = self
        blastResultsButton.action = #selector(blastResultsTapped(_:))
        bar.addCustomButton(blastResultsButton)
        showNoSelection(prompt: "")
    }

    // MARK: - Selection

    /// Nothing is picked. The bar shows the viewer's own prompt, and the greyed buttons give R1 and R4.
    public func showNoSelection(prompt: String) {
        bar.updateInfoText(prompt)
        bar.setBlastEnabled(false, reason: ClassifierActionWords.selectRowToVerify)
        bar.setExtractEnabled(false, reason: ClassifierActionWords.selectRowsToExtract)
    }

    /// `count` rows are picked, at least one. One row can be verified with BLAST, and more ask for one (R2).
    /// `info` replaces the count when the viewer has more to say about the row. `extractable` is false when the
    /// result has nothing to extract from, and `extractReason` then says why.
    public func showSelection(count: Int, info: String? = nil, extractable: Bool = true, extractReason: String? = nil) {
        bar.updateInfoText(info ?? ClassifierActionWords.rowsSelected(count))
        if count == 1 {
            bar.setBlastEnabled(true)
        } else {
            bar.setBlastEnabled(false, reason: ClassifierActionWords.selectOneRowToVerify)
        }
        bar.setExtractEnabled(extractable, reason: extractable ? nil : extractReason)
    }

    /// The viewer shows several samples at once, so BLAST asks for one sample (R3) and there are no rows to extract.
    public func showSeveralSamples(info: String) {
        bar.updateInfoText(info)
        bar.setBlastEnabled(false, reason: ClassifierActionWords.chooseOneSampleToVerify)
        bar.setExtractEnabled(false)
    }

    // MARK: - Extraction

    /// Hands an extraction to the App, which opens its dialog. A request with no selector asks for nothing.
    public func requestExtraction(_ request: ClassifierExtractionRequest) {
        guard !request.selectors.isEmpty else { return }
        onExtractionRequested?(request)
    }

    // MARK: - BLAST results

    /// Shows a BLAST result in the pane and opens it.
    public func showBlastResults(_ result: BlastVerificationResult, recordURL: URL?) {
        lastBlastResult = result
        blastDrawer.showResults(result, recordURL: recordURL)
        setBlastDrawerOpen(true)
    }

    /// Shows a BLAST run's progress in the pane and opens it.
    public func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        blastDrawer.showLoading(phase: phase, requestId: requestId)
        setBlastDrawerOpen(true)
    }

    /// Shows why a BLAST run could not start or failed in the pane and opens it.
    public func showBlastFailure(_ message: String) {
        blastDrawer.showFailure(message: message)
        setBlastDrawerOpen(true)
    }

    /// Opens the pane when it is closed and closes it when it is open, as the BLAST Results button does.
    public func toggleBlastResults() {
        setBlastDrawerOpen(!isBlastDrawerOpen)
    }

    /// Opens or closes the pane. The button's state follows.
    public func setBlastDrawerOpen(_ open: Bool) {
        blastResultsButton.state = open ? .on : .off
        guard open != isBlastDrawerOpen else { return }
        isBlastDrawerOpen = open
        onBlastDrawerOpenChanged?(open)
    }

    @objc private func blastResultsTapped(_ sender: NSButton) {
        toggleBlastResults()
    }

    private static func makeBlastResultsButton() -> NSButton {
        let button = NSButton(title: ClassifierActionWords.blastResultsTitle, target: nil, action: nil)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .accessoryBarAction
        // The title names the button, so VoiceOver reads it once.
        button.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.toolTip = ClassifierActionWords.blastResultsTooltip
        button.setAccessibilityLabel(ClassifierActionWords.blastResultsTitle)
        button.setAccessibilityHelp(ClassifierActionWords.blastResultsHint)
        button.setAccessibilityIdentifier("classifier-result-blast-results")
        return button
    }
}
