import AppKit
import XCTest
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeKnownAlleleDetailViewTests: XCTestCase {
    func testConfigureStartsInOverviewAndShowsOnlyKnownAlleleContext() throws {
        let view = makeView()

        view.configure(record: makeRecord(), observedSample: "CR1178")

        XCTAssertEqual(view.currentMode, .overview)
        XCTAssertEqual(try segmentedControl(in: view).selectedSegment, 0)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: view), "Mafa-A1*063:01")
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: view), "NHP0068")
        XCTAssertEqual(text("knownAlleleLocus", in: view), "Mafa-A1")
        XCTAssertEqual(text("knownAlleleSequenceLength", in: view), "24 bp")
        XCTAssertEqual(text("knownAlleleRoles", in: view), "Exact known call")
        XCTAssertEqual(text("knownAlleleObservedSample", in: view), "Observed in sample CR1178")

        let forbidden = [
            "Unique Reads", "Alignments", "Support", "Anchor",
            "Co-occurrence", "Supporting Samples",
        ]
        let visibleText = textFields(in: view).map(\.stringValue).joined(separator: "\n")
        for phrase in forbidden {
            XCTAssertFalse(visibleText.localizedCaseInsensitiveContains(phrase), phrase)
        }
    }

    func testOverviewProvidesSequenceAndIntervalLevelAnnotationLanes() throws {
        let view = makeView()
        view.configure(record: makeRecord(), observedSample: nil)

        let ruler = try identifiedView("knownAlleleCoordinateRuler", in: view)
        let nucleotideStrip = try identifiedView("knownAlleleNucleotideStrip", in: view)
        XCTAssertEqual(ruler.accessibilityValue() as? String, "1–24")
        XCTAssertEqual(nucleotideStrip.accessibilityValue() as? String, "ACGTACGTACGTACGTACGTACGT")
        XCTAssertGreaterThan(nucleotideStrip.frame.width, 400)

        XCTAssertEqual(try lane("gene", in: view).subviews.count, 1)
        XCTAssertEqual(try lane("CDS", in: view).subviews.count, 2)
        XCTAssertEqual(try lane("exon", in: view).subviews.count, 2)
        XCTAssertEqual(try lane("translation", in: view).subviews.count, 1)

        let joinedCDSBlocks = try lane("CDS", in: view).subviews
        XCTAssertNotEqual(
            joinedCDSBlocks[0].accessibilityIdentifier(),
            joinedCDSBlocks[1].accessibilityIdentifier()
        )
        XCTAssertEqual(
            joinedCDSBlocks[0].accessibilityLabel(),
            joinedCDSBlocks[1].accessibilityLabel()
        )
        XCTAssertEqual(joinedCDSBlocks[0].accessibilityLabel(), "CDS 2")
    }

    func testEmptyAnnotationsRemainSequenceOnlyWithoutSynthesizedFeatures() throws {
        let view = makeView()
        view.configure(
            record: makeRecord(features: [], annotatedTranslation: nil),
            observedSample: nil
        )

        XCTAssertEqual(try lane("gene", in: view).subviews.count, 0)
        XCTAssertEqual(try lane("CDS", in: view).subviews.count, 0)
        XCTAssertEqual(try lane("exon", in: view).subviews.count, 0)
        XCTAssertEqual(try lane("translation", in: view).subviews.count, 0)
        XCTAssertNotNil(find("knownAlleleCoordinateRuler", in: view))
        XCTAssertNotNil(find("knownAlleleNucleotideStrip", in: view))
    }

    func testSegmentAndFactsActionsShowExactSelectableFullWidthText() throws {
        let view = makeView()
        let record = makeRecord()
        view.configure(record: record, observedSample: "CR1178")
        let modeControl = try segmentedControl(in: view)

        select(segment: 1, in: modeControl)

        XCTAssertEqual(view.currentMode, .genBank)
        let genBank = try XCTUnwrap(find("knownAlleleGenBankTextView", in: view) as? NSTextView)
        XCTAssertEqual(genBank.string, record.genBankText)
        XCTAssertFalse(genBank.isEditable)
        XCTAssertTrue(genBank.isSelectable)
        XCTAssertNil(find("knownAlleleFactsRail", in: view))
        XCTAssertEqual(try visibleScrollView(in: view).frame.width, view.bounds.width, accuracy: 0.5)

        select(segment: 0, in: modeControl)
        let fastaButton = try XCTUnwrap(find("knownAlleleShowFASTAButton", in: view) as? NSButton)
        fastaButton.performClick(nil)

        XCTAssertEqual(view.currentMode, .fasta)
        let fasta = try XCTUnwrap(find("knownAlleleFASTATextView", in: view) as? NSTextView)
        XCTAssertEqual(fasta.string, record.fastaText)
        XCTAssertFalse(fasta.isEditable)
        XCTAssertTrue(fasta.isSelectable)
        XCTAssertNil(find("knownAlleleFactsRail", in: view))
        XCTAssertEqual(try visibleScrollView(in: view).frame.width, view.bounds.width, accuracy: 0.5)

        select(segment: 0, in: modeControl)
        let genBankButton = try XCTUnwrap(find("knownAlleleShowGenBankButton", in: view) as? NSButton)
        genBankButton.performClick(nil)
        XCTAssertEqual(view.currentMode, .genBank)
    }

    func testReconfigureResetsModeUpdatesContentAndDoesNotGrowHierarchy() throws {
        let view = makeView()
        view.configure(record: makeRecord(), observedSample: "CR1178")
        select(segment: 2, in: try segmentedControl(in: view))

        let replacement = makeRecord(
            rawReferenceID: "NHP0099",
            alleleName: "Mafa-B*099:02",
            locus: "Mafa-B",
            sequence: "AACCGGTT",
            features: [feature(type: "gene", start: 0, end: 8, sourceOrdinal: 9)],
            annotatedTranslation: nil,
            genBankText: "LOCUS       NHP0099 8 bp DNA\n//\n",
            fastaText: ">NHP0099 Mafa-B*099:02\nAACCGGTT\n"
        )
        view.configure(record: replacement, observedSample: "CR2000")
        let countAfterReplacement = descendants(of: view).count
        view.configure(record: replacement, observedSample: "CR2000")

        XCTAssertEqual(view.currentMode, .overview)
        XCTAssertEqual(try segmentedControl(in: view).selectedSegment, 0)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: view), "Mafa-B*099:02")
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: view), "NHP0099")
        XCTAssertEqual(text("knownAlleleObservedSample", in: view), "Observed in sample CR2000")
        XCTAssertFalse(textFields(in: view).contains { $0.stringValue.contains("CR1178") })
        XCTAssertEqual(descendants(of: view).count, countAfterReplacement)
        XCTAssertEqual(try lane("gene", in: view).subviews.count, 1)
        XCTAssertEqual(try lane("CDS", in: view).subviews.count, 0)
    }

    func testFallbackShowsCompactMetadataAndFreshAnalysisRequirement() throws {
        let view = makeView()

        view.configureFallback(
            alleleName: "Mafa-DPB1*01:01",
            rawReferenceID: "legacy_DPB1_01",
            fields: [("Locus", "Mafa-DPB1"), ("Definition", "Legacy reference")],
            observedSample: "CR1178"
        )

        XCTAssertEqual(text("knownAlleleAlleleLabel", in: view), "Mafa-DPB1*01:01")
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: view), "legacy_DPB1_01")
        XCTAssertEqual(text("knownAlleleObservedSample", in: view), "Observed in sample CR1178")
        XCTAssertTrue(textFields(in: view).contains { $0.stringValue == "Locus: Mafa-DPB1" })
        XCTAssertTrue(textFields(in: view).contains { $0.stringValue == "Definition: Legacy reference" })
        XCTAssertEqual(
            text("knownAlleleFallbackNote", in: view),
            "A fresh analysis is required to generate graphical reference records."
        )
        XCTAssertNil(find("knownAlleleOverview", in: view))
        XCTAssertNil(find("knownAlleleFactsRail", in: view))

        let visibleText = textFields(in: view).map(\.stringValue).joined(separator: "\n")
        for phrase in ["Unique Reads", "Alignments", "Support", "Anchor", "Co-occurrence"] {
            XCTAssertFalse(visibleText.localizedCaseInsensitiveContains(phrase), phrase)
        }
    }

    private func makeView() -> GenotypeKnownAlleleDetailView {
        let view = GenotypeKnownAlleleDetailView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func makeRecord(
        rawReferenceID: String = "NHP0068",
        alleleName: String = "Mafa-A1*063:01",
        locus: String? = "Mafa-A1",
        sequence: String = "ACGTACGTACGTACGTACGTACGT",
        features: [ONTMHCReferenceVisualizationFeature]? = nil,
        annotatedTranslation: String? = "MKTWQ",
        genBankText: String = "LOCUS       NHP0068 24 bp DNA\nFEATURES             Location/Qualifiers\n//\n",
        fastaText: String = ">NHP0068 Mafa-A1*063:01\nACGTACGTACGTACGTACGTACGT\n"
    ) -> ONTMHCReferenceVisualizationRecord {
        ONTMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            sourceOrdinal: 1,
            alleleName: alleleName,
            locus: locus,
            sequence: sequence,
            sequenceSHA256: "test-checksum",
            recordFields: ["definition": ["MHC class I allele"]],
            features: features ?? [
                feature(type: "gene", start: 0, end: 24, sourceOrdinal: 1),
                feature(type: "CDS", start: 2, end: 10, sourceOrdinal: 2),
                feature(type: "CDS", start: 14, end: 22, sourceOrdinal: 2),
                feature(type: "exon", start: 2, end: 10, sourceOrdinal: 3),
                feature(type: "exon", start: 14, end: 22, sourceOrdinal: 4),
            ],
            annotatedTranslation: annotatedTranslation,
            genBankText: genBankText,
            fastaText: fastaText,
            roles: [
                ONTMHCReferenceVisualizationRoleAssignment(
                    role: .exactKnownCall,
                    candidateStableClusterIDs: []
                )
            ]
        )
    }

    private func feature(
        type: String,
        start: Int,
        end: Int,
        sourceOrdinal: Int
    ) -> ONTMHCReferenceVisualizationFeature {
        ONTMHCReferenceVisualizationFeature(
            type: type,
            start: start,
            end: end,
            strand: "+",
            sourceOrdinal: sourceOrdinal,
            rawGenBankLocation: "\(start + 1)..\(end)",
            qualifiers: [:]
        )
    }

    private func segmentedControl(in view: NSView) throws -> NSSegmentedControl {
        try XCTUnwrap(find("knownAlleleModeControl", in: view) as? NSSegmentedControl)
    }

    private func lane(_ name: String, in view: NSView) throws -> NSView {
        try identifiedView("knownAllele\(name)Lane", in: view)
    }

    private func identifiedView(_ identifier: String, in view: NSView) throws -> NSView {
        try XCTUnwrap(find(identifier, in: view), "Missing view with accessibility identifier \(identifier)")
    }

    private func find(_ identifier: String, in root: NSView) -> NSView? {
        ([root] + descendants(of: root)).first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func textFields(in root: NSView) -> [NSTextField] {
        descendants(of: root).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
    }

    private func text(_ identifier: String, in root: NSView) -> String? {
        (find(identifier, in: root) as? NSTextField)?.stringValue
    }

    private func select(segment: Int, in control: NSSegmentedControl) {
        control.selectedSegment = segment
        control.sendAction(control.action, to: control.target)
    }

    private func visibleScrollView(in root: NSView) throws -> NSScrollView {
        try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
    }
}
