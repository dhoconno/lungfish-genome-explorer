// GenotypeManualDefinitionsExportPinTests.swift - Pins of the manual haplotype definitions export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishGenotypeUI

/// Pins of the manual haplotype definitions export (Phase 2.12 lane 12.35 M1, QA 1, ARCH question Q-A3).
///
/// The export writes the current assignments of the open store's sidecar, pretty printed with sorted keys. Since lane
/// 12.35 M2 the leaf `genotype export-manual-definitions` writes them with the Workflow builder, and its record is
/// pinned by `GenotypeManualDefinitionsExportCLIGUIParityReplayTests.assertPredictedRecordChanges`, which also pins
/// the record the deleted in-app writer wrote.
@MainActor
final class GenotypeManualDefinitionsExportPinTests: GenotypeResultViewportTestCase {
    /// The bytes the export button writes for scenario B, the current assignments of the store's sidecar, built by
    /// `GenotypeManualDefinitionsExport`. The raw sidecar holds five assignments, and the index keeps the ones it
    /// resolves.
    func testThePayloadIsTheCurrentAssignmentsPrettyPrintedWithSortedKeys() throws {
        let scenario = try makeGenotypeOnlyManualScenario()
        defer { scenario.cleanup() }
        let store = try GenotypeAnnotationStore(bundleURL: scenario.bundleURL, author: GenotypeCharacterizationFixture.author)

        let raw = store.sidecar.manualHaplotypeAssignments
        let current = GenotypeManualDefinitionsExport.currentAssignments(raw)
        let payload = try GenotypeManualDefinitionsExport.payload(currentAssignments: current)

        XCTAssertEqual(raw.count, 5)
        XCTAssertEqual(current.count, 5, "the index keeps every assignment of scenario B")
        XCTAssertEqual(
            GenotypeCharacterizationCanonicalizer.sha256Hex(payload),
            "0ec3211c0efef9500f2d53e7e625db173c5adf28b2b8aa6e50dcec896a40b675",
            "the digest the characterization record names for the output"
        )
    }

    /// Q-A3. A store over a bundle it cannot write keeps an edit in memory and never saves it, so at export time the
    /// open store holds an assignment the saved sidecar lacks (`GenotypeAnnotationStore+Publication.swift`, the
    /// read-only guard of `persist`). The export reads the store, so a leaf that read only the saved sidecar would
    /// write different rows, and the assignments must reach the leaf in the selection file (ARCH ruling 1.3).
    func testAReadOnlyStoreHoldsAnAssignmentTheSavedSidecarLacks() async throws {
        let scenario = try makeGenotypeOnlyManualScenario()
        defer { scenario.cleanup() }
        let sidecarURL = scenario.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let savedBefore = try Data(contentsOf: sidecarURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scenario.bundleURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scenario.bundleURL.path)
        }
        let store = try GenotypeAnnotationStore(bundleURL: scenario.bundleURL, author: GenotypeCharacterizationFixture.author)
        XCTAssertTrue(store.isReadOnly)
        let rawBefore = store.sidecar.manualHaplotypeAssignments

        try await store.addManualHaplotypeAssignments([
            ManualHaplotypeAssignment(
                sample: "animal-3", locus: "MHC-A", slot: .h2, label: "Unsaved", colorTokenIndex: 2,
                diagnosticAlleles: ["A*001"], notes: ""
            ),
        ], author: GenotypeCharacterizationFixture.author)

        XCTAssertEqual(store.sidecar.manualHaplotypeAssignments.count, rawBefore.count + 1)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), savedBefore, "the saved sidecar never gets the edit")
        let saved = try GenotypeAnnotationSidecar.decode(savedBefore)
        XCTAssertEqual(saved.manualHaplotypeAssignments.count, rawBefore.count)
    }
}
