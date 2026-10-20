// ReferenceBundleDisplayLeavesBundleBytesTests.swift - Showing a variant bundle changes no byte of any member
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.67 (decision MD32, BIO ruling BIO-CALLSDB-OPEN). Displaying a reference bundle opened
// `variants/calls.db` read-write and the drawer's bookmark read created the `variant_bookmarks` table in it,
// so a record's input digest of that file depended on whether the bundle had been viewed. The case drives
// `ViewerViewController` as ReadTimeWriteTests does, hashes every regular file under the bundle before and
// after, and requires the two maps to be equal. It covers every member, so it also answers whether any other
// read-write open on display writes.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ReferenceBundleDisplayLeavesBundleBytesTests: XCTestCase {
    /// How long the case waits after the drawer has the index, for work that the display schedules.
    private static let settleTime: Duration = .milliseconds(1_800)

    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "bundle-display-bytes")
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        scratch = nil
        try await super.tearDown()
    }

    func testDisplayingAVariantBundleLeavesEveryMemberByteIdentical() async throws {
        let bundle = try makeVariantBundle()
        let before = try Self.memberDigests(under: bundle)
        XCTAssertNotNil(before["variants/calls.db"], "The fixture holds the calls database.")
        XCTAssertNotNil(before["annotations/genes.db"], "The fixture holds the genes database.")

        let viewer = ViewerViewController()
        _ = viewer.view
        try viewer.displayBundle(at: bundle, mode: .sequence(name: "chr1", restoreViewState: false))
        // The display opens the drawer but does not build the search index. The embedded reference viewer builds
        // it right after (ReferenceBundleViewportController.swift:1059-1069, and MainWindowController.swift:365 for
        // the main viewer), which opens every variant database read-write, and the viewer's `didSet` hands the
        // index to the drawer, whose bookmark read is the write under test.
        let reference = try XCTUnwrap(viewer.viewerView.currentReferenceBundle)
        let index = AnnotationSearchIndex()
        index.buildIndex(bundle: reference, chromosomes: viewer.currentBundleDataProvider?.chromosomes ?? [])
        viewer.annotationSearchIndex = index
        try await waitForDrawerIndex(of: viewer)
        try await Task.sleep(for: Self.settleTime)
        viewer.clearBundleDisplay()
        try await Task.sleep(for: .milliseconds(300))

        let after = try Self.memberDigests(under: bundle)
        XCTAssertEqual(
            Self.changes(from: before, to: after), [],
            "Showing the bundle changed members of it, and a view is not an edit."
        )
        XCTAssertEqual(after, before)
    }

    // MARK: - Fixture

    /// The variant fixture of lane 13.30 (a sequence, a `genes` annotation track and a `calls` variant track),
    /// made from a BED file and a VCF the way the importers make them.
    private func makeVariantBundle() throws -> URL {
        let fileManager = FileManager.default
        let bundle = scratch.appendingPathComponent("Display.lungfishref", isDirectory: true)
        for member in ["genome", "annotations", "variants"] {
            try fileManager.createDirectory(
                at: bundle.appendingPathComponent(member, isDirectory: true), withIntermediateDirectories: true
            )
        }
        let bases = String(repeating: "ACGTTGCAAC", count: 300)
        let lines = stride(from: 0, to: bases.count, by: 60).map { start -> String in
            let from = bases.index(bases.startIndex, offsetBy: start)
            return String(bases[from..<bases.index(from, offsetBy: min(60, bases.count - start))])
        }
        try (">chr1\n" + lines.joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t3000\t6\t60\t61\n"
            .write(to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)

        let bed = scratch.appendingPathComponent("genes.bed")
        try "chr1\t1100\t1400\tgene-a\t0\t+\n".write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(
            bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/genes.db")
        )
        try fileManager.removeItem(at: bed)

        let vcf = scratch.appendingPathComponent("calls.vcf")
        try ([
            "##fileformat=VCFv4.2", "##contig=<ID=chr1,length=3000>",
            "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\ts1\ts2",
            "chr1\t1151\t.\tA\tG\t50\tPASS\t.\tGT\t0/1\t1/1",
        ].joined(separator: "\n") + "\n").write(to: vcf, atomically: true, encoding: .utf8)
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: bundle.appendingPathComponent("variants/calls.db"))
        try fileManager.removeItem(at: vcf)

        try BundleManifest(
            name: "Display Fixture",
            identifier: "org.lungfish.test.bundle-display-bytes",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 3000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 3000, offset: 6, lineBases: 60, lineWidth: 61)]
            ),
            annotations: [AnnotationTrackInfo(
                id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db"
            )],
            variants: [VariantTrackInfo(
                id: "calls", name: "Calls", path: "variants/calls.vcf.gz", indexPath: "variants/calls.vcf.gz.tbi",
                databasePath: "variants/calls.db"
            )],
            tracks: [],
            recordStore: nil
        ).save(to: bundle)
        return bundle
    }

    // MARK: - Waiting and hashing

    /// Returns once the viewer's drawer holds a finished search index, which is when its bookmark read has run.
    private func waitForDrawerIndex(of viewer: ViewerViewController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if let index = viewer.annotationDrawerView?.searchIndex, !index.isBuilding { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The drawer never took the search index.")
    }

    /// Every regular file under `root`, hidden ones included, by its path in the bundle, with the SHA-256 of its bytes.
    private static func memberDigests(under root: URL) throws -> [String: String] {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(atPath: root.path) else { throw CocoaError(.fileReadNoSuchFile) }
        var digests: [String: String] = [:]
        for case let relative as String in walker {
            let url = root.appendingPathComponent(relative)
            let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeRegular { digests[relative] = try ProvenanceFileHasher.sha256(of: url) }
        }
        return digests
    }

    /// What differs between two maps, in path order.
    private static func changes(from before: [String: String], to after: [String: String]) -> [String] {
        Set(before.keys).union(after.keys).sorted().compactMap { path -> String? in
            switch (before[path], after[path]) {
            case (nil, _?): return "added \(path)"
            case (_?, nil): return "removed \(path)"
            case (let old?, let new?) where old != new: return "rewrote \(path)"
            default: return nil
            }
        }
    }
}
