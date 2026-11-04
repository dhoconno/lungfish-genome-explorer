// ClampedTranslationReadingTests.swift - A translation that a sequence end clips, or a read that fails, says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishKit
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

/// Phase 3.2 row FASTA-CLAMPED-TRUNCATED.
///
/// A translation over a CDS that a sequence end clips gave a shorter protein, and a read that failed gave no
/// protein, both with no words on the Inspector, the viewer track and the hover. `TranslationEngine` keeps the
/// frame, so its result now says how many of the annotation's bases were read, and each route says it where the
/// protein is read. The letters of the protein do not change.
///
/// The bundle has one 120 base chromosome. A reverse-strand CDS at [100,130) names 30 bases and the chromosome ends
/// at 120, so 20 are read and the protein is W H E F P D (`BundleTranslationClampTests` pins the letters).
@MainActor
final class ClampedTranslationReadingTests: XCTestCase {

    // MARK: - Fixtures

    private static let codingBases: [Character] = Array(
        ["ATG", "GCT", "AAA", "CGT", "TGG", "CAT", "GAA", "TTC", "CCG", "GAT", "CAG", "TAC", "GGT", "AGC"].joined()
    )

    /// The bases of chr1: 100 N and then the plus strand of coding bases 10..<30.
    private var chromosome: String {
        String(repeating: "N", count: 100) + TranslationEngine.reverseComplement(String(Self.codingBases[10..<30]))
    }

    /// Names 30 bases, and the chromosome holds 20 of them.
    private var clipped: SequenceAnnotation {
        SequenceAnnotation(
            type: .cds, name: "clipped", chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 130, phase: 0)], strand: .reverse
        )
    }

    /// Names 20 bases, and the chromosome holds all of them.
    private var whole: SequenceAnnotation {
        SequenceAnnotation(
            type: .cds, name: "whole", chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 120, phase: 0)], strand: .reverse
        )
    }

    private func makeBundle(removingSequenceFile: Bool = false) async throws -> ReferenceBundle {
        let root = try TestTempDirectory.make(prefix: "clamped-translation-reading")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("Reading.lungfishref", isDirectory: true)
        let genome = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        try (">chr1\n" + chromosome + "\n").write(
            to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8
        )
        try "chr1\t120\t6\t120\t121\n".write(
            to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        try BundleManifest(
            formatVersion: "1.0",
            name: "Reading",
            identifier: "test.reading",
            source: SourceInfo(organism: "Test", assembly: "chr1", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 120,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 120, offset: 6, lineBases: 120, lineWidth: 121)]
            )
        ).save(to: bundleURL)
        let bundle = try await ReferenceBundle(url: bundleURL)
        if removingSequenceFile {
            try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("genome/sequence.fa"))
        }
        return bundle
    }

    private func makeViewer(with bundle: ReferenceBundle) -> SequenceViewerView {
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
        viewer.setReferenceBundle(bundle)
        return viewer
    }

    // MARK: - The engine's fact

    func testAnEndThatClipsTheCDSIsCountedAndTheProteinKeepsItsLetters() throws {
        let annotation = SequenceAnnotation(
            type: .cds, name: "forward", chromosome: "chr1",
            intervals: [AnnotationInterval(start: 0, end: 12, phase: 0)], strand: .forward
        )
        // The sequence ends after 8 bases, so the third codon is cut.
        let result = try XCTUnwrap(TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { start, end in
                let stop = min(end, 8)
                guard start < stop else { return nil }
                return String("ATGGCTAAACGT".dropFirst(start).prefix(stop - start))
            }
        ))

        XCTAssertEqual(result.protein, "MA")
        XCTAssertEqual(result.codingBasesRead, 8)
        XCTAssertEqual(result.annotatedCodingLength, 12)
        XCTAssertTrue(result.isClipped)
    }

    func testACDSThatIsReadWholeIsNotClipped() throws {
        let annotation = SequenceAnnotation(
            type: .cds, name: "forward", chromosome: "chr1",
            intervals: [AnnotationInterval(start: 0, end: 12, phase: 0)], strand: .forward
        )
        let result = try XCTUnwrap(TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { start, end in String("ATGGCTAAACGT".dropFirst(start).prefix(end - start)) }
        ))

        XCTAssertEqual(result.protein, "MAKR")
        XCTAssertEqual(result.codingBasesRead, 12)
        XCTAssertEqual(result.annotatedCodingLength, 12)
        XCTAssertFalse(result.isClipped)
    }

    /// An exon wholly past the end of the sequence has no bases, and the bases it names count as unread.
    func testAnExonBeyondTheSequenceEndCountsAsUnread() throws {
        let annotation = SequenceAnnotation(
            type: .cds, name: "two exons", chromosome: "chr1",
            intervals: [AnnotationInterval(start: 0, end: 6, phase: 0), AnnotationInterval(start: 20, end: 26, phase: 0)],
            strand: .forward
        )
        let result = try XCTUnwrap(TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: { start, _ in start == 0 ? "ATGGCT" : nil }
        ))

        XCTAssertEqual(result.protein, "MA")
        XCTAssertEqual(result.codingBasesRead, 6)
        XCTAssertEqual(result.annotatedCodingLength, 12)
        XCTAssertTrue(result.isClipped)
    }

    // MARK: - The Inspector

    func testTheInspectorSaysHowManyBasesWereReadWhenTheSequenceEndClipsTheCDS() async throws {
        let model = SelectionSectionViewModel()
        model.referenceBundle = try await makeBundle()

        XCTAssertEqual(model.computeTranslation(for: clipped), "WHEFPD")

        let notice = try XCTUnwrap(model.translationNotice)
        XCTAssertTrue(notice.contains("20 of its 30 coding bases"), notice)
    }

    /// A clip has two ordinary causes, a contig that really ends inside the gene and an annotation from another
    /// assembly of the reference. The notice ends with the step for the cause that a person can fix.
    func testTheInspectorNoticeSaysWhatToTryWhenTheSequenceEndClipsTheCDS() async throws {
        let model = SelectionSectionViewModel()
        model.referenceBundle = try await makeBundle()

        XCTAssertEqual(model.computeTranslation(for: clipped), "WHEFPD")

        let notice = try XCTUnwrap(model.translationNotice)
        XCTAssertTrue(notice.contains("same assembly"), notice)
    }

    func testTheInspectorShowsNoNoticeForACDSThatWasReadWhole() async throws {
        let model = SelectionSectionViewModel()
        model.referenceBundle = try await makeBundle()

        XCTAssertNotNil(model.computeTranslation(for: whole))

        XCTAssertNil(model.translationNotice)
    }

    func testTheInspectorSaysSoWhenTheBasesCouldNotBeRead() async throws {
        let model = SelectionSectionViewModel()
        model.referenceBundle = try await makeBundle(removingSequenceFile: true)

        XCTAssertNil(model.computeTranslation(for: clipped))

        let notice = try XCTUnwrap(model.translationNotice)
        XCTAssertTrue(notice.contains("could not read"), notice)
        XCTAssertTrue(notice.contains("\"clipped\""), notice)
    }

    // MARK: - The viewer track

    func testTheViewerTrackNamesHowManyBasesWereRead() async throws {
        let viewer = makeViewer(with: try await makeBundle())

        viewer.showCDSTranslation(for: clipped)

        let result = try XCTUnwrap(viewer.activeTranslationResult)
        XCTAssertEqual(TranslationTrackRenderer.label(for: result), "Translation (20 of 30 bases read)")
    }

    func testTheViewerSaysSoWhenTheBasesCouldNotBeRead() async throws {
        let viewer = makeViewer(with: try await makeBundle(removingSequenceFile: true))
        // The words go through `ViewerRefusalSeam`, so the recorder reads them and no alert opens in the tier.
        let recorder = ViewerRefusalWordsTests.Recorder()

        ViewerRefusalSeam.$presenter.withValue(recorder) {
            viewer.showCDSTranslation(for: clipped)
        }

        XCTAssertNil(viewer.activeTranslationResult)
        XCTAssertEqual(recorder.reports.count, 1, "one set of words, shown once")
        let report = try XCTUnwrap(recorder.reports.first)
        XCTAssertEqual(report.title, "Could not show the translation")
        XCTAssertTrue(report.whatHappened.contains("\"clipped\""), report.whatHappened)
    }

    // MARK: - The hover

    func testTheHoverSaysHowManyBasesWereReadWhenTheSequenceEndClipsTheCDS() async throws {
        let viewer = makeViewer(with: try await makeBundle())
        var details: [String] = []

        let context = viewer.cdsCodingContext(for: clipped, noting: &details)

        XCTAssertNotNil(context)
        XCTAssertEqual(details.count, 1)
        XCTAssertTrue(details.first?.contains("20 of 30 coding bases") ?? false, "\(details)")
    }

    func testTheHoverAddsNoLineForACDSThatWasReadWhole() async throws {
        let viewer = makeViewer(with: try await makeBundle())
        var details: [String] = []

        XCTAssertNotNil(viewer.cdsCodingContext(for: whole, noting: &details))

        XCTAssertTrue(details.isEmpty, "\(details)")
    }

    func testTheHoverSaysSoWhenTheBasesCouldNotBeRead() async throws {
        let viewer = makeViewer(with: try await makeBundle(removingSequenceFile: true))
        var details: [String] = []

        XCTAssertNil(viewer.cdsCodingContext(for: clipped, noting: &details))

        XCTAssertEqual(details.count, 1)
        XCTAssertTrue(details.first?.contains("could not be read") ?? false, "\(details)")
    }
}
