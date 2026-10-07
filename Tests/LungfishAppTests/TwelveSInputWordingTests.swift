// TwelveSInputWordingTests.swift - The app's 12S texts say what the workflow reads, as the CLI help does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
@testable import LungfishApp
@testable import LungfishCLI
import SwiftUI
import ViewInspector
import XCTest

/// 12S matching reads merged reads, unmerged pairs or both, and the app says
/// so in the words of `lungfish-cli fastq 12s-match --help`, in the Workflow
/// Library and in the 12S options of the Workflow Operations dialog. Both
/// used to say the workflow expects merged reads only (re-review 2 follow-up).
@MainActor
final class TwelveSInputWordingTests: XCTestCase {

    private static let inputs = "Inputs are FASTQ files or .lungfishfastq bundles of merged reads, unmerged pairs or both."
    private static let counting = "A merged read counts once, and so does an unmerged pair whose mates agree."

    /// The sentences the app uses are the CLI help's, so the two cannot drift.
    func testTheAppsSentencesAreTheHelpsSentences() {
        let help = FastqTwelveSMatchSubcommand.helpMessage(columns: 400)
        XCTAssertTrue(help.contains(Self.inputs), help)
        XCTAssertTrue(help.contains(Self.counting), help)
    }

    func testTheWorkflowLibrarySaysWhatTheWorkflowReads() {
        let subtitle = WorkflowLibraryCatalog.twelveSAmpliconMatchingItem.subtitle

        XCTAssertFalse(subtitle.contains("Match merged 12S"), subtitle)
        XCTAssertTrue(subtitle.contains("merged reads, unmerged pairs or both"), subtitle)
        XCTAssertTrue(subtitle.contains(Self.counting), subtitle)
    }

    func testTheTwelveSOptionsSayWhatTheWorkflowReads() throws {
        let suiteName = "TwelveSInputWordingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enablement = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablement.setWorkflow(WorkflowLibraryCatalog.twelveSAmpliconMatchingItem, enabled: true)
        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: enablement,
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        )
        let twelveS = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveS.id)
        state.advancedOptionsExpanded = true

        let texts = try WorkflowOperationsDialog(
            state: state,
            onRun: { _ in },
            onCreateTwelveSReferenceBundle: { _ in },
            onOpenPreviousRun: {},
            onCancel: {}
        ).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertTrue(texts.contains("\(Self.inputs) \(Self.counting)"), "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("expects merged FASTQ inputs") }, "\(texts)")
    }
}
