// ReferenceOpenProgressTests.swift - Each pane names its work while a reference decodes off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishTestSupport

/// Holds a decode on its background thread until the test releases it.
final class BundleDecodeGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func waitForRelease() {
        _ = semaphore.wait(timeout: .now() + 30)
    }

    func release() {
        semaphore.signal()
    }
}

/// UX ruling Q-S1: while the decode runs, the list and the summary bar's
/// status item read "Loading sequences…" through accessibility. The rows then
/// show in the same viewport and VoiceOver hears one ready announcement.
@MainActor
final class ReferenceOpenProgressTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        try await super.tearDown()
    }

    func testSlowManifestDecodeShowsLoadingSequencesThenRows() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenProgress")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Slow Open", chromosomes: [.init(name: "chr1", length: 100)], in: root
        )
        let gate = BundleDecodeGate()
        BundleLoadProbe.install { kind, _ in
            dispatchPrecondition(condition: .notOnQueue(.main))
            if kind == .bundleManifest {
                gate.waitForRelease()
            }
        }

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)

        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)
        var announcements: [String] = []
        viewport.openProgress.announce = { announcements.append($0) }
        let progress = viewport.openProgress
        XCTAssertFalse(progress.listPlaceholder.isHidden)
        XCTAssertEqual(progress.listLabel.accessibilityLabel(), "Loading sequences\u{2026}")
        XCTAssertFalse(progress.statusItem.isHidden)
        XCTAssertEqual(progress.statusLabel.accessibilityLabel(), "Loading sequences\u{2026}")
        XCTAssertFalse(progress.statusSpinner.isAccessibilityElement())
        XCTAssertEqual(viewport.testSummaryText, "Slow Open")
        XCTAssertTrue(viewport.testDisplayedSequenceNames.isEmpty)

        gate.release()
        let opened = await waitUntil(timeout: .seconds(30)) {
            viewport.testEmbeddedViewerController.currentReferenceBundle != nil
        }
        XCTAssertTrue(opened, "the embedded viewer never opened")
        XCTAssertTrue(split.viewerController.referenceBundleViewportController === viewport)
        XCTAssertEqual(viewport.testDisplayedSequenceNames, ["chr1"])
        XCTAssertTrue(progress.listPlaceholder.isHidden)
        XCTAssertTrue(progress.statusItem.isHidden)
        XCTAssertEqual(announcements, ["Sequence list ready, 1 sequence"])
    }
}
