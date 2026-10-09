// GenotypeExportCharacterizationTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Byte-level characterization of the genotype export coordinator before its
// extraction from GenotypeResultViewController (Phase 2.3, REVIEW.md R6).
// The frozen Excel capture of six scenarios is compared with committed files
// under Tests/Fixtures/golden/genotype-gui. The panel flow, the manual
// definitions provenance, the scoped export request, the panel's window, the
// one roster the matrix and the workbook count prevalence over and the exact
// threshold values of the filter context are pinned inline. Every test pins
// current behaviour, including behaviour the design experts flagged as
// wrong, so a later fix shows up as a reviewed diff.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
import UniformTypeIdentifiers
import XCTest
@testable import LungfishGenotypeUI

/// Records what the export flow hands its seams, from any isolation.
@MainActor
private final class ExportFlowRecorder {
    var events: [String] = []
    var panelRecords: [String] = []
    var runnerCaptures: [Data] = []

    func record(_ event: GenotypeExcelExportEvent, maskedBy canonicalizer: GenotypeCharacterizationCanonicalizer) {
        switch event {
        case .started:
            events.append("started")
        case .succeeded(let url):
            events.append("succeeded " + canonicalizer.maskRoot(in: url.path))
        case .failed(let message):
            events.append("failed " + message)
        }
    }
}

private struct SettleFailure: LocalizedError {
    var errorDescription: String? { "The Inspector state could not be settled." }
}

@MainActor
final class GenotypeExportCharacterizationTests: GenotypeResultViewportTestCase {
    // MARK: E1 to E3'', committed expected files

    func testHaplotypedMiSeqExportCapturesMatchCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "haplotyped-miseq") {
            let scenario = try makeHaplotypedMiSeqScenario()
            defer { scenario.cleanup() }
            return try scenario.canonicalExportFiles(prefix: "haplotyped-miseq")
        }
    }

    func testGenotypeOnlyManualExportCapturesMatchCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "genotype-only-manual") {
            let scenario = try makeGenotypeOnlyManualScenario()
            defer { scenario.cleanup() }
            return try scenario.canonicalExportFiles(prefix: "genotype-only-manual")
        }
    }

    func testLiteralStatusMiSeqExportCapturesMatchCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "literal-status-miseq") {
            let scenario = try makeLiteralStatusMiSeqScenario()
            defer { scenario.cleanup() }
            return try scenario.canonicalExportFiles(prefix: "literal-status-miseq")
        }
    }

    /// Scenario D pins the three capture inputs no other scenario moves: the
    /// global percent stays 0.0 while the filter context records 7.5, the
    /// prevalence control reaches the capture, and the sidecar locus order
    /// reaches the authority.
    func testThresholdedMiSeqExportCapturesMatchCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "haplotyped-miseq-thresholds") {
            let scenario = try makeThresholdedMiSeqScenario()
            defer { scenario.cleanup() }
            return try scenario.canonicalExportFiles(prefix: "haplotyped-miseq-thresholds")
        }
    }

    /// Scenario E pins decision D1 (finding T2). The matrix and the Excel
    /// builder take their sample roster from one function, so the catalog-only
    /// AnimalF is a matrix column and both count prevalence 40 over six
    /// animals. 04_Mafa_B_082_01, seen in two of them, leaves the matrix and
    /// the Filtered sheet alike. Its Samples and Unique Reads columns are
    /// hidden here and visible in the next scenario.
    func testCatalogPrevalenceMiSeqExportCapturesMatchCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "haplotyped-miseq-catalog-prevalence") {
            let scenario = try makeCatalogPrevalenceMiSeqScenario()
            defer { scenario.cleanup() }
            return try scenario.canonicalExportFiles(prefix: "haplotyped-miseq-catalog-prevalence")
        }
    }

    /// Decision D1 (finding T2), the matrix side. Before the fix the matrix
    /// counted prevalence over the five animals of the result and kept
    /// 04_Mafa_B_082_01 at 2 of 5, exactly 40 percent, while the Excel builder
    /// counted the catalog-only AnimalF too and dropped the row at 2 of 6. The
    /// matrix now takes its columns from the roster the builder counts over,
    /// so AnimalF is a column and the row is hidden in the window and in the
    /// Filtered sheet alike.
    func testCatalogPrevalenceHidesTheSameRowInTheMatrixAndTheFilteredSheet() throws {
        let scenario = try makeCatalogPrevalenceMiSeqScenario()
        defer { scenario.cleanup() }
        let matrix = scenario.controller.testingComparisonMatrix
        let roster = matrix.exportSnapshot(
            bundleURL: scenario.bundleURL, analysisName: "Example", lens: "genotype", unfiltered: true
        ).sampleNames
        XCTAssertEqual(roster, ["AnimalC", "AnimalA", "AnimalB", "AnimalD", "AnimalE", "AnimalF"],
                       "the catalog-only animal is a matrix column, after the moved AnimalC and the result's order")
        let visible = matrix.testingVisibleGenotypes
        XCTAssertFalse(visible.contains("04_Mafa_B_082_01"), "2 of 6 animals is under 40 percent")
        XCTAssertTrue(visible.contains("03_Mafa_B_075_01"))

        let snapshot = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(scenario.withAquaDrawingAppearance { try scenario.controller.captureExcelExportSnapshot() }.excelSnapshotData))
        XCTAssertEqual(snapshot.allMatrix.samples.map(\.name), roster, "the All sheet lists the same roster")
        let filtered = snapshot.filteredMatrix.rows.map(\.target.genotype)
        XCTAssertFalse(filtered.contains("04_Mafa_B_082_01"))
        XCTAssertTrue(filtered.contains("03_Mafa_B_075_01"))
    }

    /// Decision D1 (finding T2), the other consequence. With the Samples and
    /// Unique Reads columns visible, the GUI's default, the Excel builder used
    /// to recompute both over its six-animal roster, find the GUI's five-animal
    /// values for 04_Mafa_B_082_01 different and refuse the whole capture with
    /// one failed event and no save panel. Both sides now count over one
    /// roster, so the capture succeeds with the count columns visible, the
    /// panel flow opens one save panel and publishes no failed event, and the
    /// capture is pinned as its own expected file.
    func testCatalogPrevalenceWithCountColumnsExportCapturesMatchCharacterization() throws {
        try GenotypeCharacterizationExpectedStore.verify(prefix: "haplotyped-miseq-catalog-prevalence-counts") {
            let scenario = try makeCatalogPrevalenceWithCountColumnsMiSeqScenario()
            defer { scenario.cleanup() }
            return try scenario.canonicalExportFiles(prefix: "haplotyped-miseq-catalog-prevalence-counts")
        }

        let scenario = try makeCatalogPrevalenceWithCountColumnsMiSeqScenario()
        defer { scenario.cleanup() }
        let controller = scenario.controller
        let snapshot = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(scenario.withAquaDrawingAppearance { try controller.captureExcelExportSnapshot() }.excelSnapshotData))
        XCTAssertEqual(snapshot.allMatrix.samples.map(\.name), ["AnimalC", "AnimalA", "AnimalB", "AnimalD", "AnimalE", "AnimalF"])
        XCTAssertFalse(snapshot.filteredMatrix.rows.map(\.target.genotype).contains("04_Mafa_B_082_01"))
        XCTAssertFalse(controller.testingComparisonMatrix.testingVisibleGenotypes.contains("04_Mafa_B_082_01"))
        // The count columns reach the Filtered sheet with the window's values.
        let row = try XCTUnwrap(snapshot.filteredMatrix.rows.first { $0.target.genotype == "03_Mafa_B_075_01" })
        let values = Dictionary(uniqueKeysWithValues: (row.columnValues ?? []).map { ($0.key, $0) })
        XCTAssertEqual(values["standard.samples"]?.integer, 3, "AnimalA, AnimalC and the hidden AnimalD")
        XCTAssertEqual(values["standard.totalUniqueReads"]?.integer, 89)

        var panels = 0
        var events: [String] = []
        controller.excelSavePanelPresenter = { _, _, _ in panels += 1 }
        controller.onExcelExportEvent = { event in
            switch event {
            case .started: events.append("started")
            case .succeeded(let url): events.append("succeeded " + url.lastPathComponent)
            case .failed(let message): events.append("failed " + message)
            }
        }
        try scenario.withAquaDrawingAppearance {
            controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        }
        XCTAssertEqual(panels, 1, "the capture is no longer refused, so the save panel opens")
        XCTAssertEqual(events, [], "no event is published before the save completes")
    }

    /// Finding SF4. The filter context the matrix attaches to the capture
    /// used to print its three percent thresholds with one decimal, so a
    /// minimum percent of 0.125 appeared as 0.1 beside the Export Metadata
    /// row that prints the applied value exactly. Both now record the value
    /// the way the metadata rows do, so provenance states one number.
    func testExportFilterContextRecordsThresholdValuesExactly() throws {
        let scenario = try makeHaplotypedMiSeqScenario()
        defer { scenario.cleanup() }
        let controller = scenario.controller
        var state = controller.testingDisplayState
        state.hideLowSupport = false
        state.minimumSupportPercent = 0.125
        state.matrixMinimumPercent = 0.125
        state.matrixMinimumPrevalencePercent = 0.125
        controller.testingApplyDisplayStateImmediately(state)

        let snapshot = try scenario.withAquaDrawingAppearance { try controller.captureExcelExportSnapshot() }
        XCTAssertEqual(snapshot.filters["minimumSupportPercent"], "0.125")
        XCTAssertEqual(snapshot.filters["matrixMinimumPercent"], "0.125")
        XCTAssertEqual(snapshot.filters["matrixMinimumPrevalencePercent"], "0.125")
        let frozen = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self, from: XCTUnwrap(snapshot.excelSnapshotData))
        let rows = Dictionary(frozen.metadata.compactMap { row in row.count == 2 ? (row[0], row[1]) : nil }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(rows["Minimum percent"], "0.125")
        XCTAssertEqual(rows[GenotypeExcelSnapshotBuilder.prevalenceMetadataLabel], "0.125")
        XCTAssertEqual(rows["matrixMinimumPercent"], "0.125", "the filter context row agrees with the metadata row")
        XCTAssertEqual(rows["matrixMinimumPrevalencePercent"], "0.125")
        XCTAssertEqual(rows["minimumSupportPercent"], "0.125")
    }

    // MARK: E3, the panel flow

    func testExcelPanelFlowHandsTheRunnerTheFrozenCaptureAndPublishesEvents() async throws {
        let scenario = try makeGenotypeOnlyManualScenario()
        defer { scenario.cleanup() }
        let controller = scenario.controller
        let root = scenario.root
        let direct = try scenario.canonicalExcelCapture()
        let recorder = ExportFlowRecorder()
        let masker = GenotypeCharacterizationCanonicalizer(root: root)
        var save: ((URL?) -> Void)?
        controller.excelSavePanelPresenter = { panel, _, completion in
            let namePattern = /example-genotype-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z\.xlsx/
            recorder.panelRecords = [
                "title " + panel.title,
                "message " + panel.message,
                "prompt " + panel.prompt,
                "canCreateDirectories \(panel.canCreateDirectories)",
                "contentTypes " + panel.allowedContentTypes.map(\.identifier).joined(separator: ","),
                "name " + (panel.nameFieldStringValue.wholeMatch(of: namePattern) == nil ? "unexpected " + panel.nameFieldStringValue : "matches pattern"),
            ]
            save = completion
        }
        controller.onExcelExportEvent = { event in recorder.record(event, maskedBy: masker) }
        let panelOpenedAt = Date()
        controller.viewportExportRunner = { snapshot, _ in
            let canonicalizer = GenotypeCharacterizationCanonicalizer(
                root: root,
                generatedAtWindow: GenotypeCharacterizationCanonicalizer.window(from: panelOpenedAt, to: Date())
            )
            let capture = try canonicalizer.encode(snapshot)
            await MainActor.run {
                recorder.runnerCaptures.append(capture)
            }
        }
        let state = controller.testingDisplayState
        controller.presentExcelExportPanel(expectedDisplayState: state)
        XCTAssertEqual(recorder.panelRecords, [
            "title Export Genotype View",
            "message Export Genotype View",
            "prompt Export",
            "canCreateDirectories true",
            "contentTypes org.openxmlformats.spreadsheetml.sheet",
            "name matches pattern",
        ])
        XCTAssertEqual(recorder.events, [])
        // The view changes while the panel is up. The runner must still
        // receive the capture frozen before the panel, not one taken at save.
        var changedWhilePanelIsUp = state
        changedWhilePanelIsUp.matrixMinimumReads += 3
        controller.testingApplyDisplayStateImmediately(changedWhilePanelIsUp)
        controller.testingComparisonMatrix.testingHideSamples(["AnimalA"])
        try XCTUnwrap(save)(root.appendingPathComponent("out.xlsx"))
        await waitUntil { recorder.events.count == 2 }
        XCTAssertEqual(recorder.events, ["started", "succeeded <ROOT>/out.xlsx"])
        XCTAssertEqual(recorder.runnerCaptures.count, 1)
        let runnerCapture = try XCTUnwrap(recorder.runnerCaptures.first)
        XCTAssertEqual(
            runnerCapture, direct,
            "The runner must receive the capture frozen before the panel\n"
                + GenotypeCharacterizationExpectedStore.differences(expected: direct, actual: runnerCapture)
        )
        controller.testingApplyDisplayStateImmediately(state)
        controller.testingResetMatrixVisibility()

        // A settled Inspector state that differs from the controller's yields no panel and no event.
        recorder.events = []
        recorder.panelRecords = []
        save = nil
        controller.presentExcelExportPanel(expectedDisplayState: state, settleDisplayState: {
            var settled = state
            settled.matrixMinimumReads += 1
            return settled
        })
        XCTAssertNil(save)
        XCTAssertEqual(recorder.panelRecords, [])
        XCTAssertEqual(recorder.events, [])

        // A settle step that throws publishes exactly one failed event with its message.
        controller.presentExcelExportPanel(expectedDisplayState: state, settleDisplayState: { throw SettleFailure() })
        XCTAssertNil(save)
        XCTAssertEqual(recorder.events, ["failed The Inspector state could not be settled."])
    }

    // MARK: E4, manual definitions provenance

    func testManualDefinitionsExportRecordsItsProvenance() throws {
        let scenario = try makeGenotypeOnlyManualScenario()
        defer { scenario.cleanup() }
        let store = try GenotypeAnnotationStore(bundleURL: scenario.bundleURL, author: GenotypeCharacterizationFixture.author)
        scenario.controller.testingInstallEffectiveHaplotypeAnnotationStore(store)
        // The payload is the test's own input, the raw sidecar assignments
        // (five, the validator-rejected label included), not the current
        // assignments the production button encodes. The test pins the write
        // half, the bytes on disk and the provenance, not the payload builder.
        let assignments = store.sidecar.manualHaplotypeAssignments
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = try encoder.encode(assignments)
        let outputURL = scenario.root.appendingPathComponent("manual-haplotype-definitions.json")
        let source = SteppedTimeSource(startingAt: Date(timeIntervalSince1970: 1_800_000_000))
        let clock = ProvenanceRunClock(source: source.source)
        source.advance(by: 3)

        try scenario.controller.testingWriteManualDefinitionsExport(
            data: payload, outputURL: outputURL, assignmentCount: assignments.count, runClock: clock
        )

        XCTAssertEqual(try Data(contentsOf: outputURL), payload)
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let masker = GenotypeCharacterizationCanonicalizer(root: scenario.root)
        let iso = GenotypeCharacterizationCanonicalizer.iso8601
        func describe(_ value: ParameterValue) -> String {
            switch value {
            case .string(let text): return text
            case .integer(let number): return "\(number)"
            case .file(let url): return "file " + masker.maskRoot(in: url.path)
            default: return String(describing: value)
            }
        }
        func describe(_ options: [String: ParameterValue], as kind: String) -> [String] {
            options.keys.sorted().map { "\(kind) \($0) = " + describe(options[$0]!) }
        }
        let step = try XCTUnwrap(envelope.steps.first)
        var projection = [
            "workflow " + envelope.workflowName,
            "tool " + envelope.toolName,
            "steps \(envelope.steps.count)",
            "step tool " + step.toolName,
            "argv " + masker.maskRoot(in: step.argv.joined(separator: " ")),
            "durable " + masker.maskRoot(in: (step.durableReplayArgv ?? []).joined(separator: " ")),
        ]
        projection += describe(envelope.options.explicit, as: "explicit")
        projection += describe(envelope.options.defaults, as: "default")
        projection += describe(envelope.options.resolvedDefaults, as: "resolved")
        projection += describe(step.resolvedOptions, as: "step resolved")
        projection += envelope.files.map { file in
            "file \(file.role.rawValue) " + masker.maskRoot(in: file.path) + " sha256 " + (file.checksumSHA256 ?? "none")
        }
        projection += [
            "output " + masker.maskRoot(in: envelope.output?.path ?? "none"),
            "started " + iso.string(from: envelope.createdAt),
            "step started " + (step.startedAt.map(iso.string) ?? "none"),
            "step completed " + (step.completedAt.map(iso.string) ?? "none"),
            "wall seconds " + String(format: "%.1f", envelope.wallTimeSeconds ?? -1),
            "exit \(envelope.exitStatus ?? -1)",
        ]
        let bundle = "<ROOT>/Project/Analyses/run/manual.lungfishgenotype"
        let sidecarDigest = GenotypeCharacterizationCanonicalizer.sha256Hex(
            try Data(contentsOf: scenario.bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        )
        XCTAssertEqual(sidecarDigest, "4fce2a215405419f50f4eafdeb2dc16585a35eeb0885a7ff1dbb8c11830e24d4", "The pre-written sidecar must be the bytes the export read")
        XCTAssertEqual(projection, [
            "workflow lungfish app manual haplotype definition export",
            "tool Lungfish Genome Explorer",
            "steps 1",
            "step tool Lungfish Genome Explorer",
            "argv Lungfish Genome Explorer export-manual-haplotype-definitions --bundle \(bundle) --output <ROOT>/manual-haplotype-definitions.json",
            "durable Lungfish Genome Explorer export-manual-haplotype-definitions --bundle \(bundle) --output <ROOT>/manual-haplotype-definitions.json",
            "explicit bundle = file \(bundle)",
            "explicit output = file <ROOT>/manual-haplotype-definitions.json",
            "default format = json",
            "resolved assignmentCount = 5",
            "step resolved assignmentCount = 5",
            "file input \(bundle)/annotations.json sha256 4fce2a215405419f50f4eafdeb2dc16585a35eeb0885a7ff1dbb8c11830e24d4",
            "file output <ROOT>/manual-haplotype-definitions.json sha256 0ec3211c0efef9500f2d53e7e625db173c5adf28b2b8aa6e50dcec896a40b675",
            "output <ROOT>/manual-haplotype-definitions.json",
            "started 2027-01-15T08:00:00Z",
            "step started 2027-01-15T08:00:00Z",
            "step completed 2027-01-15T08:00:03Z",
            "wall seconds 3.0",
            "exit 0",
        ])
    }

    // MARK: E5, the scoped export request

    func testScopedExportRequestReachesOnlyTheOwningWindowScope() throws {
        let controller = makeCharacterizationController()
        let scope = WindowStateScope()
        controller.windowStateScope = scope
        var requests = 0
        controller.onExcelExportRequested = { requests += 1 }

        NotificationCenter.default.post(
            name: .genotypeResultExcelExportRequested, object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: scope)
        )
        XCTAssertEqual(requests, 1)

        NotificationCenter.default.post(
            name: .genotypeResultExcelExportRequested, object: nil,
            userInfo: ScopedEventFilter.scopedUserInfo(scope: WindowStateScope())
        )
        XCTAssertEqual(requests, 1, "Another window's scope must not reach this controller")

        NotificationCenter.default.post(name: .genotypeResultExcelExportRequested, object: nil, userInfo: nil)
        XCTAssertEqual(requests, 1, "An unscoped window event fails closed")
    }

    // MARK: E6, the panel's window

    func testSavePanelPresenterReceivesTheHostingWindow() throws {
        let scenario = try makeGenotypeOnlyManualScenario()
        defer { scenario.cleanup() }
        let controller = scenario.controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.contentViewController = nil }
        window.contentViewController = controller
        var received: NSWindow?
        var panels = 0
        controller.excelSavePanelPresenter = { _, presentedIn, completion in
            received = presentedIn
            panels += 1
            completion(nil)
        }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        XCTAssertEqual(panels, 1)
        XCTAssertTrue(received === window, "The sheet must attach to the controller's hosting window, never a fresh NSWindow")
    }
}
