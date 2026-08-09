// MappingViewerBundleFetchTests.swift - Phase 1 real-path regression tests.
//
// These prove that after Item 1's origin-scoped escape-root fix, a prepared
// mapping VIEWER bundle (whose `genome/` etc. are symlinks into the external
// source `.lungfishref`) opens through `ReferenceBundle` and fetches sequence
// byte-for-byte identical to the source bundle — through the real
// `SyncBgzipFASTAReader` path production ships through. They also pin the
// security-critical negatives (out-of-project viewer stays strict; a viewer
// with no `originBundlePath` rejects its own top-level symlink).
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishTestSupport

final class MappingViewerBundleFetchTests: XCTestCase {

    private static let realPreparer: MappingViewerScaffold.PreparerStep = { source, viewer in
        try MappingViewerBundlePreparer.prepareBaseBundle(
            sourceBundleURL: source,
            viewerBundleURL: viewer
        )
    }

    // MARK: - Positive (bgzip branch, byte-for-byte)

    func testPreparedViewerBundleOpensAndFetchSequenceSyncMatchesSourceBundleByteForByte() async throws {
        let scaffold: MappingViewerScaffold
        do {
            scaffold = try MappingViewerScaffold.make(payloadKind: .bgzip, preparer: Self.realPreparer)
        } catch let error as MappingViewerScaffold.ScaffoldError {
            if case .toolsUnavailable(let detail) = error {
                throw XCTSkip("bgzip payload requires samtools/bgzip: \(detail)")
            }
            throw error
        }
        defer { scaffold.cleanUp() }

        // Open BOTH bundles through the real fetch path.
        let sourceBundle = try await ReferenceBundle(url: scaffold.sourceBundleURL)
        let viewerBundle = try await ReferenceBundle(url: scaffold.viewerBundleURL)

        let chr1 = MappingViewerScaffold.defaultContigs[0]
        let region = GenomicRegion(chromosome: chr1.name, start: 0, end: chr1.bases.count)
        let sourceSeq = try sourceBundle.fetchSequenceSync(region: region)
        let viewerSeq = try viewerBundle.fetchSequenceSync(region: region)

        XCTAssertEqual(viewerSeq, sourceSeq, "Viewer fetch must equal source fetch byte for byte")
        XCTAssertEqual(viewerSeq, chr1.bases)
    }

    func testPreparedViewerBundleFetchesSecondContigAtNonZeroOffset() async throws {
        let scaffold: MappingViewerScaffold
        do {
            scaffold = try MappingViewerScaffold.make(payloadKind: .bgzip, preparer: Self.realPreparer)
        } catch let error as MappingViewerScaffold.ScaffoldError {
            if case .toolsUnavailable(let detail) = error {
                throw XCTSkip("bgzip payload requires samtools/bgzip: \(detail)")
            }
            throw error
        }
        defer { scaffold.cleanUp() }

        let viewerBundle = try await ReferenceBundle(url: scaffold.viewerBundleURL)
        let chr2 = MappingViewerScaffold.defaultContigs[1]

        // Non-zero offset window in the SECOND contig (0-based 4..<12).
        let window = try viewerBundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: chr2.name, start: 4, end: 12)
        )
        let expected = String(Array(chr2.bases)[4..<12])
        XCTAssertEqual(window, expected)
    }

    // MARK: - Positive (plain FASTA / project-relative origin)

    func testPreparedViewerBundleWithProjectRelativeOriginOpens() async throws {
        // The scaffold places the viewer inside a `.lungfish` project, so the
        // real preparer records a `@/`-project-relative origin. Assert it opens.
        let scaffold = try MappingViewerScaffold.make(payloadKind: .plainFASTA, preparer: Self.realPreparer)
        defer { scaffold.cleanUp() }

        let originPath = try BundleManifest.load(from: scaffold.viewerBundleURL).originBundlePath
        XCTAssertNotNil(originPath)
        XCTAssertTrue(originPath?.hasPrefix("@/") == true, "Expected project-relative origin, got \(String(describing: originPath))")

        let viewerBundle = try await ReferenceBundle(url: scaffold.viewerBundleURL)
        let chr1 = MappingViewerScaffold.defaultContigs[0]
        let seq = try viewerBundle.fetchSequenceSync(
            region: GenomicRegion(chromosome: chr1.name, start: 0, end: chr1.bases.count)
        )
        XCTAssertEqual(seq, chr1.bases)
    }

    // MARK: - Negative (out-of-project viewer stays strict)

    func testViewerBundleOutsideProjectRootStaysStrict() async throws {
        // Build the scaffold, then relocate the viewer bundle OUT of the
        // `.lungfish` project (and out of any project). With no enclosing
        // project the escape roots are empty => strict => opening must fail.
        let scaffold = try MappingViewerScaffold.make(payloadKind: .plainFASTA, preparer: Self.realPreparer)
        defer { scaffold.cleanUp() }

        let fm = FileManager.default
        let relocatedParent = scaffold.projectRootURL
            .deletingLastPathComponent() // enclosing MappingViewerScaffold-<uuid> dir
            .appendingPathComponent("relocated-outside", isDirectory: true)
        try fm.createDirectory(at: relocatedParent, withIntermediateDirectories: true)
        let relocatedViewer = relocatedParent.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try fm.moveItem(at: scaffold.viewerBundleURL, to: relocatedViewer)

        do {
            _ = try await ReferenceBundle(url: relocatedViewer)
            XCTFail("Out-of-project viewer bundle must stay strict and reject its symlinks")
        } catch let error as ReferenceBundleError {
            guard case .validationFailed(let underlying) = error else {
                XCTFail("Expected .validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                underlying.contains { if case .invalidPath = $0 { return true }; return false },
                "Expected a wrapped BundleValidationError.invalidPath, got \(underlying)"
            )
        }
    }

    // MARK: - Negative (no originBundlePath rejects top-level symlink)

    func testViewerBundleWithoutOriginBundlePathRejectsTopLevelSymlink() async throws {
        let scaffold = try MappingViewerScaffold.make(
            payloadKind: .plainFASTA,
            includeOriginBundlePath: false,
            preparer: Self.realPreparer
        )
        defer { scaffold.cleanUp() }

        XCTAssertNil(try BundleManifest.load(from: scaffold.viewerBundleURL).originBundlePath)

        do {
            _ = try await ReferenceBundle(url: scaffold.viewerBundleURL)
            XCTFail("Viewer with no originBundlePath must reject its own top-level symlink")
        } catch let error as ReferenceBundleError {
            guard case .validationFailed(let underlying) = error else {
                XCTFail("Expected .validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(
                underlying.contains { if case .invalidPath = $0 { return true }; return false },
                "Expected a wrapped BundleValidationError.invalidPath, got \(underlying)"
            )
        }
    }

    // MARK: - Annotation/metadata through symlinked dir

    func testPreparedViewerBundleAnnotationOrMetadataResolvesThroughSymlinkedDir() async throws {
        // Build a source bundle that ALSO has an annotations/ directory with a
        // SQLite database, prepare a viewer that symlinks it, then assert the
        // annotation database resolves through the symlinked annotations/ dir
        // via the escape-root-aware public member accessor.
        let scaffold = try MappingViewerScaffold.make(payloadKind: .plainFASTA, preparer: Self.realPreparer)
        defer { scaffold.cleanUp() }

        let fm = FileManager.default
        // Add annotations/ to the SOURCE bundle after the fact and re-run the
        // preparer so the viewer symlinks it too.
        let sourceAnnotations = scaffold.sourceBundleURL.appendingPathComponent("annotations", isDirectory: true)
        try fm.createDirectory(at: sourceAnnotations, withIntermediateDirectories: true)
        let annDB = sourceAnnotations.appendingPathComponent("genes.sqlite")
        try Data("sqlite-placeholder".utf8).write(to: annDB)

        // Update the source manifest to declare the annotation track, then re-prepare.
        let srcManifest = try BundleManifest.load(from: scaffold.sourceBundleURL)
        let annTrack = AnnotationTrackInfo(
            id: "genes", name: "Genes", path: "annotations/genes.sqlite",
            databasePath: "annotations/genes.sqlite"
        )
        let updatedSrc = BundleManifest(
            formatVersion: srcManifest.formatVersion,
            name: srcManifest.name,
            identifier: srcManifest.identifier,
            source: srcManifest.source,
            genome: srcManifest.genome,
            annotations: [annTrack]
        )
        try updatedSrc.save(to: scaffold.sourceBundleURL)
        try Self.realPreparer(scaffold.sourceBundleURL, scaffold.viewerBundleURL)

        // The viewer's annotations/ is now a symlink into the source.
        let viewerAnnotations = scaffold.viewerBundleURL.appendingPathComponent("annotations")
        let attrs = try fm.attributesOfItem(atPath: viewerAnnotations.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)

        // Open the viewer bundle and resolve the annotation DB through the
        // escape-root-aware accessor.
        let viewerBundle = try await ReferenceBundle(url: scaffold.viewerBundleURL)
        let resolved = try viewerBundle.memberURL(
            for: "annotations/genes.sqlite",
            field: "annotations[genes].databasePath"
        )
        XCTAssertTrue(fm.fileExists(atPath: resolved.path), "Annotation DB must resolve through the symlinked annotations/ dir")
        let contents = try String(contentsOf: resolved, encoding: .utf8)
        XCTAssertEqual(contents, "sqlite-placeholder")
    }
}
