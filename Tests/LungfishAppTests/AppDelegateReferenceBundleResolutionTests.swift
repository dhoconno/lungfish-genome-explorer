// AppDelegateReferenceBundleResolutionTests.swift - Which bundle "the current bundle" is
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Tools > Call Variants... checked only `ViewerViewController.currentReferenceBundle`,
// which the `.browse` display route (every production `displayBundle(at:)` call) never
// sets and `clearBundleDisplay` clears, so the item was permanently disabled. File >
// Import Center > VCF Variants checked `currentBundleURL`, nil for the same reason and
// for a displayed mapping result, so every such VCF became a new variant-only bundle at
// the project root instead of a track on the displayed bundle. Both now share one
// resolver; these tests pin its order of preference and the bundle it hands back.

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class AppDelegateReferenceBundleResolutionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateReferenceBundleResolutionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @MainActor
    func testDisplayedBundleWinsInDisplayRouteOrder() {
        let sequenceRoute = URL(fileURLWithPath: "/p/seq.lungfishref", isDirectory: true)
        let browseRoute = URL(fileURLWithPath: "/p/browse.lungfishref", isDirectory: true)
        let mappingCopy = URL(fileURLWithPath: "/p/Analyses/run/ref.lungfishref", isDirectory: true)
        let selected = URL(fileURLWithPath: "/p/selected.lungfishref", isDirectory: true)

        XCTAssertEqual(
            AppDelegate.resolveReferenceBundleURL(
                currentReferenceBundleURL: sequenceRoute,
                currentBundleURL: sequenceRoute,
                referenceViewportRenderedBundleURL: browseRoute,
                mappingResultRenderedBundleURL: mappingCopy,
                selectedBundleURLs: [selected]
            ),
            sequenceRoute
        )
        // `.browse` mode: only the viewport knows the bundle.
        XCTAssertEqual(
            AppDelegate.resolveReferenceBundleURL(
                currentReferenceBundleURL: nil,
                currentBundleURL: nil,
                referenceViewportRenderedBundleURL: browseRoute,
                mappingResultRenderedBundleURL: nil,
                selectedBundleURLs: [selected]
            ),
            browseRoute
        )
        // A displayed mapping result resolves to its reference copy.
        XCTAssertEqual(
            AppDelegate.resolveReferenceBundleURL(
                currentReferenceBundleURL: nil,
                currentBundleURL: nil,
                referenceViewportRenderedBundleURL: nil,
                mappingResultRenderedBundleURL: mappingCopy,
                selectedBundleURLs: [selected]
            ),
            mappingCopy
        )
    }

    @MainActor
    func testSidebarSelectionCountsOnlyWhenNothingIsDisplayedAndOnlyWhenUnambiguous() {
        let a = URL(fileURLWithPath: "/p/a.lungfishref", isDirectory: true)
        let b = URL(fileURLWithPath: "/p/b.lungfishref", isDirectory: true)

        XCTAssertEqual(
            AppDelegate.resolveReferenceBundleURL(
                currentReferenceBundleURL: nil,
                currentBundleURL: nil,
                referenceViewportRenderedBundleURL: nil,
                mappingResultRenderedBundleURL: nil,
                selectedBundleURLs: [a, a]
            ),
            a.standardizedFileURL
        )
        XCTAssertNil(
            AppDelegate.resolveReferenceBundleURL(
                currentReferenceBundleURL: nil,
                currentBundleURL: nil,
                referenceViewportRenderedBundleURL: nil,
                mappingResultRenderedBundleURL: nil,
                selectedBundleURLs: [a, b]
            ),
            "two selected bundles are ambiguous"
        )
        XCTAssertNil(
            AppDelegate.resolveReferenceBundleURL(
                currentReferenceBundleURL: nil,
                currentBundleURL: nil,
                referenceViewportRenderedBundleURL: nil,
                mappingResultRenderedBundleURL: nil
            )
        )
        // A displayed non-reference bundle (a FASTQ package) is not a reference bundle.
        XCTAssertNil(
            AppDelegate.resolveReferenceBundleURL(
                currentReferenceBundleURL: nil,
                currentBundleURL: URL(fileURLWithPath: "/p/reads.lungfishfastq", isDirectory: true),
                referenceViewportRenderedBundleURL: nil,
                mappingResultRenderedBundleURL: nil
            )
        )
    }

    @MainActor
    func testSidebarCandidatesIncludeSelectedBundlesAndMappingResultReferenceCopies() throws {
        let bundleURL = tempDir.appendingPathComponent("ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let resultDirectory = tempDir.appendingPathComponent("minimap2-run", isDirectory: true)
        let viewerBundleURL = resultDirectory.appendingPathComponent("ref.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: viewerBundleURL, withIntermediateDirectories: true)
        try MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.rawValue,
            sourceReferenceBundleURL: bundleURL,
            viewerBundleURL: viewerBundleURL,
            bamURL: resultDirectory.appendingPathComponent("s.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("s.sorted.bam.bai"),
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        ).save(to: resultDirectory)
        let fastq = tempDir.appendingPathComponent("reads.lungfishfastq", isDirectory: true)

        let candidates = AppDelegate.referenceBundleCandidates(inSidebarSelection: [bundleURL, resultDirectory, fastq])

        XCTAssertEqual(candidates.map(\.lastPathComponent), ["ref.lungfishref", "ref.lungfishref"])
        XCTAssertEqual(candidates[1].standardizedFileURL, viewerBundleURL.standardizedFileURL)
    }

    @MainActor
    func testResolvedBundleLoadsItsManifestSoCallVariantsCanCheckTracks() throws {
        let bundleURL = tempDir.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let bamURL = bundleURL.appendingPathComponent("alignments/sample.sorted.bam")
        try FileManager.default.createDirectory(at: bamURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bam".utf8).write(to: bamURL)
        try Data("bai".utf8).write(to: bamURL.appendingPathExtension("bai"))
        try BundleManifest(
            name: "Ref",
            identifier: "bundle.ref",
            source: SourceInfo(organism: "Virus", assembly: "A", database: "Test"),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample",
                    format: .bam,
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai"
                )
            ]
        ).save(to: bundleURL)

        let bundle = try XCTUnwrap(AppDelegate.loadReferenceBundle(at: bundleURL))
        XCTAssertEqual(bundle.manifest.alignments.map(\.id), ["aln-1"])
        XCTAssertTrue(AppDelegate().canShowBAMVariantCalling(bundle: bundle))
        XCTAssertNil(AppDelegate.loadReferenceBundle(at: tempDir.appendingPathComponent("missing.lungfishref")))
    }

    @MainActor
    func testMenuValidationAndImportsShareTheResolver() {
        let source = combinedAppDelegateSource()

        // Call Variants: validation and action both resolve through the shared helper.
        XCTAssertTrue(source.contains("let bundle = currentReferenceBundle(in: activeMainWindowController())"))
        XCTAssertTrue(source.contains("bundle: currentReferenceBundle(in: controller)"))
        XCTAssertFalse(source.contains("viewerController?.currentReferenceBundle\n"),
                       "menu validation must not read the sequence-route-only property directly")

        // VCF and BAM imports (menu and Import Center, four sites) resolve the same way.
        XCTAssertEqual(source.components(separatedBy: "let bundleURL = currentReferenceBundleURL(in: originController)").count - 1, 4)
        XCTAssertTrue(source.contains("return currentReferenceBundleURL(in: activeMainWindowController()) != nil"))
    }
}
