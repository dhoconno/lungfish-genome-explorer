// ReferenceBundleEscapeRootTests.swift - Security tests for the origin-scoped
// escape-root derivation in `ReferenceBundle`.
//
// These verify that `ReferenceBundle` derives escape roots from
// `manifest.originBundlePath` ONLY when every hardened constraint is satisfied,
// and otherwise falls back to strict behavior (empty roots => the app's own
// legitimate top-level symlinks are rejected). All fixtures live under the test
// temp directory; no external paths are ever read.
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class ReferenceBundleEscapeRootTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishRefEscapeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Fixture construction

    private struct Fixture {
        let projectRoot: URL
        let sourceBundle: URL
        let viewerBundle: URL
    }

    /// Builds a `.lungfish` project holding:
    /// - a source `.lungfishref` with a real `genome/sequence.fa` + `.fai`
    /// - a viewer `.lungfishref` whose top-level `genome` is a SYMLINK into
    ///   `genomeSymlinkTarget` (defaults to the source's `genome/`)
    /// - a viewer manifest with `originBundlePath = originOverride`
    ///
    /// When `matchingIdentifier` is false, the source manifest gets a different
    /// identifier than the viewer.
    private func makeFixture(
        originOverride: String?,
        genomeSymlinkTarget: URL? = nil,
        matchingIdentifier: Bool = true,
        sourceExtension: String = "lungfishref",
        projectExtension: String = "lungfish",
        viewerInsideProject: Bool = true
    ) throws -> Fixture {
        let fm = FileManager.default
        let projectRoot = tempDirectory
            .appendingPathComponent("Test.\(projectExtension)", isDirectory: true)
        let refSeqDir = projectRoot.appendingPathComponent("Reference Sequences", isDirectory: true)
        let sourceBundle = refSeqDir.appendingPathComponent("src.\(sourceExtension)", isDirectory: true)
        let sourceGenome = sourceBundle.appendingPathComponent("genome", isDirectory: true)
        try fm.createDirectory(at: sourceGenome, withIntermediateDirectories: true)

        // 4 bp single-contig genome (fai offset 6 = after ">chr1\n").
        try ">chr1\nACGT\n".write(
            to: sourceGenome.appendingPathComponent("sequence.fa"),
            atomically: true, encoding: .utf8
        )
        try "chr1\t4\t6\t4\t5\n".write(
            to: sourceGenome.appendingPathComponent("sequence.fa.fai"),
            atomically: true, encoding: .utf8
        )

        let sharedIdentifier = "escape-test.\(UUID().uuidString)"
        let sourceManifest = BundleManifest(
            formatVersion: "1.0",
            name: "Escape Source",
            identifier: matchingIdentifier ? sharedIdentifier : "\(sharedIdentifier).source-differs",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)]
            )
        )
        try sourceManifest.save(to: sourceBundle)

        let viewerParent: URL = viewerInsideProject
            ? projectRoot.appendingPathComponent("Analyses", isDirectory: true).appendingPathComponent("run", isDirectory: true)
            : tempDirectory.appendingPathComponent("outside-run", isDirectory: true)
        let viewerBundle = viewerParent.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try fm.createDirectory(at: viewerBundle, withIntermediateDirectories: true)

        // Top-level genome symlink.
        try fm.createSymbolicLink(
            at: viewerBundle.appendingPathComponent("genome"),
            withDestinationURL: genomeSymlinkTarget ?? sourceGenome
        )

        let viewerManifest = BundleManifest(
            formatVersion: "1.0",
            name: "Escape Viewer",
            identifier: sharedIdentifier,
            originBundlePath: originOverride,
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)]
            )
        )
        try viewerManifest.save(to: viewerBundle)

        return Fixture(projectRoot: projectRoot, sourceBundle: sourceBundle, viewerBundle: viewerBundle)
    }

    /// Asserts `ReferenceBundle(url:)` throws `ReferenceBundleError`, and
    /// (since every security negative in this file rejects via the SAME
    /// top-level genome-symlink escape check) additionally asserts the
    /// wrapped error is specifically `.validationFailed` carrying a
    /// `BundleValidationError.invalidPath` — not merely "some
    /// ReferenceBundleError", which would also pass for an unrelated failure
    /// (e.g. a manifest load error) and silently widen the guarantee.
    private func assertOpenThrows(_ viewerBundle: URL, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ReferenceBundle(url: viewerBundle)
            XCTFail("Expected ReferenceBundle to reject the escape", file: file, line: line)
        } catch let error as ReferenceBundleError {
            guard case .validationFailed(let underlying) = error else {
                XCTFail("Expected .validationFailed, got \(error)", file: file, line: line)
                return
            }
            let hasInvalidPath = underlying.contains { validationError in
                if case .invalidPath = validationError { return true }
                return false
            }
            XCTAssertTrue(
                hasInvalidPath,
                "Expected a wrapped BundleValidationError.invalidPath, got \(underlying)",
                file: file, line: line
            )
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - Positive: valid project-relative origin opens

    func testValidProjectRelativeOriginOpens() async throws {
        // `@/Reference Sequences/src.lungfishref` is a valid in-project origin.
        let fixture = try makeFixture(originOverride: "@/Reference Sequences/src.lungfishref")
        let bundle = try await ReferenceBundle(url: fixture.viewerBundle)
        let seq = try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr1", start: 0, end: 4))
        XCTAssertEqual(seq, "ACGT")
    }

    // MARK: - Security negatives (origin string validation)

    func testRejectsAbsoluteOriginBundlePath() async throws {
        // Absolute origin path must be rejected outright => strict => symlink rejected.
        let fixture = try makeFixture(originOverride: "/etc")
        await assertOpenThrows(fixture.viewerBundle)
    }

    func testRejectsDotDotTraversalOriginBundlePath() async throws {
        let fixture = try makeFixture(originOverride: "../../../../etc")
        await assertOpenThrows(fixture.viewerBundle)
    }

    func testRejectsDotDotTraversalAfterAtSlashPrefix() async throws {
        // `@/` anchors at the project root, but a `..` INSIDE the inner path
        // must still be rejected outright (escaping the project root via a
        // sibling of the project itself) — `validatedRelativeOriginPath`
        // strips only the `@/` prefix and then applies the SAME
        // no-`..`/no-`.`/no-empty-component validation to the remainder.
        let fixture = try makeFixture(originOverride: "@/../sibling.lungfishref")
        await assertOpenThrows(fixture.viewerBundle)
    }

    // MARK: - Security negatives (resolved origin constraints)

    func testRejectsOriginWithoutLungfishrefExtension() async throws {
        // The origin resolves to a plain directory that merely contains a
        // manifest but is NOT a `.lungfishref` bundle.
        let fm = FileManager.default
        let fixture = try makeFixture(originOverride: nil)
        // Create a plain-dir "origin" inside the project with a manifest and a
        // real genome, then point the viewer's genome symlink and origin at it.
        let plainOrigin = fixture.projectRoot.appendingPathComponent("plain-origin", isDirectory: true)
        let plainGenome = plainOrigin.appendingPathComponent("genome", isDirectory: true)
        try fm.createDirectory(at: plainGenome, withIntermediateDirectories: true)
        try ">chr1\nACGT\n".write(to: plainGenome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t4\t6\t4\t5\n".write(to: plainGenome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        let viewerIdentifier = try BundleManifest.load(from: fixture.viewerBundle).identifier
        let originManifest = BundleManifest(
            name: "Plain Origin", identifier: viewerIdentifier,
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 4, chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        )
        try originManifest.save(to: plainOrigin)

        // Repoint the viewer's genome symlink at the plain origin's genome and
        // set the origin path to the plain (non-.lungfishref) dir.
        let viewerGenomeLink = fixture.viewerBundle.appendingPathComponent("genome")
        try? fm.removeItem(at: viewerGenomeLink)
        try fm.createSymbolicLink(at: viewerGenomeLink, withDestinationURL: plainGenome)
        try rewriteOrigin(of: fixture.viewerBundle, to: "@/plain-origin")

        await assertOpenThrows(fixture.viewerBundle)
    }

    func testRejectsOriginWithMismatchedIdentifier() async throws {
        // Origin is a real `.lungfishref` but its identifier differs from the viewer's.
        let fixture = try makeFixture(
            originOverride: "@/Reference Sequences/src.lungfishref",
            matchingIdentifier: false
        )
        await assertOpenThrows(fixture.viewerBundle)
    }

    func testRejectsOriginEqualToAncestorOfViewerBundle() async throws {
        // Point the origin at the project root (an ancestor of the viewer bundle).
        // Even though the genome symlink lands inside it, an ancestor must be
        // rejected as an escape root.
        let fixture = try makeFixture(originOverride: "@/")
        await assertOpenThrows(fixture.viewerBundle)
    }

    func testRejectsOriginOutsideProjectRoot() async throws {
        // Viewer bundle placed OUTSIDE any `.lungfish` project => no project
        // root => empty escape roots => strict => symlink rejected.
        let fm = FileManager.default
        let plainRoot = tempDirectory.appendingPathComponent("no-project", isDirectory: true)
        let sourceBundle = plainRoot.appendingPathComponent("src.lungfishref", isDirectory: true)
        let sourceGenome = sourceBundle.appendingPathComponent("genome", isDirectory: true)
        try fm.createDirectory(at: sourceGenome, withIntermediateDirectories: true)
        try ">chr1\nACGT\n".write(to: sourceGenome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t4\t6\t4\t5\n".write(to: sourceGenome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        let identifier = "escape-test.no-project"
        try BundleManifest(
            name: "Src", identifier: identifier,
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 4, chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        ).save(to: sourceBundle)

        let viewerBundle = plainRoot.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try fm.createDirectory(at: viewerBundle, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: viewerBundle.appendingPathComponent("genome"), withDestinationURL: sourceGenome)
        try BundleManifest(
            name: "Viewer", identifier: identifier, originBundlePath: "../src.lungfishref",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 4, chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        ).save(to: viewerBundle)

        await assertOpenThrows(viewerBundle)
    }

    func testRejectsChainedOriginsNoRecursion() async throws {
        // Bundle A (viewer) declares origin B; B declares origin C. The genome
        // symlink escapes A into C. Because escape-root derivation is depth=1
        // (B's own originBundlePath is ignored), C is not reachable => reject.
        let fm = FileManager.default
        let fixture = try makeFixture(originOverride: "@/Reference Sequences/src.lungfishref")

        // Build C = the real "deep" source with the actual genome.
        let cBundle = fixture.projectRoot.appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("deep.lungfishref", isDirectory: true)
        let cGenome = cBundle.appendingPathComponent("genome", isDirectory: true)
        try fm.createDirectory(at: cGenome, withIntermediateDirectories: true)
        try ">chr1\nACGT\n".write(to: cGenome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t4\t6\t4\t5\n".write(to: cGenome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        let identifier = try BundleManifest.load(from: fixture.viewerBundle).identifier
        try BundleManifest(
            name: "C", identifier: identifier,
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 4, chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        ).save(to: cBundle)

        // B = src.lungfishref: turn it into a pure pointer to C (declares origin C),
        // and repoint the viewer genome symlink to escape INTO C (past B).
        try rewriteOrigin(of: fixture.sourceBundle, to: "@/Reference Sequences/deep.lungfishref")
        let viewerGenomeLink = fixture.viewerBundle.appendingPathComponent("genome")
        try? fm.removeItem(at: viewerGenomeLink)
        try fm.createSymbolicLink(at: viewerGenomeLink, withDestinationURL: cGenome)

        await assertOpenThrows(fixture.viewerBundle)
    }

    // MARK: - Security negative: viewer bundle not inside ANY `.lungfish` project

    func testRejectsWhenViewerNotInsideAnyLungfishProject() async throws {
        // Same fixture shape as the positive case (a real in-project-style
        // origin string), but the viewer bundle itself is built OUTSIDE any
        // `.lungfish` project root (`viewerInsideProject: false` places it at
        // `<tmp>/outside-run/viewer.lungfishref` with no `.lungfish` ancestor).
        // `FASTQBundle.findProjectRoot(from: bundleURL)` must return `nil`, so
        // `allowedRoots` returns `[]` regardless of how well-formed the
        // recorded `originBundlePath` looks => strict => symlink rejected.
        let fixture = try makeFixture(
            originOverride: "@/Reference Sequences/src.lungfishref",
            viewerInsideProject: false
        )
        await assertOpenThrows(fixture.viewerBundle)
    }

    // MARK: - Security negative: deeper symlink inside an otherwise-valid origin escapes

    func testRejectsDeeperSymlinkInsideValidOriginEscapingOutward() async throws {
        // The TOP-LEVEL `genome` symlink correctly targets the in-project
        // origin's `genome/` directory (condition (a) and the origin
        // derivation all pass, so `allowedRoots` returns `[origin]`). But
        // INSIDE that origin, the actual payload file the manifest names is
        // itself a symlink pointing OUTSIDE the origin entirely. Condition
        // (b) (file-identity containment of the FINAL resolved target) must
        // still fail and `validatedBundleMemberURL` must throw `.invalidPath`
        // — an origin-level pass does not vouch for what's nested inside it.
        let fm = FileManager.default
        let fixture = try makeFixture(originOverride: "@/Reference Sequences/src.lungfishref")

        let secret = tempDirectory.appendingPathComponent("secret-outside", isDirectory: true)
        try fm.createDirectory(at: secret, withIntermediateDirectories: true)
        try "SECRET".write(to: secret.appendingPathComponent("payload.fa"), atomically: true, encoding: .utf8)

        // Replace the source's real sequence.fa with a symlink escaping to `secret`.
        let sourceGenome = fixture.sourceBundle.appendingPathComponent("genome", isDirectory: true)
        let sourceSequence = sourceGenome.appendingPathComponent("sequence.fa")
        try fm.removeItem(at: sourceSequence)
        try fm.createSymbolicLink(
            at: sourceSequence,
            withDestinationURL: secret.appendingPathComponent("payload.fa")
        )

        await assertOpenThrows(fixture.viewerBundle)
    }

    // MARK: - Positive: filesystem-relative (non-`@/`) origin resolves (Item 3 off-by-one fix)

    func testFilesystemRelativeOriginResolvesRelativeToBundleDirectoryNotItsParent() async throws {
        // Covers the off-by-one fix in the non-`@/` resolution branch by
        // calling `ReferenceBundleEscapeRoots.allowedRoots` DIRECTLY (it is
        // `public`) rather than through a full `ReferenceBundle.init` open,
        // because the realistic full-open scenario is unreachable given two
        // independent design constraints that compose against each other:
        //
        // 1. `validatedRelativeOriginPath` unconditionally rejects any origin
        //    string containing a `..` component (by design — Item 1's
        //    pentest finding). So the `../../../Reference Sequences/...`
        //    shape `MappingViewerBundlePreparer.filesystemRelativePath`'s
        //    legacy fallback emits can NEVER reach resolution — step 1
        //    rejects it first, regardless of this fix.
        // 2. Because `..` is banned, a non-`@/` origin can only legally name
        //    a location reached by walking DOWNWARD from the bundle — which
        //    necessarily places the "origin" lexically INSIDE the viewer
        //    bundle's own directory tree, where the existing lexical
        //    descendancy check already permits it with no escape-root
        //    machinery involved at all. There is no way to construct a
        //    non-`@/`, non-`..` origin that BOTH resolves outside the
        //    viewer bundle (needing escape-root permission) AND exercises
        //    this fix through a full `ReferenceBundle.init` open.
        //
        // So the meaningful, precise assertion is on `allowedRoots`'s
        // RETURN VALUE directly: given a non-`@/` origin string and a
        // deliberately non-directory-flagged `bundleURL` (the realistic
        // shape for a URL that didn't come from a filesystem stat — e.g. a
        // `Codable`/JSON-decoded path string or a resolved security-scoped
        // bookmark), the derived escape root must be the SAME directory
        // `MappingViewerBundlePreparer.filesystemRelativePath` intended, not
        // one level too shallow.
        let fm = FileManager.default
        let projectRoot = tempDirectory.appendingPathComponent("Test.lungfish", isDirectory: true)
        let viewerBundle = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("viewer.lungfishref", isDirectory: true)
        // The real sibling source this scaffold shape represents (what
        // `filesystemRelativePath` from `MappingViewerScaffold`/production
        // actually points at): `Test.lungfish/Reference Sequences/src.lungfishref`.
        let sourceBundle = projectRoot
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("src.lungfishref", isDirectory: true)
        let sourceGenome = sourceBundle.appendingPathComponent("genome", isDirectory: true)
        try fm.createDirectory(at: sourceGenome, withIntermediateDirectories: true)
        try ">chr1\nACGT\n".write(to: sourceGenome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "chr1\t4\t6\t4\t5\n".write(to: sourceGenome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        let identifier = "escape-test.off-by-one-direct"
        let sourceManifest = BundleManifest(
            name: "Off-By-One Source", identifier: identifier,
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 4, chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        )
        try sourceManifest.save(to: sourceBundle)

        try fm.createDirectory(at: viewerBundle, withIntermediateDirectories: true)
        // The recorded origin string is the `..`-bearing form (the shape the
        // preparer's legacy fallback actually emits, and the shape whose
        // resolution — NOT its string validation — this fix corrects). We
        // call `allowedRoots` directly so the (unrelated, by-design) step-1
        // `..` rejection in `validatedRelativeOriginPath` never enters into
        // it; we are unit-testing resolution math, not the full open.
        let viewerManifestWithDotDot = BundleManifest(
            name: "Viewer", identifier: identifier,
            originBundlePath: "../../../Reference Sequences/src.lungfishref",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 4, chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        )

        // EXPLICITLY non-directory-flagged bundle URL (see note above on why
        // `isDirectory: false` must be forced rather than omitted: a bare
        // `URL(fileURLWithPath:)` auto-stats an EXISTING directory and
        // silently self-corrects the trailing slash, defeating this test).
        let bareViewerURL = URL(fileURLWithPath: viewerBundle.standardizedFileURL.path, isDirectory: false)

        // `allowedRoots` still returns `[]` here because step 1 rejects the
        // `..`-bearing string outright (by design, unrelated to this fix) —
        // confirms the two constraints compose as documented above.
        XCTAssertEqual(
            ReferenceBundleEscapeRoots.allowedRoots(forBundleAt: bareViewerURL, manifest: viewerManifestWithDotDot),
            []
        )

        // Now the shape this fix actually targets: a non-`@/`, NON-`..`
        // origin (permitted by step 1) resolved against the same
        // non-directory-flagged bundle URL. `_source/src.lungfishref`
        // resolves DOWNWARD from the viewer bundle itself.
        let nestedSource = viewerBundle
            .appendingPathComponent("_source", isDirectory: true)
            .appendingPathComponent("src.lungfishref", isDirectory: true)
        let nestedGenome = nestedSource.appendingPathComponent("genome", isDirectory: true)
        try fm.createDirectory(at: nestedGenome, withIntermediateDirectories: true)
        try sourceManifest.save(to: nestedSource)

        let viewerManifestNested = BundleManifest(
            name: "Viewer", identifier: identifier,
            originBundlePath: "_source/src.lungfishref",
            source: SourceInfo(organism: "Test", assembly: "Test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 4, chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)])
        )

        let roots = ReferenceBundleEscapeRoots.allowedRoots(forBundleAt: bareViewerURL, manifest: viewerManifestNested)
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(
            roots.first?.standardizedFileURL.path,
            nestedSource.standardizedFileURL.path,
            "Before the fix this resolved one directory too shallow (a SIBLING of the viewer bundle, e.g. '.../run/_source/src.lungfishref', instead of the real child '.../run/viewer.lungfishref/_source/src.lungfishref')"
        )
    }

    // MARK: - Helpers

    private func rewriteOrigin(of bundleURL: URL, to origin: String?) throws {
        let existing = try BundleManifest.load(from: bundleURL)
        let updated = BundleManifest(
            formatVersion: existing.formatVersion,
            name: existing.name,
            identifier: existing.identifier,
            description: existing.description,
            originBundlePath: origin,
            createdDate: existing.createdDate,
            modifiedDate: existing.modifiedDate,
            source: existing.source,
            genome: existing.genome,
            annotations: existing.annotations,
            variants: existing.variants,
            tracks: existing.tracks,
            alignments: existing.alignments,
            metadata: existing.metadata,
            browserSummary: nil,
            warnings: existing.warnings,
            recordStore: existing.recordStore
        )
        try updated.save(to: bundleURL)
    }
}
