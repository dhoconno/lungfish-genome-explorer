// GenotypeManualHaplotypeDraftAlertTests.swift - The unsaved-draft alert through an injected presenter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishGenotypeUI
import LungfishIO
import LungfishTestSupport

/// Drives the "Save Haplotype Assignment Changes?" alert with no decision
/// provider installed, so the controller builds the real alert and maps the
/// chosen button to a decision. Only the sheet presentation is replaced.
@MainActor
final class GenotypeManualHaplotypeDraftAlertTests: GenotypeResultViewportTestCase {
    private var bundleURL: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        bundleURL = try TestTempDirectory.make(prefix: "ManualHaplotypeDraftAlert")
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        TestTempDirectory.cleanup(bundleURL)
        try await super.tearDown()
    }

    func testCancelButtonKeepsTheDraftAndRefusesTheTransition() async throws {
        let controller = try makeControllerWithUnsavedDraft(hostedInWindow: true)
        let presenter = RecordingDraftAlertPresenter(answering: .alertThirdButtonReturn)
        presenter.install(on: controller)

        let allowed = await controller.prepareForManualHaplotypeTransition(.selection)

        XCTAssertFalse(allowed)
        XCTAssertEqual(presenter.presentations, [
            RecordingDraftAlertPresenter.Presentation(
                messageText: "Save Haplotype Assignment Changes?",
                informativeText: "The requested selection change will close the current sample editor.",
                buttonTitles: ["Save", "Discard Changes", "Cancel"],
                alertStyle: .warning,
                window: ObjectIdentifier(try XCTUnwrap(window))
            ),
        ])
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(controller.testingManualHaplotypeAssignments, [])
    }

    func testDiscardButtonDropsTheDraftAndAllowsTheTransition() async throws {
        let controller = try makeControllerWithUnsavedDraft(hostedInWindow: true)
        let presenter = RecordingDraftAlertPresenter(answering: .alertSecondButtonReturn)
        presenter.install(on: controller)

        let allowed = await controller.prepareForManualHaplotypeTransition(.lens)

        XCTAssertTrue(allowed)
        XCTAssertEqual(
            presenter.presentations.map(\.informativeText),
            ["The requested lens change will close the current sample editor."]
        )
        XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(controller.testingManualHaplotypeAssignments, [])
    }

    func testSaveButtonSavesTheDraftAndAllowsTheTransition() async throws {
        let controller = try makeControllerWithUnsavedDraft(hostedInWindow: true)
        let presenter = RecordingDraftAlertPresenter(answering: .alertFirstButtonReturn)
        presenter.install(on: controller)

        let allowed = await controller.prepareForManualHaplotypeTransition(.selection)

        XCTAssertTrue(allowed)
        XCTAssertEqual(presenter.presentations.count, 1)
        XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(controller.testingManualHaplotypeAssignments.map(\.label), ["Draft H1"])
    }

    func testWithoutAWindowNothingIsPresentedAndTheDraftIsKept() async throws {
        // The controller falls back to the key window, so the app object must
        // exist and hold no key window for this path to be reachable.
        let application = NSApplication.shared
        try XCTSkipIf(
            application.keyWindow != nil,
            "An earlier test in this process left a key window, so the no-window path cannot be reached"
        )
        let controller = try makeControllerWithUnsavedDraft(hostedInWindow: false)
        let presenter = RecordingDraftAlertPresenter(answering: .alertFirstButtonReturn)
        presenter.install(on: controller)

        let allowed = await controller.prepareForManualHaplotypeTransition(.selection)

        XCTAssertFalse(allowed)
        XCTAssertEqual(presenter.presentations, [])
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
    }

    // MARK: - Fixture

    /// A controller showing a saved, empty annotation sidecar with an unsaved
    /// manual-haplotype draft for AnimalA. No decision provider is installed,
    /// so a transition reaches the alert.
    private func makeControllerWithUnsavedDraft(
        hostedInWindow: Bool
    ) throws -> GenotypeResultViewController {
        let result = makeResult(bundleURL: bundleURL, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_001_01", reads: 21),
        ])
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: bundleURL)
        try GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-02T00:00:00Z")
            .encoded()
            .write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let controller = makeMatrixAnnotationGuardedController()
        if hostedInWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 900),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = controller.view
            self.window = window
        } else {
            _ = controller.view
        }
        controller.configure(result: result)
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Draft H1")
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        return controller
    }
}

/// Stands in for the sheet presenter. It records each alert it is handed and
/// answers with a fixed button, as if the user had clicked it.
@MainActor
private final class RecordingDraftAlertPresenter {
    struct Presentation: Equatable {
        let messageText: String
        let informativeText: String
        let buttonTitles: [String]
        let alertStyle: NSAlert.Style
        let window: ObjectIdentifier
    }

    private(set) var presentations: [Presentation] = []
    private let response: NSApplication.ModalResponse

    init(answering response: NSApplication.ModalResponse) {
        self.response = response
    }

    func install(on controller: GenotypeResultViewController) {
        controller.manualHaplotypeDraftAlertPresenter = { [self] alert, window in
            presentations.append(Presentation(
                messageText: alert.messageText,
                informativeText: alert.informativeText,
                buttonTitles: alert.buttons.map(\.title),
                alertStyle: alert.alertStyle,
                window: ObjectIdentifier(window)
            ))
            return response
        }
    }
}
