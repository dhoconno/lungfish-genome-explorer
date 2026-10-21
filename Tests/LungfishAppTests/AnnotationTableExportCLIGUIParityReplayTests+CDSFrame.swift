// AnnotationTableExportCLIGUIParityReplayTests+CDSFrame.swift - The GFF3 frame and the codon table of a bundle CDS
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.65 (V1-2, BIO ruling on 13.65 M1 items 1 to 5). Each case imports a GFF3 CDS through
// `AnnotationDatabase.createFromGFF3` into a bundle and resolves one SNP's Coding Feature, Consequence and AA Change
// cells on two sides. Side C is the leaf's read, `VariantTableBundleCodingFeatures.resolver`, which
// `AnnotationTableExportRowReader` builds for `lungfish-cli bundle export-annotation-table`. Side A is the viewer, a
// `SequenceViewerView` holding the bundle, whose `cdsCodingContext(for:)` builds each CDS's context (the context the
// hover reads) and whose `variantTableExportResolverSnapshot()` builds the table's features. Every literal is worked
// out by hand from the bases below, 1-based as GFF3 counts.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

extension AnnotationTableExportCLIGUIParityReplayTests {
    static let frameTrackID = "cds"

    /// `chrF`, A1 A2 T3 G4 A5 G6 C7 T8 G9 G10 T11 A12 A13 C14 C15. Its CDS 1-13 has phase 1, so its codons are ATG
    /// (2-4) AGC (5-7) TGG (8-10) TAA (11-13), M S W stop.
    static let chrFBases = "AATGAGCTGGTAACC"
    /// `chrM`, whose CDS 1-12 with `transl_table=2` reads ATG (1-3) AGC (4-6) TGG (7-9) TAA (10-12), M S W stop.
    static let chrMBases = "ATGAGCTGGTAACC"
    /// `chrR`. Its CDS is 11-18 and 3-7 on the reverse strand, and its coding sequence is CATGAGCT then GGTAA, read at
    /// phase 1 as ATG AGC TGG TAA, M S W stop. Base 12 (G) is the C at coding index 6, the last base of codon 2.
    static let chrRBases = "AATTACCGGGAGCTCATGAA"

    static let frameGFF3 = "##gff-version 3\n"
        + "chrF\t.\tCDS\t1\t13\t.\t+\t1\tID=cds-f;Name=f\n"
        + "chrM\t.\tCDS\t1\t12\t.\t+\t0\tID=cds-m;Name=m;transl_table=2\n"
        + "chrR\t.\tCDS\t3\t7\t.\t-\t2\tID=cds-r;Name=r\n"
        + "chrR\t.\tCDS\t11\t18\t.\t-\t1\tID=cds-r;Name=r\n"

    /// A bundle of `chromosomes` whose one annotation track `cds` is `gff` imported through
    /// `AnnotationDatabase.createFromGFF3` with `sizes`.
    static func makeFrameBundle(
        _ root: URL, chromosomes: [(name: String, bases: String)], gff: String, sizes: [(String, Int64)]?
    ) async throws -> ReferenceBundle {
        let folder = root.appendingPathComponent("frame.lungfishref", isDirectory: true)
        for name in ["genome", "annotations"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var fasta = ""
        var index = ""
        var infos: [ChromosomeInfo] = []
        for chromosome in chromosomes {
            fasta += ">\(chromosome.name)\n"
            let offset = fasta.utf8.count
            fasta += chromosome.bases + "\n"
            let length = chromosome.bases.count
            index += "\(chromosome.name)\t\(length)\t\(offset)\t\(length)\t\(length + 1)\n"
            infos.append(ChromosomeInfo(
                name: chromosome.name, length: Int64(length), offset: Int64(offset), lineBases: length, lineWidth: length + 1
            ))
        }
        try fasta.write(to: folder.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
        try index.write(to: folder.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8)
        let gffURL = root.appendingPathComponent("frame.gff3")
        try gff.write(to: gffURL, atomically: true, encoding: .utf8)
        _ = try await AnnotationDatabase.createFromGFF3(
            gffURL: gffURL, outputURL: folder.appendingPathComponent("annotations/cds.db"), chromosomeSizes: sizes
        )
        let manifest = BundleManifest(
            name: "frame",
            identifier: "org.lungfish.test.cds-frame",
            source: SourceInfo(organism: "Test", assembly: "frame"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(chromosomes.reduce(0) { $0 + $1.bases.count }), chromosomes: infos
            ),
            annotations: [
                AnnotationTrackInfo(id: frameTrackID, name: "CDS", path: "annotations/cds.bb", databasePath: "annotations/cds.db"),
            ],
            variants: []
        )
        try manifest.save(to: folder)
        return ReferenceBundle(url: folder, manifest: try BundleManifest.load(from: folder))
    }

    /// The bundle of the three chromosomes and `frameGFF3`, imported with no chromosome sizes.
    func frameBundle() async throws -> ReferenceBundle {
        let root = deepRoot("cds-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try await Self.makeFrameBundle(
            root, chromosomes: [("chrF", Self.chrFBases), ("chrM", Self.chrMBases), ("chrR", Self.chrRBases)],
            gff: Self.frameGFF3, sizes: nil
        )
    }

    /// One SNP row of a variant track at the 1-based `position`.
    static func snp(_ chromosome: String, _ position: Int, _ ref: String, _ alt: String) -> AnnotationSearchResult {
        AnnotationSearchResult(
            name: "\(chromosome):\(position)", chromosome: chromosome, start: position - 1, end: position,
            trackId: "calls", type: "SNP", ref: ref, alt: alt
        )
    }

    /// Side C's Coding Feature, Consequence and AA Change cells of `row`, from the leaf's bundle read.
    static func leafCells(_ bundle: ReferenceBundle, _ row: AnnotationSearchResult) throws -> [String] {
        let fields = try VariantTableBundleCodingFeatures.resolver(
            bundle: bundle, trackIDs: VariantTableBundleCodingFeatures.trackIDs(bundle: bundle), rows: [row],
            variantChromosomeAliasMap: [:]
        ).resolve(row)
        return [fields.codingFeature, fields.consequence, fields.aaChange]
    }

    /// Side A's cells of `row`. The viewer holds the bundle and every annotation track over the row's chromosome with
    /// `annotation_db_track_id` set, as `fetchAnnotationsAsync` caches them, and builds each CDS's context with
    /// `cdsCodingContext(for:)` before the table's resolver reads them.
    static func viewerCells(_ bundle: ReferenceBundle, _ row: AnnotationSearchResult) throws -> [String] {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        viewer.setReferenceBundle(bundle)
        let length = Int(try XCTUnwrap(bundle.chromosome(named: row.chromosome)).length)
        var annotations: [SequenceAnnotation] = []
        for trackID in bundle.annotationTrackIds {
            var read = try bundle.getAnnotationsSync(
                trackId: trackID, region: GenomicRegion(chromosome: row.chromosome, start: 0, end: length)
            )
            for index in read.indices {
                read[index].qualifiers["annotation_db_track_id"] = AnnotationQualifier(trackID)
            }
            annotations += read
        }
        viewer.cachedBundleAnnotations = annotations
        for cds in annotations where cds.type == .cds {
            XCTAssertNotNil(viewer.cdsCodingContext(for: cds), "the viewer reads a context for \(cds.name)")
        }
        let fields = try viewer.variantTableExportResolverSnapshot().preparingForBackgroundExport().resolve(row)
        return [fields.codingFeature, fields.consequence, fields.aaChange]
    }

    /// Item 2. `chrM:6 C>A` makes codon 2 AGC into AGA, which `transl_table=2` reads as a stop, S2*, stop gained. The
    /// standard code, which the base uses, reads Arg, S2R, a missense change.
    func testNonStandardTableCDSUsesItsTranslationTable() async throws {
        let bundle = try await frameBundle()
        let row = Self.snp("chrM", 6, "C", "A")
        let expected = ["m", "m: stop_gained S2*", "S2*"]
        XCTAssertEqual(try Self.leafCells(bundle, row), expected, "side C translates with table 2")
        XCTAssertEqual(try Self.viewerCells(bundle, row), expected, "side A translates with table 2")
    }

    /// Item 3 (BIO). `chrM:9 G>A` makes codon 3 TGG into TGA, which table 2 reads as Trp, W3W, synonymous. The
    /// standard code reads a stop, W3*.
    func testAMitochondrialCDSUsesItsCodonTable() async throws {
        let bundle = try await frameBundle()
        let row = Self.snp("chrM", 9, "G", "A")
        let expected = ["m", "m: synonymous_variant W3W", "W3W"]
        XCTAssertEqual(try Self.leafCells(bundle, row), expected, "side C translates with table 2")
        XCTAssertEqual(try Self.viewerCells(bundle, row), expected, "side A translates with table 2")
    }
}
