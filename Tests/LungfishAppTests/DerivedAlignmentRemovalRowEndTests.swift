// DerivedAlignmentRemovalRowEndTests.swift - The removal row ends once the Inspector is gone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U61 (SW10 F1, UX 5). Remove Derived Alignment starts `lungfish-cli bam remove-track` on a row and
// completes the row when the runner returns. That completion sat after `guard let self, let split`, so a row whose
// Inspector was gone (a closed window, a project switch) never ended, and the Operations Panel showed it running
// for good although the command had removed the track. The tests run the Inspector's own workflow against a
// stand-in command that waits for a gate file, so the Inspector is let go while the runner is still out.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport

@MainActor
final class DerivedAlignmentRemovalRowEndTests: XCTestCase {
    private var root: URL!
    private var savedCLIPath: String?
    private var rowsBefore: Set<UUID> = []

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "removal-row-ends")
        savedCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        rowsBefore = Set(OperationCenter.shared.items.map(\.id))
    }

    override func tearDown() async throws {
        if let savedCLIPath {
            setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
        for item in OperationCenter.shared.items where !rowsBefore.contains(item.id) {
            OperationCenter.shared.clearItem(id: item.id)
        }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// The Inspector is let go while the runner is out, so nothing is left to reload. The command removed the
    /// track before it exited, so the row completes with the command's own message.
    func testTheRemovalRowEndsWhenTheInspectorIsGoneBeforeTheRunnerReturns() async throws {
        let run = try await runRemoval(releasingTheInspector: true)

        XCTAssertTrue(run.ended, "the removal row never ended after the command exited, it reads \(run.row.state)")
        XCTAssertEqual(run.row.state, .completed)
        XCTAssertEqual(run.row.detail, "Removed Sample 1 filtered.")
        XCTAssertEqual(run.arguments, InspectorViewController.removeDerivedAlignmentCLIArguments(
            bundleURL: run.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
        ), "the workflow ran the remove-track command of the row")
    }

    /// The control. With the Inspector still in its split the same workflow ends the row, so the stand-in and
    /// the confirm sheet reach the completion the other test releases the Inspector in front of.
    func testTheRemovalRowEndsWhenTheInspectorStaysInItsSplit() async throws {
        let run = try await runRemoval(releasingTheInspector: false)

        XCTAssertTrue(run.ended, "the removal row never ended, it reads \(run.row.state)")
        XCTAssertEqual(run.arguments, InspectorViewController.removeDerivedAlignmentCLIArguments(
            bundleURL: run.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
        ))
    }

    // MARK: - One removal through the Inspector

    private struct Removal {
        let row: OperationCenter.Item
        let ended: Bool
        let arguments: [String]?
        let bundleURL: URL
    }

    /// Asks the Inspector to remove the derived track of the fixture bundle, confirms the alert, and lets the
    /// stand-in command exit once the Inspector has been let go (or not). The command waits for a gate file
    /// before it prints its events, and the main actor runs the runner's completion only after the test awaits,
    /// so the Inspector is gone before the runner returns.
    private func runRemoval(releasingTheInspector: Bool) async throws -> Removal {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let bundlePath = fixture.bundleURL.path
        let gate = root.appendingPathComponent("gate")
        let stand = try StandInAlignmentCLI.make(in: root, body: [
            "while [ ! -f '\(gate.path)' ]; do /bin/sleep 0.05; done",
            StandInAlignmentCLI.line(#"{"event":"start","message":"Removing derived alignment...","progress":0}"#),
            StandInAlignmentCLI.line(
                "{\"event\":\"complete\",\"output\":\"\(bundlePath)\",\"outputs\":[\"\(bundlePath)\"],\"message\":\"Removed Sample 1 filtered.\"}"
            ),
        ].joined(separator: "\n"))
        setenv("LUNGFISH_CLI_PATH", stand.cli.path, 1)

        var split: MainSplitViewController? = MainSplitViewController()
        split?.loadViewIfNeeded()
        let window = NSWindow(contentViewController: try XCTUnwrap(split))
        window.isReleasedWhenClosed = false
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }
        var inspector: InspectorViewController? = split?.inspectorController
        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        inspector?.updateAlignmentSection(from: ReferenceBundle(url: fixture.bundleURL, manifest: manifest))
        inspector?.viewModel.documentSectionViewModel.bundleURL = fixture.bundleURL

        let remove = try XCTUnwrap(
            inspector?.viewModel.documentSectionViewModel.removeDerivedAlignmentTrack,
            "the Inspector wires the removal control of a derived alignment row"
        )
        remove(DerivedAlignmentTrackFixture.derivedTrackID)
        let sheet = try XCTUnwrap(window.attachedSheet, "the removal asks for a confirmation")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        let started = await waitUntil(timeout: .seconds(30)) {
            OperationCenter.shared.items.contains { !self.rowsBefore.contains($0.id) }
        }
        XCTAssertTrue(started, "the confirmed removal never began its row")
        let rowID = try XCTUnwrap(OperationCenter.shared.items.first { !rowsBefore.contains($0.id) }).id

        if releasingTheInspector {
            inspector?.removeFromParent()
            inspector = nil
            window.contentViewController = nil
            split = nil
        }
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        let ended = await waitUntil(timeout: .seconds(30)) {
            !(OperationCenter.shared.items.first { $0.id == rowID }?.state.isActive ?? false)
        }
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == rowID })
        withExtendedLifetime(split) {}
        return Removal(row: row, ended: ended, arguments: stand.arguments(), bundleURL: fixture.bundleURL)
    }
}
