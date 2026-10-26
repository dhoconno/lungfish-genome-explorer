// ViewerWindowFrameProbeTests.swift - Showing a result viewer never resizes the window (obs-22 probes B1, B2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishAssemblyUI

/// Probes B1 and B2 of the obs-22 review of lane TREE. obs-22 grew the main window because a
/// view measured its text at 0 points wide, before its first layout, and wrote the result into
/// a required height. A viewer that measures the same way, or one that hosts SwiftUI with its
/// default sizing, could grow the window the same way. Each test gives a window a laptop-sized
/// frame, shows the viewer as the app does, and asserts the frame keeps its size.
@MainActor
final class ViewerWindowFrameProbeTests: XCTestCase {
    private static let probeFrame = NSRect(x: 0, y: 0, width: 1440, height: 800)

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    /// B1. The assembly summary strip is configured by the load Task that
    /// `displayAssemblyResult` starts, right after the viewer installs the result view and
    /// before its own layout settles. The strip measures at 0 points wide when it has not been
    /// laid out, and the fixture's ten fields then ask for about 600 points of height.
    func testDisplayingAnAssemblyResultKeepsTheWindowFrame() async throws {
        let viewer = ViewerViewController()
        let window = hostWindow(for: viewer)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, Self.probeFrame, "the window starts at the probe frame")

        viewer.displayAssemblyResult(try makeAssemblyResult())
        let configured = await waitUntil(budget: .standard) {
            viewer.assemblyResultController?.testSummaryStrip
                .value(for: "assembly-result-summary-n50").isEmpty == false
        }
        XCTAssertTrue(configured, "the load Task configured the summary strip within the standard budget")
        window.layoutIfNeeded()
        assertFrameKept(window, after: "showing an assembly result")
    }

    /// B2. The MHC viewer hosts its SwiftUI viewport with the default sizing options, which the
    /// two primer hosts turn off because SwiftUI's ideal size outranked the window's own size.
    /// A reference FASTA with one unwrapped line has the widest ideal size the viewport can
    /// have, so it is the case most likely to widen the window.
    func testDisplayingAnMHCReferenceBundleKeepsTheWindowFrame() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewerWindowFrameProbeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")
        let unwrappedSequence = String(repeating: "ACGT", count: 2_500)
        try ">M1 MHC-B exon 2 amplicon\n\(unwrappedSequence)\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )
        let model = try MHCReferenceBundleViewportModel.load(bundleURL: bundleURL)

        let viewer = ViewerViewController()
        let window = hostWindow(for: viewer)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, Self.probeFrame, "the window starts at the probe frame")

        viewer.displayMHCReferenceBundle(model, onEditHaplotypes: {})
        let hostingView = try XCTUnwrap(viewer.mhcReferenceBundleViewController?.view)
        let sized = await waitUntil(budget: .standard) {
            window.layoutIfNeeded()
            return hostingView.fittingSize.width > 0
        }
        XCTAssertTrue(sized, "SwiftUI sized the viewport within the standard budget")
        assertFrameKept(window, after: "showing an MHC reference bundle")
    }

    private func hostWindow(for viewer: ViewerViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: Self.probeFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        self.window = window
        window.contentViewController = viewer
        window.setFrame(Self.probeFrame, display: false)
        return window
    }

    private func assertFrameKept(
        _ window: NSWindow,
        after step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let detail = "after \(step) the window frame is \(window.frame), it was \(Self.probeFrame)"
        XCTAssertEqual(
            window.frame.height, Self.probeFrame.height, accuracy: 0.5,
            "height changed, \(detail)", file: file, line: line
        )
        XCTAssertEqual(
            window.frame.width, Self.probeFrame.width, accuracy: 0.5,
            "width changed, \(detail)", file: file, line: line
        )
    }
}
