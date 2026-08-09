// BundleManifestEscapeRootTests.swift - Tests for the origin-scoped,
// top-level-symlink-only escape allowance in
// `BundleManifest.validatedBundleMemberURL(..., allowedEscapeRoots:)`.
//
// These tests exercise the PURE Core-level rule: given a set of already-trusted
// `allowedEscapeRoots`, does the validator permit exactly the legitimate
// bundle-owned top-level symlinks and reject everything else? The derivation of
// the escape roots from `originBundlePath` (and all its security constraints)
// is tested at the LungfishIO layer.
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class BundleManifestEscapeRootTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishEscapeRootTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Helpers

    /// Asserts that `expression` throws `BundleValidationError.invalidPath`
    /// specifically (not merely "throws some error"). `XCTAssertThrowsError`
    /// alone would also pass for an unrelated error type, silently widening
    /// what these security negatives actually guarantee.
    private func assertThrowsInvalidPath(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> Void
    ) {
        do {
            try expression()
            XCTFail("Expected BundleValidationError.invalidPath to be thrown", file: file, line: line)
        } catch let error as BundleValidationError {
            switch error {
            case .invalidPath:
                break // expected
            default:
                XCTFail("Expected .invalidPath, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected BundleValidationError.invalidPath, got \(type(of: error)): \(error)", file: file, line: line)
        }
    }

    /// Builds a source bundle directory containing a real `genome/` dir with a
    /// payload file, and a viewer bundle whose top-level `genome` is a SYMLINK
    /// into the source bundle's `genome/`. Returns both URLs.
    private func makeSourceAndViewer(
        sourceName: String = "src.lungfishref",
        viewerName: String = "viewer.lungfishref"
    ) throws -> (source: URL, viewer: URL) {
        let source = tempDirectory.appendingPathComponent(sourceName, isDirectory: true)
        let sourceGenome = source.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceGenome, withIntermediateDirectories: true)
        try "ACGT".write(to: sourceGenome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)

        let viewer = tempDirectory.appendingPathComponent(viewerName, isDirectory: true)
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: viewer.appendingPathComponent("genome"),
            withDestinationURL: sourceGenome
        )
        return (source, viewer)
    }

    // MARK: - Default strict behavior

    func testValidatedBundleMemberURLDefaultEscapeRootsPreservesStrictBehavior() throws {
        let (_, viewer) = try makeSourceAndViewer()

        // No allowedEscapeRoots => today's strict behavior => a top-level
        // symlink pointing outside the bundle must throw .invalidPath.
        assertThrowsInvalidPath {
            _ = try BundleManifest.validatedBundleMemberURL(
                for: "genome/sequence.fa",
                in: viewer,
                field: "genome.path"
            )
        }
    }

    // MARK: - Owned top-level symlink into origin

    func testAllowedEscapeRootPermitsOwnedTopLevelSymlinkIntoOrigin() throws {
        let (source, viewer) = try makeSourceAndViewer()

        // With the source declared as an allowed escape root, the bundle-owned
        // top-level `genome` symlink into it is permitted.
        let resolved = try BundleManifest.validatedBundleMemberURL(
            for: "genome/sequence.fa",
            in: viewer,
            field: "genome.path",
            allowedEscapeRoots: [source]
        )
        // The returned candidate is the (unresolved) viewer-relative URL.
        XCTAssertEqual(resolved.lastPathComponent, "sequence.fa")
        // And it points at real content.
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        let contents = try String(contentsOf: resolved, encoding: .utf8)
        XCTAssertEqual(contents, "ACGT")
    }

    // MARK: - Leaf-file symlink rejected even with origin

    func testAllowedEscapeRootRejectsLeafFileSymlinkEvenWithOrigin() throws {
        // Here `genome/` is a REAL directory inside the viewer, and only the
        // leaf file `genome/sequence.fa` is a symlink into the origin. The
        // first path component (`genome`) is NOT a bundle-owned symlink, so
        // condition (a) fails and the escape must be rejected even though the
        // target lands inside an allowed root.
        let source = tempDirectory.appendingPathComponent("src.lungfishref", isDirectory: true)
        let sourceGenome = source.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceGenome, withIntermediateDirectories: true)
        let sourceFASTA = sourceGenome.appendingPathComponent("sequence.fa")
        try "ACGT".write(to: sourceFASTA, atomically: true, encoding: .utf8)

        let viewer = tempDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        let viewerGenome = viewer.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: viewerGenome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: viewerGenome.appendingPathComponent("sequence.fa"),
            withDestinationURL: sourceFASTA
        )

        assertThrowsInvalidPath {
            _ = try BundleManifest.validatedBundleMemberURL(
                for: "genome/sequence.fa",
                in: viewer,
                field: "genome.path",
                allowedEscapeRoots: [source]
            )
        }
    }

    // MARK: - Target outside origin rejected

    func testAllowedEscapeRootRejectsTargetOutsideOrigin() throws {
        // The bundle-owned top-level `genome` symlink points at a directory that
        // is NOT inside any allowed escape root. Condition (b) fails.
        let elsewhere = tempDirectory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "ACGT".write(to: elsewhere.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)

        let source = tempDirectory.appendingPathComponent("src.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let viewer = tempDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: viewer.appendingPathComponent("genome"),
            withDestinationURL: elsewhere
        )

        // `source` is an allowed root but the symlink points at `elsewhere`.
        assertThrowsInvalidPath {
            _ = try BundleManifest.validatedBundleMemberURL(
                for: "genome/sequence.fa",
                in: viewer,
                field: "genome.path",
                allowedEscapeRoots: [source]
            )
        }
    }

    // MARK: - Nested escape past origin rejected

    func testRejectsNestedSymlinkEscapePastOrigin() throws {
        // The bundle-owned top-level `genome` symlink points INTO the origin,
        // but inside the origin there is a deeper symlink that escapes the
        // origin entirely. The fully-resolved candidate must fall outside all
        // allowed roots and be rejected.
        let outside = tempDirectory.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "SECRET".write(to: outside.appendingPathComponent("payload.fa"), atomically: true, encoding: .utf8)

        let source = tempDirectory.appendingPathComponent("src.lungfishref", isDirectory: true)
        let sourceGenome = source.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceGenome, withIntermediateDirectories: true)
        // Deeper symlink inside the origin that escapes to `outside`.
        try FileManager.default.createSymbolicLink(
            at: sourceGenome.appendingPathComponent("sequence.fa"),
            withDestinationURL: outside.appendingPathComponent("payload.fa")
        )

        let viewer = tempDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: viewer.appendingPathComponent("genome"),
            withDestinationURL: sourceGenome
        )

        assertThrowsInvalidPath {
            _ = try BundleManifest.validatedBundleMemberURL(
                for: "genome/sequence.fa",
                in: viewer,
                field: "genome.path",
                allowedEscapeRoots: [source]
            )
        }
    }

    // MARK: - File-identity containment

    func testEscapeRootDescendancyDecidedByFileIdentityAcrossPrivateTmpAlias() throws {
        // `FileManager.default.temporaryDirectory` on macOS is under
        // `/var/folders/...` which resolves to `/private/var/folders/...`. A
        // naive string-prefix containment check would fail to match a
        // `/var/...` root against a `/private/var/...` candidate (or vice
        // versa). File-identity containment (st_dev, st_ino) makes them match.
        let (source, viewer) = try makeSourceAndViewer()

        // Build a /var-flavored alias of the source URL by replacing the
        // /private prefix if present, else prepend nothing (still exercises the
        // resolve-both-sides path because tempDirectory resolves through
        // /private).
        let sourcePath = source.path
        let aliasPath: String
        if sourcePath.hasPrefix("/private/var/") {
            aliasPath = String(sourcePath.dropFirst("/private".count))
        } else {
            aliasPath = sourcePath
        }
        let aliasRoot = URL(fileURLWithPath: aliasPath)

        // Even though `aliasRoot` may be a string-distinct path from the
        // resolved candidate, file identity resolves both to the same inode.
        let resolved = try BundleManifest.validatedBundleMemberURL(
            for: "genome/sequence.fa",
            in: viewer,
            field: "genome.path",
            allowedEscapeRoots: [aliasRoot]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }

    func testNFDvsNFCComponentNamesDecidedByFileIdentity() throws {
        // Create a source bundle whose name contains a composed (NFC) accented
        // character, then declare the escape root using the decomposed (NFD)
        // spelling of the same name. APFS is normalization-insensitive so both
        // spellings resolve to the same inode; file-identity containment must
        // accept the symlink.
        let nfcName = "réf.lungfishref"  // composed é
        let nfdName = nfcName.decomposedStringWithCanonicalMapping

        let source = tempDirectory.appendingPathComponent(nfcName, isDirectory: true)
        let sourceGenome = source.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceGenome, withIntermediateDirectories: true)
        try "ACGT".write(to: sourceGenome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)

        let viewer = tempDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: viewer.appendingPathComponent("genome"),
            withDestinationURL: sourceGenome
        )

        let nfdRoot = tempDirectory.appendingPathComponent(nfdName, isDirectory: true)

        let resolved = try BundleManifest.validatedBundleMemberURL(
            for: "genome/sequence.fa",
            in: viewer,
            field: "genome.path",
            allowedEscapeRoots: [nfdRoot]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }

    func testCaseVariantPathDecidedByFileIdentityNotStringPrefix() throws {
        // APFS default volumes are case-insensitive: a root declared with a
        // different letter case than the real directory must still be accepted
        // via file identity, and a string-prefix check that lowercased or not
        // would give an inconsistent answer.
        let source = tempDirectory.appendingPathComponent("Src.lungfishref", isDirectory: true)
        let sourceGenome = source.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceGenome, withIntermediateDirectories: true)
        try "ACGT".write(to: sourceGenome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)

        let viewer = tempDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: viewer.appendingPathComponent("genome"),
            withDestinationURL: sourceGenome
        )

        // Declare the escape root with a lowercased first letter.
        let caseVariantRoot = tempDirectory.appendingPathComponent("src.lungfishref", isDirectory: true)

        // On a case-insensitive volume this resolves to the same inode.
        if FileManager.default.fileExists(atPath: caseVariantRoot.path) {
            let resolved = try BundleManifest.validatedBundleMemberURL(
                for: "genome/sequence.fa",
                in: viewer,
                field: "genome.path",
                allowedEscapeRoots: [caseVariantRoot]
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        } else {
            // Case-sensitive volume: the case-variant path does not exist, so
            // it yields no matching identity and the escape is rejected. Both
            // outcomes are decided by file identity, never by string casing.
            assertThrowsInvalidPath {
                _ = try BundleManifest.validatedBundleMemberURL(
                    for: "genome/sequence.fa",
                    in: viewer,
                    field: "genome.path",
                    allowedEscapeRoots: [caseVariantRoot]
                )
            }
        }
    }
}
