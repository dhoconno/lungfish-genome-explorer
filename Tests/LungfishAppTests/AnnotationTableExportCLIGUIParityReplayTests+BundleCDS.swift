// AnnotationTableExportCLIGUIParityReplayTests+BundleCDS.swift - The bundle-wide CDS read of the derived columns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.38 M2 (rows M854 and M863, BIO ruling on M854 items 6 to 11, V1-1 and R-QB2). A region
// selection keeps its bytes and its digest. A new selection names the annotation tracks whose CDS the leaf reads across
// the bundle over the exported rows, and the drawer reads the same CDS for its filter and sort.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

extension AnnotationTableExportCLIGUIParityReplayTests {
    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// BIO ruling on M854 items 8 and 9. A selection with the region chr1 0-120, as the base wrote it, still writes the
    /// selection bytes and the payload pinned at 9a0922e66 with M1's commits, so a replay of a record made by 2.12 or
    /// by 2.13 before M2 regenerates its digest (BIO 6).
    func testRegionSelectionReplaysItsDigest() async throws {
        let root = deepRoot("region-replay")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeDerivedFixture(root)
        let collected = try await Self.collectDerived(Case(tab: .variants, format: .csv, derived: true), in: root)
        XCTAssertEqual(
            collected.table.codingFeatureRegion,
            AnnotationTableFeatureRegion(chromosome: "chr1", start: 0, end: 120, trackIDs: [Self.cdsTrackID])
        )
        let output = Self.outputURL(in: root, .csv)
        let run = try await runC(root, collected, format: .csv, output: output)
        XCTAssertTrue(run.completed, run.detail)
        let selection = URL(fileURLWithPath: try XCTUnwrap(run.invocation.selection))
        let selectionText = try String(contentsOf: selection, encoding: .utf8)
        XCTAssertTrue(selectionText.contains("\"schemaVersion\" : 2"), selectionText)
        XCTAssertEqual(try Self.sha256(selection), "7f37a4ea5ea3fba30faccc3893049a92b4c04a6bf5e1c9caa54e58c81b14709d", "the region selection's bytes\n\(selectionText)")
        let payload = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(try Self.sha256(output), "4f761a94c20ac07e3d441bfbe04cb6fc85306c3d95d36fbb59fed4109e8ea132", "the payload pinned at the base\n\(payload)")
    }

    /// What the drawer collects for a bundle-wide case on the second bundle. The viewer's cache holds `cdsF` only, and
    /// the rows come from the drawer's request with `readsBundleCodingFeatures`, so a Consequence sort reads the
    /// shared read. Side A's cells come from its own loop, every annotation track over each whole chromosome of the
    /// rows with `explicitCodingContext`, the viewer's answer once the view shows each row (item 2, no shared read).
    /// The selection names the tracks the drawer names, from `VariantTableBundleCodingFeatures.trackIDs`.
    static func collectBundleWide(_ parityCase: Case, in root: URL) async throws -> Collected {
        let folder = bundleURL(in: root)
        let manifest = try BundleManifest.load(from: folder)
        let bundle = ReferenceBundle(url: folder, manifest: manifest)
        let ivarDB = folder.appendingPathComponent("variants/ivar.db")
        let plainDB = folder.appendingPathComponent("variants/plain.db")
        let handles = [
            (trackId: ivarTrackID, db: try VariantDatabase(url: ivarDB)),
            (trackId: plainTrackID, db: try VariantDatabase(url: plainDB)),
        ]
        var aliasMaps = BundleChromosomeAliasMaps()
        aliasMaps.reset(chromosomes: manifest.genome?.chromosomes ?? [])
        let overlay = await VariantFormatOverlayLoader.load(
            sources: VariantFormatOverlaySource.iVarSources(bundle: bundle, databases: handles, aliasMaps: &aliasMaps)
        )
        let aliases = VariantTableCodingFeatures.referenceAliases(chromosomes: manifest.genome?.chromosomes ?? [])
        let name: (String) -> String = { bundle.chromosome(named: $0)?.name ?? $0 }
        var cached = VariantTableExportResolverSnapshot(
            features: VariantTableCodingFeatures.features(
                annotations: try bundle.getAnnotationsSync(
                    trackId: cdsTrackID, region: GenomicRegion(chromosome: "chr1", start: 10, end: 90)
                ),
                fallbackChromosome: "chr1", chromosomeName: name, context: { Optional(explicitCodingContext($0)) }
            ),
            variantChromosomeAliasMap: [:], referenceChromosomeAliases: aliases, referenceBundle: bundle
        )
        cached.codingFeatureRegion = AnnotationTableFeatureRegion(chromosome: "chr1", start: 10, end: 90, trackIDs: [cdsTrackID])
        XCTAssertEqual(cached.features.count, 1, "the viewer's cache holds cdsF only")
        let rows = try AnnotationTableVariantQueryRequest(
            context: AnnotationVariantQueryContext(
                databases: handles, trackNames: [ivarTrackID: "iVar calls", plainTrackID: "Plain calls"],
                trackChromosomes: [ivarTrackID: ["chr1"], plainTrackID: ["chr1"]], annotationDatabases: [],
                infoKeys: ["AF", "ALT_FREQ", "ALT_QUAL", "DP", "TYPE"], variantAliasMap: [:], formatOverlay: overlay
            ),
            query: .init(), types: [], infoFilters: [], selectedSamples: [], activeTokens: [], region: nil, geneList: nil,
            filterBookmarkedOnly: false, filterModerateOrHigher: false, withinSampleAFRange: nil, bookmarkedKeys: [],
            hiddenTrackIDs: [plainTrackID], variantColumnFilters: [], callerSettingsByTrack: [:], resolverSnapshot: cached,
            numericColumnKeys: ["position"], sortKey: parityCase.sortsByConsequence ? "consequence" : "position",
            sortAscending: parityCase.sortsByConsequence, readsBundleCodingFeatures: true
        ).run(shouldCancel: { false })
        var annotations: [SequenceAnnotation] = []
        for trackID in bundle.annotationTrackIds {
            for chromosome in Set(rows.map(\.chromosome)).sorted() {
                let length = Int(bundle.chromosome(named: chromosome)?.length ?? 0)
                annotations += try bundle.getAnnotationsSync(
                    trackId: trackID, region: GenomicRegion(chromosome: chromosome, start: 0, end: length)
                )
            }
        }
        let sideA = try VariantTableExportResolverSnapshot(
            features: VariantTableCodingFeatures.features(
                annotations: annotations, fallbackChromosome: "chr1", chromosomeName: name,
                context: { Optional(explicitCodingContext($0)) }
            ),
            variantChromosomeAliasMap: [:], referenceChromosomeAliases: aliases, referenceBundle: bundle
        ).preparingForBackgroundExport()
        let trackIDs = VariantTableBundleCodingFeatures.trackIDs(bundle: bundle)
        let sources = AnnotationTableExportSources(
            manifestURL: folder.appendingPathComponent(BundleManifest.filename),
            genomeURL: folder.appendingPathComponent("genome/sequence.fa"),
            annotationDatabases: [.init(trackID: cdsTrackID, url: folder.appendingPathComponent("annotations/cds.db"))],
            variantDatabases: [.init(trackID: ivarTrackID, url: ivarDB), .init(trackID: plainTrackID, url: plainDB)],
            overlayURLsByTrack: Dictionary(grouping: overlay.sourceIdentities, by: \.trackID)
                .mapValues { identities in identities.map(\.url).sorted { $0.path < $1.path } },
            codingFeatureTrackIDs: trackIDs
        )
        let query = [
            "text": "", "sort": parityCase.sortsByConsequence ? "consequence:ascending" : "position:descending",
            "derivedVariantResolutionScope": AnnotationTableVariantQueryRequest.bundleCodingFeatureResolutionScope,
        ]
        return Collected(
            snapshot: .captureVariants(
                rows, columns: derivedVariantColumns, scope: parityCase.scope,
                numericInfoColumnIDs: derivedNumericColumnIDs, integerInfoColumnIDs: ["info_DP"],
                sourceURLs: try sources.urls(tab: "variants", trackIDs: Set(rows.map(\.trackId))), queryDescription: query,
                resolvedText: AnnotationTableExport.variantResolvedText(
                    rows: rows, columns: derivedVariantColumns,
                    callerSettingsByTrack: [ivarTrackID: VariantCallerSettingsSummary.text(databaseURL: ivarDB)],
                    resolverSnapshot: sideA
                )
            ),
            table: AnnotationTableExportSelection(
                scope: parityCase.scope.rawValue, columns: derivedVariantColumns,
                numericColumnIDs: derivedNumericColumnIDs.sorted(), integerColumnIDs: ["info_DP"],
                variantChromosomeAliases: [:], bundleCodingFeatureTrackIDs: trackIDs
            )
        )
    }

    /// The Position and the three derived cells of each row of side C's TSV, in written order.
    static func bundleDerivedRows(_ runs: RouteParityRuns) throws -> [(position: String, cells: [String])] {
        let text = try String(contentsOf: outputURL(in: runs.c.root, .tsv), encoding: .utf8)
        return text.split(separator: "\n").dropFirst()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == derivedVariantColumns.count }
            .map { ($0[2], Array($0.suffix(3))) }
    }

    /// BIO ruling on M854 item 9. With the viewer's cache over `cdsF` only, the `cdsR` row at POS 110 still exports
    /// `G3D` and its `cdsR` label, on Selected Rows and on All Matching, and A equals C.
    func testRowOutsideTheViewGetsItsDerivedCells() async throws {
        for scope in [AnnotationTableExportScope.selected, .allMatching] {
            let runs = try await assertParity(Case(tab: .variants, format: .tsv, derived: true, bundleWide: true, scope: scope))
            let row = try XCTUnwrap(try Self.bundleDerivedRows(runs).first { $0.position == "110" }, "\(scope)")
            XCTAssertEqual(row.cells, ["geneR • cdsR", "geneR • cdsR: missense_variant G3D", "G3D"], "\(scope)")
        }
    }

    /// BIO ruling on M854 item 9 and F7. All Matching sorted by Consequence, with the POS 110 row outside the cached
    /// region, writes the rows in the order of their exported cells, so that row sorts last and not beside the empty
    /// POS 4 row, and A equals C.
    func testDerivedSortPlacesRowsOutsideTheView() async throws {
        let runs = try await assertParity(
            Case(tab: .variants, format: .tsv, derived: true, bundleWide: true, sortsByConsequence: true)
        )
        let rows = try Self.bundleDerivedRows(runs)
        XCTAssertEqual(rows.map(\.position), ["4", "14", "65", "31", "110"])
        XCTAssertEqual(rows.map { $0.cells[1] }, [
            "", "geneF • cdsF: frameshift_variant", "geneF • cdsF: missense_variant W12S",
            "geneF • cdsF: synonymous_variant G7G", "geneR • cdsR: missense_variant G3D",
        ])
    }

    /// Runs the leaf on a selection written directly and checks it ends with `status`, says `words`, and leaves
    /// neither the output nor its record.
    private func assertLeafRefuses(
        _ root: URL, _ table: AnnotationTableExportSelection, identities: [String], status: Int, saying words: String,
        _ label: String
    ) async throws {
        let output = Self.outputURL(in: root, .csv)
        let selection = try ViewerExportSelection(identities: identities, annotationTable: table).write(besideOutput: output)
        let invocation = AnnotationTableExport.invocation(
            bundleURL: Self.bundleURL(in: root), tab: .variants, format: .csv,
            selectionURL: selection, outputURL: output, force: true
        )
        let run = await RouteParityHarness.runCLI(harness.cliBinary, arguments: invocation.arguments(), timeout: .seconds(60))
        XCTAssertEqual(run.status.map { Int($0) }, status, "\(label) \(run.detail)")
        XCTAssertTrue((run.stdout + run.stderr).contains(words), "\(label) \(run.stdout) \(run.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(label) leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), "\(label) and no record")
    }

    /// BIO ruling on M854 items 6 and 9, R-QB2 item 1. A track holding 50,000 annotations over the POS 65 row fails
    /// the read at its limit in both scopes with exit 64, the ruled words and no file.
    func testCDSReadOverItsLimitFails() async throws {
        let root = deepRoot("cds-limit")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeDerivedFixture(root)
        let collected = try await Self.collectDerived(Case(tab: .variants, format: .csv, derived: true), in: root)
        let database = Self.bundleURL(in: root).appendingPathComponent("annotations/cds.db")
        let bed = root.appendingPathComponent("many.bed")
        try (0..<VariantTableBundleCodingFeatures.annotationLimit)
            .map { "chr1\t60\t70\tf\($0)\t0\t+\t60\t70\t0,0,0\t1\t10\t0\tCDS\tgene=g\($0)\n" }.joined()
            .write(to: bed, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: database)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: database)
        try FileManager.default.removeItem(at: bed)
        let words = "The annotation track CDS holds at least 50,000 annotations in chr1:65-65, the most the export reads "
            + "from one track at a time, so the Gene / Protein, Consequence and AA Change cells of the variants there "
            + "could miss a coding feature. No file was written. Export fewer of the variants in that span at a time."
        for scope in ["selected", "allMatching"] {
            var table = collected.table
            table.scope = scope
            table.codingFeatureRegion = nil
            table.bundleCodingFeatureTrackIDs = [Self.cdsTrackID]
            table.query = [:]
            try await assertLeafRefuses(root, table, identities: collected.snapshot.rowIdentities, status: 64, saying: words, scope)
        }
    }

    /// V1-1 item 4. A selection naming both a region and the bundle's tracks is refused with the exit of an unreadable
    /// selection (3), and one naming a track the bundle lacks fails with 64, each before anything is written.
    func testSelectionWithBothCodingFeatureFormsIsRefused() async throws {
        let root = deepRoot("both-forms")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeDerivedFixture(root)
        let collected = try await Self.collectDerived(Case(tab: .variants, format: .csv, derived: true), in: root)
        var both = collected.table
        both.bundleCodingFeatureTrackIDs = [Self.cdsTrackID]
        try await assertLeafRefuses(
            root, both, identities: collected.snapshot.rowIdentities, status: 3,
            saying: "names both a coding feature region and the bundle's coding feature tracks", "both forms"
        )
        var unknown = collected.table
        unknown.codingFeatureRegion = nil
        unknown.bundleCodingFeatureTrackIDs = ["gone"]
        try await assertLeafRefuses(
            root, unknown, identities: collected.snapshot.rowIdentities, status: 64,
            saying: "The selection names the annotation track gone, which this bundle does not hold.", "unknown track"
        )
    }
}
