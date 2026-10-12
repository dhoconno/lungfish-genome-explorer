// BundleTranslationClampTests.swift - The reader of reference bases that CDS translation and extraction share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

/// Phase 2.8 lane B6, decision G1.
///
/// A reference bundle refuses a read that runs past the end of a chromosome, and the five bundle closures
/// of the viewer, the Inspector, the extraction commands and the hover text turned the refusal into nil, so a
/// reverse-strand CDS that ran past the end lost the whole segment. `ClampedSequenceProvider` clamps the range
/// first and keeps the bases that exist, and `TranslationEngine` moves the frame by the bases that are missing.
///
/// The bundle has one 120 base chromosome. A reverse-strand CDS at [100,130) holds M A K R W H E F P D, and the
/// chromosome ends at 120, so the 10 bases at the 5' end of the CDS are missing.
@MainActor
final class BundleTranslationClampTests: XCTestCase {

    // MARK: - Fixtures

    private static let codingBases: [Character] = Array(
        ["ATG", "GCT", "AAA", "CGT", "TGG", "CAT", "GAA", "TTC", "CCG", "GAT", "CAG", "TAC", "GGT", "AGC"].joined()
    )

    private func coding(_ range: Range<Int>) -> String {
        String(Self.codingBases[range])
    }

    private func plusStrand(ofCoding range: Range<Int>) -> String {
        TranslationEngine.reverseComplement(coding(range))
    }

    /// The bases of chr1: 100 N and then the plus strand of coding bases 10..<30.
    private var chromosome: String {
        String(repeating: "N", count: 100) + plusStrand(ofCoding: 10..<30)
    }

    private var clippedReverseCDS: SequenceAnnotation {
        SequenceAnnotation(
            type: .cds,
            name: "clipped",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 130, phase: 0)],
            strand: .reverse
        )
    }

    private func makeBundle() async throws -> ReferenceBundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LungfishTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Clamp.lungfishref", isDirectory: true)
        let genome = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try (">chr1\n" + chromosome + "\n").write(
            to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8
        )
        try "chr1\t120\t6\t120\t121\n".write(
            to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        try BundleManifest(
            formatVersion: "1.0",
            name: "Clamp",
            identifier: "test.clamp",
            source: SourceInfo(organism: "Test", assembly: "chr1", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 120,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 120, offset: 6, lineBases: 120, lineWidth: 121)]
            )
        ).save(to: bundleURL)
        return try await ReferenceBundle(url: bundleURL)
    }

    // MARK: - The reader

    /// This is why the closures lost the segment. The bundle throws for a range that runs past the end.
    func testTheBundleRefusesARangeThatRunsPastTheChromosomeEnd() async throws {
        let bundle = try await makeBundle()

        XCTAssertThrowsError(
            try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr1", start: 100, end: 130))
        )
        let unclamped = TranslationEngine.translateCDS(
            annotation: clippedReverseCDS,
            sequenceProvider: { start, end in
                try? bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr1", start: start, end: end))
            }
        )
        XCTAssertNil(unclamped, "the whole segment dropped, so there was nothing to translate")
    }

    func testAClampedReadKeepsTheBasesThatExist() async throws {
        let provider = ClampedSequenceProvider(bundle: try await makeBundle())
        let kept = String(chromosome.suffix(20))

        let segment = try XCTUnwrap(provider.segment(chromosome: "chr1", start: 100, end: 130))

        XCTAssertEqual(segment.start, 100)
        XCTAssertEqual(segment.sequence, kept)
        XCTAssertEqual(provider.bases(chromosome: "chr1", start: 100, end: 130), kept)
    }

    func testARangeThatStartsAtOrPastTheEndHasNoBases() async throws {
        let provider = ClampedSequenceProvider(bundle: try await makeBundle())

        XCTAssertNil(provider.segment(chromosome: "chr1", start: 120, end: 130))
        XCTAssertNil(provider.segment(chromosome: "chr1", start: 200, end: 230))
    }

    func testARangeInsideTheChromosomeReadsAsTheBundleReadsIt() async throws {
        let bundle = try await makeBundle()
        let provider = ClampedSequenceProvider(bundle: bundle)

        for (start, end) in [(0, 120), (10, 20), (100, 120), (119, 120)] {
            let direct = try bundle.fetchSequenceSync(region: GenomicRegion(chromosome: "chr1", start: start, end: end))
            let segment = try XCTUnwrap(provider.segment(chromosome: "chr1", start: start, end: end))
            XCTAssertEqual(segment.sequence, direct, "\(start)-\(end)")
            XCTAssertEqual(segment.start, start, "\(start)-\(end)")
        }
    }

    func testAnUnknownLengthPassesTheRangeThroughAsItWas() {
        let provider = ClampedSequenceProvider(extent: { _ in nil }, fetch: { _, _, _ in "ACGT" })

        let segment = provider.segment(chromosome: "chrX", start: 500, end: 504)

        XCTAssertEqual(segment, TranslationEngine.SegmentRead(start: 500, sequence: "ACGT"))
    }

    // MARK: - What the callers get

    func testAReverseCDSThatRunsPastTheChromosomeEndTranslatesInFrame() async throws {
        let provider = ClampedSequenceProvider(bundle: try await makeBundle())

        let fromBases = try XCTUnwrap(TranslationEngine.translateCDS(
            annotation: clippedReverseCDS,
            sequenceProvider: provider.basesProvider(chromosome: "chr1")
        ))
        let fromSegments = try XCTUnwrap(TranslationEngine.translateCDS(
            annotation: clippedReverseCDS,
            segmentProvider: provider.segmentProvider(chromosome: "chr1")
        ))

        for result in [fromBases, fromSegments] {
            XCTAssertEqual(result.phaseOffset, 2)
            XCTAssertEqual(result.protein, "WHEFPD")
            XCTAssertEqual(result.codingSequence, coding(10..<30))
        }
    }

    /// The extraction commands use `extractionProvider`, and the extractor attaches the protein.
    func testTheExtractionOfAClippedReverseCDSCarriesTheSameProtein() async throws {
        let provider = ClampedSequenceProvider(bundle: try await makeBundle())

        let result = try SequenceExtractor.extract(
            request: ExtractionRequest.defaultAnnotationRequest(for: clippedReverseCDS),
            sequenceProvider: provider.extractionProvider,
            chromosomeLength: 120
        )

        XCTAssertEqual(result.nucleotideSequence, coding(10..<30))
        XCTAssertEqual(result.proteinSequence, "WHEFPD")
    }

    // MARK: - The five bundle closures

    private func makeViewer(with bundle: ReferenceBundle) -> SequenceViewerView {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        viewer.setReferenceBundle(bundle)
        return viewer
    }

    /// Closure 1, the viewer's CDS translation track.
    func testTheViewerShowsTheTranslationOfAClippedReverseCDS() async throws {
        let viewer = makeViewer(with: try await makeBundle())

        viewer.showCDSTranslation(for: clippedReverseCDS)

        XCTAssertEqual(viewer.activeTranslationResult?.protein, "WHEFPD")
    }

    /// Closure 2, the Inspector's translation of the selected CDS.
    func testTheInspectorTranslatesAClippedReverseCDS() async throws {
        let model = SelectionSectionViewModel()
        model.referenceBundle = try await makeBundle()

        XCTAssertEqual(model.computeTranslation(for: clippedReverseCDS), "WHEFPD")
    }

    /// Closures 3 and 4, the two providers the extraction commands pass to the extractor.
    func testTheExtractionProvidersOfTheViewerClampToTheChromosome() async throws {
        let viewer = makeViewer(with: try await makeBundle())
        let kept = String(chromosome.suffix(20))
        let forAnnotation = try XCTUnwrap(viewer.makeSequenceProvider(for: clippedReverseCDS))

        XCTAssertEqual(forAnnotation("chr1", 100, 130), kept)
        XCTAssertEqual(viewer.makeRegionSequenceProvider()("chr1", 100, 130), kept)

        let result = try SequenceExtractor.extract(
            request: ExtractionRequest.defaultAnnotationRequest(for: clippedReverseCDS),
            sequenceProvider: forAnnotation,
            chromosomeLength: 120
        )
        XCTAssertEqual(result.nucleotideSequence, coding(10..<30))
        XCTAssertEqual(result.proteinSequence, "WHEFPD")
    }

    /// Closure 5, the coding context behind the variant hover text. It reads the bases that exist and takes
    /// the frame from the same rule as the translation.
    func testTheHoverCodingContextOfAClippedReverseCDSKeepsItsFrame() async throws {
        let viewer = makeViewer(with: try await makeBundle())

        let context = try XCTUnwrap(viewer.cdsCodingContext(for: clippedReverseCDS))

        XCTAssertEqual(String(context.codingBases), coding(10..<30))
        XCTAssertEqual(context.codingGenomePositions, Array((100..<120).reversed()))
        XCTAssertEqual(context.phaseOffset, 2)
    }

    /// A GenBank import records the phase on the 5'-most segment, which is the highest one on the reverse
    /// strand. The hover context used the lowest segment, which has none.
    func testTheHoverCodingContextOfAReverseCDSTakesItsPhaseFromTheFivePrimeSegment() async throws {
        let viewer = makeViewer(with: try await makeBundle())
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "two-segments",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 10, end: 25),
                AnnotationInterval(start: 60, end: 90, phase: 1)
            ],
            strand: .reverse
        )

        let context = try XCTUnwrap(viewer.cdsCodingContext(for: annotation))

        XCTAssertEqual(context.phaseOffset, 1)
        XCTAssertEqual(context.codingGenomePositions.first, 89)
        XCTAssertEqual(context.codingGenomePositions.count, 45)
    }

    // MARK: - Residue numbers

    /// A residue is numbered in the whole protein, not from the first codon that was read. The chromosome ends at
    /// 120, so the first 10 coding bases are missing and the first whole codon read, W, is residue 5 of
    /// M A K R W H E F P D.
    func testTheTableConsequenceOfAClippedReverseCDSNumbersTheResidueInTheWholeProtein() async throws {
        let viewer = makeViewer(with: try await makeBundle())
        viewer.cachedBundleAnnotations = [clippedReverseCDS]

        let predicted = viewer.fallbackConsequenceForTableVariant(
            chromosome: "chr1", position: 117, ref: "A", alt: "G"
        )

        XCTAssertEqual(predicted.aaChange, "W5R")
        XCTAssertTrue(
            try XCTUnwrap(predicted.consequence).hasSuffix("missense_variant W5R"),
            "\(String(describing: predicted.consequence))"
        )
    }

    // MARK: - A window onto part of a chromosome

    /// The viewer's cached window cuts a CDS at either end, so it reports where its bases start. A window that
    /// starts inside a reverse-strand CDS cuts the 3' end and leaves the frame alone.
    func testTheWindowReaderReportsWhereItsBasesStart() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "reverse-window",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 142, phase: 0)],
            strand: .reverse
        )
        let bases = plusStrand(ofCoding: 0..<32) + String(repeating: "N", count: 8)
        let provider = ClampedSequenceProvider(
            window: bases,
            region: GenomicRegion(chromosome: "chr1", start: 110, end: 150)
        )

        let segment = try XCTUnwrap(provider.segment(chromosome: "chr1", start: 100, end: 142))
        XCTAssertEqual(segment.start, 110)
        XCTAssertEqual(segment.sequence.count, 32)

        let result = try XCTUnwrap(TranslationEngine.translateCDS(
            annotation: annotation,
            segmentProvider: provider.segmentProvider(chromosome: "chr1")
        ))
        XCTAssertEqual(result.phaseOffset, 0)
        XCTAssertEqual(result.protein, "MAKRWHEFPD")
    }

    /// A window that ends inside a reverse-strand CDS cuts its 5' end.
    func testTheWindowReaderMovesTheFrameWhenItCutsTheFivePrimeEnd() throws {
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "reverse-window",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 142, phase: 0)],
            strand: .reverse
        )
        let bases = String(repeating: "N", count: 10) + plusStrand(ofCoding: 17..<42)
        let provider = ClampedSequenceProvider(
            window: bases,
            region: GenomicRegion(chromosome: "chr1", start: 90, end: 125)
        )

        let result = try XCTUnwrap(TranslationEngine.translateCDS(
            annotation: annotation,
            segmentProvider: provider.segmentProvider(chromosome: "chr1")
        ))

        XCTAssertEqual(result.phaseOffset, 1)
        XCTAssertEqual(result.protein, "EFPDQYGS")
    }
}
