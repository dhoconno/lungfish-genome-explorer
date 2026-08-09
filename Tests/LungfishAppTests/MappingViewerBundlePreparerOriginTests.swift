// MappingViewerBundlePreparerOriginTests.swift - Finding-2 regression tests.
//
// The preparer must only emit the `@/` project-relative `originBundlePath` when
// the VIEWER bundle actually lives inside a `.lungfish` project. For a viewer
// bundle outside any project, it must fall back to the filesystem-relative
// (viewer-anchored, always-resolvable) form.
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class MappingViewerBundlePreparerOriginTests: XCTestCase {

    private func makeSource(at sourceBundle: URL) throws {
        let genomeDir = sourceBundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try "ACGT".write(to: genomeDir.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8)
        try "chr1\t4\n".write(to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            name: "Reference", identifier: "test.reference",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "genome/sequence.fa.gz", indexPath: "genome/sequence.fa.gz.fai",
                               totalLength: 4, chromosomes: [])
        ).save(to: sourceBundle)
    }

    func testOutOfProjectViewerUsesFilesystemRelativeOrigin() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparerOriginTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // No `.lungfish` project anywhere in the ancestry.
        let sourceBundle = tempDir.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try makeSource(at: sourceBundle)

        let viewerBundle = tempDir.appendingPathComponent("Analysis/Reference.lungfishref", isDirectory: true)
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle
        )

        let origin = try BundleManifest.load(from: viewerBundle).originBundlePath
        XCTAssertNotNil(origin)
        XCTAssertFalse(origin?.hasPrefix("@/") == true, "Out-of-project viewer must NOT get a @/ origin, got \(String(describing: origin))")
        XCTAssertTrue(origin?.hasPrefix("..") == true, "Expected filesystem-relative origin, got \(String(describing: origin))")
    }

    func testInProjectViewerUsesProjectRelativeOrigin() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreparerOriginTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let projectRoot = tempDir.appendingPathComponent("Test.lungfish", isDirectory: true)
        let sourceBundle = projectRoot
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try makeSource(at: sourceBundle)

        let viewerBundle = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle
        )

        let origin = try BundleManifest.load(from: viewerBundle).originBundlePath
        XCTAssertEqual(origin, "@/Reference Sequences/Reference.lungfishref")
    }
}
