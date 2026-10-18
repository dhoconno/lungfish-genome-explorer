// ReferenceOpenManifestLoadTests.swift - A reference opens with one manifest decode, off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishTestSupport

/// Records every decode that `BundleLoadProbe` reports.
final class BundleDecodeLog: Sendable {
    private let entries = Mutex<[(kind: BundleLoadProbe.Kind, path: String)]>([])

    /// Records each later decode. With `offMainOnly`, a decode on the main
    /// thread stops the test process at that decode.
    func install(offMainOnly: Bool) {
        BundleLoadProbe.install { [self] kind, url in
            if offMainOnly {
                dispatchPrecondition(condition: .notOnQueue(.main))
            }
            entries.withLock { $0.append((kind, url.standardizedFileURL.path)) }
        }
    }

    func count(_ kind: BundleLoadProbe.Kind) -> Int {
        entries.withLock { $0.filter { $0.kind == kind }.count }
    }
}

/// The manifest of a large reference is hundreds of megabytes and takes
/// seconds to decode. Opening one decoded it three times on the main thread,
/// for the route, for the embedded viewer and for the BAM metadata context.
@MainActor
final class ReferenceOpenManifestLoadTests: XCTestCase {
    override func tearDown() async throws {
        BundleLoadProbe.install(nil)
        try await super.tearDown()
    }

    func testReferenceOpenDecodesOnceOffMain() async throws {
        let root = try TestTempDirectory.make(prefix: "ReferenceOpenManifestLoad")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Open Once",
            chromosomes: [.init(name: "chr2", length: 80), .init(name: "chr1", length: 100)],
            in: root
        )
        let decodes = BundleDecodeLog()
        decodes.install(offMainOnly: true)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)

        let opened = await waitUntil(timeout: .seconds(30)) {
            split.viewerController.referenceBundleViewportController?
                .testEmbeddedViewerController.currentReferenceBundle?.url.standardizedFileURL
                == bundleURL.standardizedFileURL
        }
        XCTAssertTrue(opened, "the embedded viewer never opened the bundle")
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)
        XCTAssertEqual(viewport.testDisplayedSequenceNames.sorted(), ["chr1", "chr2"])
        XCTAssertEqual(decodes.count(.bundleManifest), 1)
    }
}
