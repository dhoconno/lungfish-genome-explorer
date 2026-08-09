// MappingViewerScaffoldSmokeTests.swift - Phase 0 infrastructure smoke test.
//
// Proves the shared `MappingViewerScaffold` fixture builds a realistic
// synthetic `.lungfish` project: a source reference bundle with a REAL genome
// payload, plus a prepared viewer bundle whose `genome/` is a resolving symlink
// into the source (produced by the REAL `MappingViewerBundlePreparer`). This is
// pure fixture infrastructure — it asserts NO product behaviour change (that is
// Phase 1). In particular it deliberately reads the SOURCE bundle genome, not
// the viewer bundle, because the viewer-bundle validator still (correctly, for
// Phase 0) rejects the app's own symlinks until Item 1 lands.
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishTestSupport

final class MappingViewerScaffoldSmokeTests: XCTestCase {

    /// Adapts the production preparer (which has a defaulted `fileManager`
    /// parameter) to the scaffold's two-argument `PreparerStep` signature.
    private static let realPreparer: MappingViewerScaffold.PreparerStep = { source, viewer in
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: source,
            viewerBundleURL: viewer
        )
    }

    /// Builds both payload flavours, injecting the real production preparer, and
    /// asserts: (1) the viewer `genome` is a symbolic link that resolves, and
    /// (2) the source bundle's genome payload is byte-for-byte readable via the
    /// real fetch path (plain `IndexedFASTAReader` and bgzip
    /// `SyncBgzipFASTAReader`).
    func testScaffoldBuildsResolvingSymlinkAndReadableSourcePayload() throws {
        let plain = try MappingViewerScaffold.make(
            payloadKind: .plainFASTA,
            preparer: Self.realPreparer
        )
        defer { plain.cleanUp() }
        try assertScaffold(plain)

        // The bgzip payload requires real samtools + bgzip; skip cleanly if the
        // machine lacks them rather than failing the infra smoke test.
        do {
            let bgzip = try MappingViewerScaffold.make(
                payloadKind: .bgzip,
                preparer: Self.realPreparer
            )
            defer { bgzip.cleanUp() }
            try assertScaffold(bgzip)
        } catch let error as MappingViewerScaffold.ScaffoldError {
            if case .toolsUnavailable(let detail) = error {
                throw XCTSkip("bgzip payload requires samtools/bgzip: \(detail)")
            }
            throw error
        }
    }

    /// The built-in preparer (used by IO/Core tests that cannot import
    /// `LungfishApp`) produces the same resolving-symlink layout.
    func testScaffoldBuiltInPreparerAlsoProducesResolvingSymlink() throws {
        let scaffold = try MappingViewerScaffold.make(payloadKind: .plainFASTA)
        defer { scaffold.cleanUp() }
        try assertScaffold(scaffold)
    }

    // MARK: - Helpers

    private func assertScaffold(_ scaffold: MappingViewerScaffold) throws {
        let fileManager = FileManager.default

        // Project root carries the `.lungfish` extension so origin-scoping can
        // resolve the enclosing project in Phase 1.
        XCTAssertEqual(scaffold.projectRootURL.pathExtension, "lungfish")
        XCTAssertTrue(fileManager.fileExists(atPath: scaffold.sourceBundleURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: scaffold.viewerBundleURL.path))

        // (1) The viewer genome is a symbolic link into the source and resolves.
        let viewerGenome = scaffold.viewerBundleURL.appendingPathComponent("genome")
        let attributes = try fileManager.attributesOfItem(atPath: viewerGenome.path)
        XCTAssertEqual(
            attributes[.type] as? FileAttributeType,
            .typeSymbolicLink,
            "Viewer genome/ must be a symlink (matches production preparer)"
        )
        let resolvedTarget = viewerGenome.resolvingSymlinksInPath()
        XCTAssertTrue(
            fileManager.fileExists(atPath: resolvedTarget.path),
            "Viewer genome symlink must resolve to a real directory"
        )
        // The symlink points into the source bundle's genome directory.
        let sourceGenome = scaffold.sourceBundleURL
            .appendingPathComponent("genome")
            .resolvingSymlinksInPath()
        XCTAssertEqual(resolvedTarget.standardizedFileURL.path, sourceGenome.standardizedFileURL.path)

        // The viewer manifest records an origin pointing at the source bundle.
        let viewerManifest = try BundleManifest.load(from: scaffold.viewerBundleURL)
        XCTAssertNotNil(viewerManifest.originBundlePath)

        // (2) The source bundle's genome payload is readable via the real fetch
        // path. Assert bases at a non-zero offset and near the contig end on
        // chr1, and that the SECOND contig resolves — catching off-by-one and
        // single-contig-only regressions.
        let sourceManifest = try BundleManifest.load(from: scaffold.sourceBundleURL)
        let sourceBundle = ReferenceBundle(url: scaffold.sourceBundleURL, manifest: sourceManifest)
        let contigs = MappingViewerScaffold.defaultContigs
        let chr1 = contigs[0]
        let chr2 = contigs[1]

        // Non-zero offset window in chr1 (0-based 4..<12).
        let chr1Mid = try sourceBundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: chr1.name, start: 4, end: 12)
        )
        XCTAssertEqual(chr1Mid, subsequence(of: chr1.bases, start: 4, end: 12))

        // Tail of chr1 (last 8 bases).
        let chr1Length = chr1.bases.count
        let chr1Tail = try sourceBundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: chr1.name, start: chr1Length - 8, end: chr1Length)
        )
        XCTAssertEqual(chr1Tail, subsequence(of: chr1.bases, start: chr1Length - 8, end: chr1Length))

        // Second contig resolves fully.
        let chr2Full = try sourceBundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: chr2.name, start: 0, end: chr2.bases.count)
        )
        XCTAssertEqual(chr2Full, chr2.bases)
    }

    private func subsequence(of bases: String, start: Int, end: Int) -> String {
        let chars = Array(bases)
        return String(chars[start..<end])
    }
}
