// AnnotationTableExportCLIGUIParityReplayTests+CDSShapes.swift - The CDS shapes of the variant table's derived columns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.38 M1 (rows M854 and M863, BIO ruling on M854 items 1 to 5). At the base the leaf reads the CDS
// of the selection's region only, so each case here writes the region the viewer caches while it shows `chr2`, names
// both annotation tracks, and proves the leaf (side C) equal to the viewer (side A) on one shape of CDS-EDGE-PARITY,
// with the cells pinned as literals worked out by hand from `chr2Genome`. No case puts a CDS on `chr1`, so the pins
// of `testDerivedColumnsAndOverlayMatch` keep their bytes.

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
    static let cds2TrackID = "cds2"

    /// One iVar call of the second bundle, its 1-based POS first.
    typealias DerivedCall = (position: Int, ref: String, alt: String, type: String, depth: Int, frequency: String)

    /// `chr2` of the second bundle, 90 bases, here by 0-based start. [0,2) CC, [2,17) ATGGCATGGAACTCC,
    /// [17,36) GATCGTAGCTAGGTCAGCA, [36,39) TTC, [39,48) GCAGATCTT, [48,50) AA, [50,62) GGATCCAAGCTT,
    /// [62,70) TTAACCGG, [70,90) ATGCCATTGACGTAGCCATG.
    static let chr2Genome = [
        "CC", "ATGGCATGGAACTCC", "GATCGTAGCTAGGTCAGCA", "TTC", "GCAGATCTT", "AA", "GGATCCAAGCTT", "TTAACCGG",
        "ATGCCATTGACGTAGCCATG",
    ].joined()
    /// `chr2` follows `>chr1\n`, chr1's 120 bases and a newline, and `>chr2\n`, so its bases start at byte 133.
    static let chr2Info = ChromosomeInfo(name: "chr2", length: 90, offset: 133, lineBases: 90, lineWidth: 91)
    static let chr2IndexLine = "chr2\t90\t133\t90\t91\n"

    /// The `chr2` CDS of the track `cds`. `ovA` is [6,36) on the forward strand.
    static let chr2CDSLines = "chr2\t6\t36\tovA\t0\t+\t6\t36\t0,0,0\t1\t30\t0\tCDS\tgene=geneA\n"
    /// The CDS of the track `cds2`, which follows `cds` in the manifest. `ovB` is [2,32) on the forward strand, so it
    /// starts before `ovA`, and their frames differ by (6 - 2) mod 3 = 1.
    static let chr2CDS2Lines = "chr2\t2\t32\tovB\t0\t+\t2\t32\t0,0,0\t1\t30\t0\tCDS\tgene=geneB\n"
    /// The `chr2` calls of the iVar track. POS 15 (base 14) lies under `ovA` and `ovB`.
    static let chr2Calls: [DerivedCall] = [(15, "T", "G", "SNP", 60, "0.5")]

    /// The region the viewer caches while it shows `chr2`, the visible span widened by at least 50,000 bases on each
    /// side and clamped to the chromosome (`SequenceViewerView+Rendering.swift:912-917`), so all of `chr2`.
    static let chr2CachedRegion = GenomicRegion(chromosome: "chr2", start: 0, end: 90)
    /// The sequence window the viewer holds. It covers `ovA` and `ovB` and stops before base 65.
    static let chr2CachedWindow = GenomicRegion(chromosome: "chr2", start: 0, end: 65)

    /// Side A's features while the viewer shows `chr2`, read as `fetchAnnotationsAsync` caches them
    /// (`SequenceViewerView+Rendering.swift:917-950`), every annotation track in manifest order over the cached region
    /// with `annotation_db_track_id` set, and each CDS's context built as `cdsCodingContext(for:)` builds it. The
    /// region names the tracks of those qualifiers, sorted, as `variantTableExportResolverSnapshot()` names them
    /// (`SequenceViewerView+CodingFeatureLabels.swift:46-52`). Side A does not call the leaf's read.
    static func chr2ViewerFeatures(
        bundle: ReferenceBundle
    ) throws -> (features: [VariantTableExportResolverSnapshot.CodingFeature], region: AnnotationTableFeatureRegion) {
        var annotations: [SequenceAnnotation] = []
        for trackID in bundle.annotationTrackIds {
            var read = try bundle.getAnnotationsSync(trackId: trackID, region: chr2CachedRegion)
            for index in read.indices {
                read[index].qualifiers["annotation_db_track_id"] = AnnotationQualifier(trackID)
            }
            annotations += read
        }
        var features: [VariantTableExportResolverSnapshot.CodingFeature] = []
        for annotation in annotations where annotation.type == .cds {
            let context = try viewerCodingContext(annotation, bundle: bundle)
            features += VariantTableCodingFeatures.features(
                annotations: [annotation], fallbackChromosome: chr2CachedRegion.chromosome,
                chromosomeName: { bundle.chromosome(named: $0)?.name ?? $0 }, context: { _ in Optional(context) }
            )
        }
        let trackIDs = Set(annotations.compactMap { $0.qualifier("annotation_db_track_id") }).sorted()
        let region = AnnotationTableFeatureRegion(
            chromosome: chr2CachedRegion.chromosome, start: chr2CachedRegion.start, end: chr2CachedRegion.end, trackIDs: trackIDs
        )
        return (features, region)
    }

    /// The context `cdsCodingContext(for:)` builds (`SequenceViewerView+Tooltips.swift:620-656`). A segment comes from
    /// the cached window when the window holds all of it and otherwise from `ClampedSequenceProvider(bundle:)`,
    /// `TranslationEngine.codingLayout` finds the frame, no base count is checked, and the code is `.standard`. A CDS
    /// with no layout throws, so it cannot fall back to the leaf's own derivation without a sign.
    static func viewerCodingContext(
        _ annotation: SequenceAnnotation, bundle: ReferenceBundle
    ) throws -> VariantTableCodingFeatures.Context {
        let chromosome = try XCTUnwrap(annotation.chromosome)
        let window = chr2CachedWindow
        let cached = try bundle.fetchSequenceSync(region: window)
        let sequenceProvider: (Int, Int) -> String? = { start, end in
            guard start < end else { return nil }
            if window.chromosome == chromosome, start >= window.start, end <= window.end {
                let lower = cached.index(cached.startIndex, offsetBy: start - window.start)
                let upper = cached.index(cached.startIndex, offsetBy: end - window.start)
                return String(cached[lower..<upper])
            }
            return ClampedSequenceProvider(bundle: bundle).bases(chromosome: chromosome, start: start, end: end)
        }
        let layout = try XCTUnwrap(
            TranslationEngine.codingLayout(annotation: annotation, segmentProvider: { start, end in
                sequenceProvider(start, end).map { TranslationEngine.SegmentRead(start: start, sequence: $0) }
            }),
            "the viewer reads a layout for \(annotation.name)"
        )
        return (
            codingBases: Array(layout.codingSequence.uppercased()), codingGenomePositions: layout.genomicPositions,
            phaseOffset: layout.phaseOffset, codonTable: .standard, codonsBeforeFirstRead: layout.codonsBeforeFirstRead
        )
    }

    /// The Gene / Protein, Consequence and AA Change cells of the `chr2` row `ref>alt` in side C's TSV.
    static func chr2DerivedCells(_ ref: String, _ alt: String, _ runs: RouteParityRuns) throws -> [String] {
        let text = try String(contentsOf: outputURL(in: runs.c.root, .tsv), encoding: .utf8)
        let rows = text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let row = try XCTUnwrap(
            rows.first { $0.count == derivedVariantColumns.count && $0[1] == "chr2" && $0[3] == ref && $0[4] == alt },
            "the chr2 row \(ref)>\(alt) is in the table\n\(text)"
        )
        return Array(row.suffix(3))
    }

    /// BIO ruling on M854 item 2, shape (c). `ovA` of the track `cds` and `ovB` of `cds2` share base 14 in different
    /// frames. In `ovB` ([2,32)) base 14 opens codon 5, [14,17) TCC (Ser), which T>G makes GCC (Ala), S5A missense. In
    /// `ovA` ([6,36)) it closes codon 3, [12,15) ACT (Thr), which T>G makes ACG (Thr), T3T synonymous. Each cell lists
    /// `cds` before `cds2`, the manifest's order, though `ovB` starts first, and A equals C.
    func testOverlappingCDSKeepTrackOrder() async throws {
        let runs = try await assertParity(Case(tab: .variants, format: .tsv, derived: true, addsChr2: true))
        XCTAssertEqual(try Self.chr2DerivedCells("T", "G", runs), [
            "geneA • ovA; geneB • ovB",
            "geneA • ovA: synonymous_variant T3T; geneB • ovB: missense_variant S5A",
            "geneA • ovA: T3T, geneB • ovB: S5A",
        ])
    }
}
