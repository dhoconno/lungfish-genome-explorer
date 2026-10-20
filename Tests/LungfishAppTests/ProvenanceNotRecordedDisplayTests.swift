// ProvenanceNotRecordedDisplayTests.swift - The Provenance tab reads Not recorded for facts a record never held
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishTestSupport

/// The Inspector once showed the reading Mac's executable, process ID, architecture, dependency
/// set and app version for a record that held none, as if the record had held them. A fact a
/// record never held now reads Not recorded (plan decision S4). Whether such a record reads
/// Older record format, and whether it counts as complete, is left to lane P7b.
@MainActor
final class ProvenanceNotRecordedDisplayTests: XCTestCase {
    func testABareRunShowsNotRecordedForTheRuntimeFactsItNeverHeld() async throws {
        let rows = try await runtimeRows(of: try await loadModel("s3-write-sidecar-bare-run"))
        XCTAssertEqual(rows["Executable"], "Not recorded")
        XCTAssertEqual(rows["Process ID"], "Not recorded")
        XCTAssertEqual(rows["Architecture"], "Not recorded")
        XCTAssertEqual(rows["Dependency Set"], "Not recorded", "readers once filled it from the reading Mac, like Executable")
        XCTAssertEqual(rows["App Version"], "Lungfish 2026.10.10 (dev)")
        XCTAssertEqual(rows["OS"], "macOS 26.7.1 (arm64)")
    }

    func testAnEnvelopeWithoutAnAppOrWorkflowVersionShowsNotRecorded() async throws {
        let model = try await loadModel("s2-analysis-kraken2-fixture")
        XCTAssertEqual(model.summary.workflowVersion, "Not recorded")
        let rows = try await runtimeRows(of: model)
        XCTAssertEqual(rows["App Version"], "Not recorded")
        XCTAssertEqual(rows["Architecture"], "Not recorded")
        XCTAssertEqual(rows["Executable"], "python3")
        XCTAssertEqual(rows["Process ID"], "38076")
    }

    // MARK: Helpers

    private func loadModel(_ caseID: String) async throws -> ProvenanceInspectorViewModel {
        let materialized = try ProvenanceCompatCorpus.materialize(caseID)
        addTeardownBlock { materialized.cleanup() }
        let selection = try XCTUnwrap(materialized.selection)
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: selection,
            sidebarType: .analysisResult,
            contentMode: .genomics,
            displayName: selection.lastPathComponent
        ))
        let finished = await waitUntil(timeout: .seconds(60)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertEqual(model.resolvedSidecarURL?.standardizedFileURL, materialized.sidecar.standardizedFileURL)
        return model
    }

    private func runtimeRows(of model: ProvenanceInspectorViewModel) async throws -> [String: String] {
        Dictionary(model.runtimeRows.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
