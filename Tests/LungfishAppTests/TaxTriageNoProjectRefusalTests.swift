// TaxTriageNoProjectRefusalTests.swift - A TaxTriage launch with no project open is refused
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A12 (decision L1, UX U14). TaxTriage runs through `lungfish-cli` by default since 2.11
// U30 M4, and its launch takes the same refusal as Kraken2 and EsViritu. With no project open the dialog's own
// folder, beside the first input, used to receive the result. The launch now shows the `No Project
// Open` sheet and starts nothing, so no row appears and no byte is written beside the reads.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageNoProjectRefusalTests: XCTestCase {
    private var root: URL!
    private var rowIDs: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "taxtriage-no-project")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        rowIDs.forEach { OperationCenter.shared.clearItem(id: $0) }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// One sample whose reads sit in a folder of the temporary root, not in any project.
    private func makeConfig() throws -> TaxTriageConfig {
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        let input = reads.appendingPathComponent("S1.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
        return TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S1", fastq1: input)],
            outputDirectory: reads.appendingPathComponent("taxtriage-output", isDirectory: true),
            kraken2DatabasePath: root.appendingPathComponent("Databases/kraken2", isDirectory: true),
            maxCpus: 2,
            profile: "local"
        )
    }

    /// Phase 2.10 lane A35 (panel decision A4). A launch whose viewer sits in no window has nothing
    /// to hold a sheet, so the refusal reaches the user app-modal in the same words. The test binds
    /// a recording presenter, since no test can click an application-modal alert away.
    func testATaxTriageLaunchWhoseViewerHasNoWindowIsRefusedAppModal() throws {
        let config = try makeConfig()
        let before = try ClassifierRouteFixtures.snapshot(of: root)
        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = ViewerViewController()
        let recorder = RecordingNoProjectPresenter()
        let existing = Set(OperationCenter.shared.items.map(\.id))
        AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({
            TaxTriageSerialBatchRunner(runPipeline: { _, _ in throw CancellationError() })
        }) {
            AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
                delegate.launchTaxTriage(config: config, viewerController: viewer, routeContext: nil, route: .cli)
            }
        }
        let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        rowIDs.append(contentsOf: started.map(\.id))

        XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open"])
        XCTAssertEqual(
            recorder.presentations.map(\.message),
            ["Open or create a project before running TaxTriage. LGE saves its results in the project's Analyses folder."]
        )
        XCTAssertNil(recorder.presentations.first?.window, "no window is given, so it is app-modal")
        XCTAssertEqual(started.map(\.title), [], "a refused launch registers no row")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: root), before, "a refused launch writes nothing beside the reads")
    }

    func testATaxTriageLaunchWithNoProjectIsRefusedAndStartsNothing() async throws {
        let config = try makeConfig()
        let contexts: [(name: String, context: OperationRouteContext?)] = [
            ("no route context", nil),
            ("a window with no project", OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())),
        ]

        for (name, context) in contexts {
            let before = try ClassifierRouteFixtures.snapshot(of: root)
            let delegate = makeAppDelegateWithTemporaryState()
            let viewer = ViewerViewController()
            let window = NSWindow(contentViewController: viewer)
            window.isReleasedWhenClosed = false
            defer {
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                window.contentViewController = nil
                window.close()
            }

            let existing = Set(OperationCenter.shared.items.map(\.id))
            // A runner that ends the launch at once, so a launch that gets past the refusal never
            // reaches the managed Nextflow.
            AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({
                TaxTriageSerialBatchRunner(runPipeline: { _, _ in throw CancellationError() })
            }) {
                delegate.launchTaxTriage(config: config, viewerController: viewer, routeContext: context, route: .cli)
            }
            let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
            rowIDs.append(contentsOf: started.map(\.id))
            _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }

            XCTAssertEqual(
                window.attachedSheet.map(Self.texts(in:)),
                "No Project Open\nOpen or create a project before running TaxTriage. LGE saves its results in the project's Analyses folder.",
                "\(name): the sheet"
            )
            XCTAssertEqual(started.map(\.title), [], "\(name): a refused launch registers no row")
            XCTAssertEqual(
                try ClassifierRouteFixtures.snapshot(of: root), before,
                "\(name): a refused launch writes nothing beside the reads"
            )
        }
    }

    /// The text fields of a sheet, top to bottom, one per line.
    private static func texts(in window: NSWindow) -> String {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return texts.joined(separator: "\n")
    }
}
