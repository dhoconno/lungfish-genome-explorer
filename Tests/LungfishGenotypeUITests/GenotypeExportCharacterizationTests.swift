// GenotypeExportCharacterizationTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Byte-level characterization of the genotype export coordinator before its
// extraction from GenotypeResultViewController (Phase 2.3, REVIEW.md R6).
// The frozen Excel capture and the delimited viewport snapshot of four
// scenarios are compared with committed files under
// Tests/Fixtures/golden/genotype-gui. The panel flow, the manual definitions
// provenance, the scoped export request and the panel's window are pinned
// inline. Every test pins current behaviour, including behaviour the design
// experts flagged as wrong, so a later fix shows up as a reviewed diff.

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
    var runnerFormats: [GenotypeViewportExportFormat] = []

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
        controller.viewportExportRunner = { snapshot, format, _ in
            let canonicalizer = GenotypeCharacterizationCanonicalizer(
                root: root,
                generatedAtWindow: GenotypeCharacterizationCanonicalizer.window(from: panelOpenedAt, to: Date())
            )
            let capture = try canonicalizer.encode(snapshot)
            await MainActor.run {
                recorder.runnerCaptures.append(capture)
                recorder.runnerFormats.append(format)
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
        XCTAssertEqual(recorder.runnerFormats, [.excel])
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
