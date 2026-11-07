// MappingWindowFrameTests.swift - A mapping result keeps the window's frame (3.3 lane RESCANFIX, owner row 12, W-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner row 12 of the Preview 2026.11.2 check list, ruled EVIDENCE in D6. W-26 of the 2026-11-05 walk saw the main
// window grow to 4387 points on a 2560 point screen when a mapping result's summary line was long, with the toolbar and
// the Inspector off screen. WALKFIX (d0dde46bc) let `ReferenceBundleSummaryLabel` yield to the window. This test sets a
// real window's frame, selects a mapping result and then one whose BAM files are gone, and reads the frame after each.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class MappingWindowFrameTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer?
    private var frameDefaults: HostDefaultsRestorer?

    override func setUpWithError() throws {
        isolateAlignmentPaneDefaults()
    }

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "MappingWindowFrame")
        // The viewport saves layouts under the result's path, and a window may save its frame by name.
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        frameDefaults = HostDefaultsRestorer(keysContaining: "NSWindow Frame")
    }

    override func tearDown() async throws {
        frameDefaults?.restore()
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    /// 760 points, then 2,200 points or the widest the screen holds. After each selection the window's width and origin
    /// are as set, within 1 point.
    func testMappingResultKeepsWindowsOf760And2200Points() async throws {
        let healthy = try makeMapping("Healthy")
        let bamsGone = try makeMapping("BAMsGone")
        // The result's own BAM path is only recorded; the viewer bundle's track BAM is the file on disk.
        let onDisk = bamsGone.bams.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertFalse(onDisk.isEmpty, "the BAMs-gone fixture had no BAM on disk to remove")
        for bam in onDisk {
            try FileManager.default.removeItem(at: bam)
            try? FileManager.default.removeItem(at: bam.appendingPathExtension("bai"))
        }
        let harness = try ViewSwitchWindowHarness()
        defer { harness.close() }
        let visible = try XCTUnwrap(harness.window.screen ?? NSScreen.main, "the frame test needs a screen").visibleFrame
        let wide = min(2200, visible.width)
        print("MappingWindowFrameTests: the screen's visible frame is \(Int(visible.width))x\(Int(visible.height)), so the wide window is \(Int(wide)) points")

        for width in [760, wide] {
            let asked = NSRect(x: visible.minX, y: visible.minY, width: width, height: min(820, visible.height))
            harness.window.setFrame(asked, display: true)
            harness.window.layoutIfNeeded()
            // A window narrower than its own minimums takes them before any result shows (open row
            // WINDOW-GROWS-MINIMUMS), so the frame each selection must keep is the one the window took.
            let set = harness.window.frame
            print("MappingWindowFrameTests: asked for \(asked), the window took \(set) before any result")
            for mapping in [healthy, bamsGone] {
                harness.split.displayMappingAnalysisFromSidebar(at: mapping.result)
                let line = await settledSummaryLine(of: mapping, in: harness)
                harness.window.layoutIfNeeded()
                let frame = harness.window.frame
                let context = "\(Int(width)) points, \(mapping.result.deletingLastPathComponent().lastPathComponent), summary line \(line.count) characters: \(line)"
                print("MappingWindowFrameTests: \(context), frame \(frame)")
                XCTAssertEqual(frame.width, set.width, accuracy: 1, "the window grew to \(frame.width) points, \(context)")
                XCTAssertEqual(frame.minX, set.minX, accuracy: 1, "the window moved to x \(frame.minX), \(context)")
                XCTAssertEqual(frame.minY, set.minY, accuracy: 1, "the window moved to y \(frame.minY), \(context)")
            }
        }
    }

    // MARK: - Helpers

    private struct Mapping {
        let result: URL
        let bams: [URL]
    }

    /// Waits until the viewport shows `mapping` and its summary line is written, then returns the line.
    private func settledSummaryLine(of mapping: Mapping, in harness: ViewSwitchWindowHarness) async -> String {
        let viewer = harness.split.viewerController!
        let settled = await waitUntil(budget: .lookup) {
            guard let viewport = viewer.referenceBundleViewportController else { return false }
            return viewport.currentInput?.mappingResultDirectoryURL == mapping.result.standardizedFileURL
                && viewport.summaryLabel.stringValue.contains("Mapping")
        }
        let line = viewer.referenceBundleViewportController?.summaryLabel.stringValue ?? "no viewport"
        XCTAssertTrue(settled, "the mapping result never showed its summary line, it reads \(line)")
        return line
    }

    /// A mapping result with a viewer bundle and one sample's alignment, the shape of `ReferenceBundleSurfaceRouteTests`.
    private func makeMapping(_ name: String) throws -> Mapping {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = try MappingRoutingFixture.makeReferenceBundle(
            name: "Viewer \(name)", chromosomes: [.init(name: "chrA", length: 100)], in: folder
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundle, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true,
            originalSourcePath: MappingRoutingFixture.ownBAMOriginalSourcePath
        )
        let result = folder.appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let summary = MappingContigSummary(
            contigName: "chrA", contigLength: 100, mappedReads: 9, mappedReadPercent: 90,
            meanDepth: 3.5, coverageBreadth: 0.8, medianMAPQ: 60, meanIdentity: 0.99
        )
        let saved = MappingRoutingFixture.makeMappingResult(resultDirectory: result, viewerBundleURL: bundle, contigs: [summary])
        try saved.save(to: result)
        return Mapping(result: result, bams: [saved.bamURL, bundle.appendingPathComponent("alignments/reads-track.bam")])
    }
}
