// ProvenanceLoadingWordsTests.swift - The Provenance tab says only that it is loading until the record has been read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

/// Walk finding WO-8 (UX-WALK row WO-8). Switching the Source picker cleared the old record and showed the empty
/// summary, so for about two seconds the tab said "No provenance required", "Loading provenance…" and a Workflow of
/// "No Provenance" together, and two of the three were false. While the record is read the tab now shows its title, its
/// buttons, the Source picker and "Loading provenance…", and nothing that speaks for a record it has not read.
@MainActor
final class ProvenanceLoadingWordsTests: XCTestCase {
    private let loadingWords = "Loading provenance\u{2026}"
    private let emptySummaryWords = ["No provenance required", "No Provenance"]
    private let recordGroups = [
        "provenance-run-summary", "provenance-step-list", "provenance-files",
        "provenance-options", "provenance-runtime", "provenance-raw-json",
    ]

    // MARK: - Harness

    private func texts(_ model: ProvenanceInspectorViewModel) throws -> [String] {
        try ProvenanceSection(viewModel: model).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    /// Fails for each word of an empty summary that the tab shows, whether as a Label of the status line or as a Text.
    private func assertNoEmptySummaryWords(
        _ model: ProvenanceInspectorViewModel, _ context: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let inspected = try ProvenanceSection(viewModel: model).inspect()
        let shown = try texts(model)
        for words in emptySummaryWords {
            XCTAssertFalse(shown.contains(words), "\(context) shows \"\(words)\". \(shown)", file: file, line: line)
            XCTAssertThrowsError(
                try inspected.find(ViewType.Label.self, where: { (try? $0.find(text: words)) != nil }),
                "\(context) shows \"\(words)\" as its status line.", file: file, line: line
            )
        }
        for identifier in recordGroups {
            XCTAssertThrowsError(
                try inspected.find(viewWithAccessibilityIdentifier: identifier),
                "\(context) shows the \(identifier) group.", file: file, line: line
            )
        }
    }

    private func makeProject() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "provenance-loading-words")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Loading Words.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func place(_ source: URL, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: url, options: .atomic)
    }

    // MARK: - The loading state

    func testWhileTheRecordLoadsTheTabShowsOnlyTheLoadingWords() throws {
        let model = ProvenanceInspectorViewModel()
        model.isLoading = true

        let shown = try texts(model)
        XCTAssertEqual(shown.filter { $0 == loadingWords }.count, 1, "\(shown)")
        try assertNoEmptySummaryWords(model, "The loading tab")
        XCTAssertEqual(shown.first, "Provenance", "The tab keeps its title above the loading words. \(shown)")
    }

    func testTheTabShowsItsGroupsAgainOnceNothingIsLoading() throws {
        let model = ProvenanceInspectorViewModel()
        model.isLoading = false

        let inspected = try ProvenanceSection(viewModel: model).inspect()
        XCTAssertFalse(try texts(model).contains(loadingWords))
        for identifier in recordGroups {
            XCTAssertNoThrow(try inspected.find(viewWithAccessibilityIdentifier: identifier), identifier)
        }
    }

    // MARK: - Switching the Source picker

    /// Two real records in one project, the adopted run and a cancelled trim, with the picker offering both. The switch
    /// reads the second off the main actor, and the main actor does not run again before the first check below.
    func testSwitchingTheSourceShowsOnlyTheLoadingWordsUntilTheRecordIsRead() async throws {
        let project = try makeProject()
        let adoptedFolder = project.appendingPathComponent("Imports/SRR24403534.lungfishfastq", isDirectory: true)
        let trimFolder = project.appendingPathComponent("Analyses/fastq-trim-cancelled", isDirectory: true)
        try place(
            ProvenanceDisplayFixtures.testsDirectory.appendingPathComponent(
                "Fixtures/provenance-adopted-run/Imports/SRR24403534.lungfishfastq/.lungfish-provenance.json"),
            at: adoptedFolder.appendingPathComponent(".lungfish-provenance.json")
        )
        try place(
            ProvenanceDisplayFixtures.directory.appendingPathComponent("Analyses/fastq-trim-cancelled/.lungfish-provenance.json"),
            at: trimFolder.appendingPathComponent(".lungfish-provenance.json")
        )
        let adopted = ProvenanceInspectableItem(
            url: adoptedFolder, sidebarType: .fastqBundle, contentMode: .genomics, displayName: "SRR24403534"
        )
        let trim = ProvenanceInspectableItem(
            url: trimFolder, sidebarType: .analysisResult, contentMode: .genomics, displayName: "fastq-trim-cancelled"
        )

        let model = ProvenanceInspectorViewModel()
        model.load(item: adopted)
        let first = await waitUntil(budget: .lookup) { !model.isLoading }
        XCTAssertTrue(first, "The first record did not load.")
        model.restoreSources([
            ProvenanceSource(id: "adopted", name: "Adopted run", item: adopted),
            ProvenanceSource(id: "trim", name: "Cancelled trim", item: trim),
        ])
        XCTAssertEqual(model.selectedSourceID, "adopted")
        XCTAssertTrue(try texts(model).contains("lungfish import fastq"), "The adopted run's record shows before the switch.")

        model.selectSource(id: "trim")

        XCTAssertTrue(model.isLoading, "The switch reads the second record off the main actor.")
        let shown = try texts(model)
        XCTAssertEqual(shown.filter { $0 == loadingWords }.count, 1, "\(shown)")
        try assertNoEmptySummaryWords(model, "The tab during the switch")
        XCTAssertFalse(shown.contains("lungfish import fastq"), "The first record's words are gone. \(shown)")
        XCTAssertNoThrow(
            try ProvenanceSection(viewModel: model).inspect().find(viewWithAccessibilityIdentifier: "provenance-source-picker"),
            "The Source picker stays so the person can switch again."
        )

        let second = await waitUntil(budget: .lookup) { !model.isLoading }
        XCTAssertTrue(second, "The second record did not load.")
        let loaded = try texts(model)
        XCTAssertFalse(loaded.contains(loadingWords), "\(loaded)")
        XCTAssertTrue(loaded.contains("lungfish fastq trim"), "The second record's Workflow shows once it is read. \(loaded)")
        XCTAssertEqual(model.selectedSourceID, "trim")
    }
}
