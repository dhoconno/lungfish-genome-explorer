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
        XCTAssertEqual(try modeButton("knownAlleleModeOverview", in: view).state, .on)
        XCTAssertEqual(try modeButton("knownAlleleModeGenBank", in: view).state, .off)
        XCTAssertEqual(try modeButton("knownAlleleModeFASTA", in: view).state, .off)
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
        XCTAssertEqual(try lane("translation", in: view).subviews.count, 2)

        let joinedCDSBlocks = try lane("CDS", in: view).subviews
        XCTAssertNotEqual(
            joinedCDSBlocks[0].accessibilityIdentifier(),
            joinedCDSBlocks[1].accessibilityIdentifier()
        )
        XCTAssertEqual(
            joinedCDSBlocks[0].accessibilityLabel(),
            joinedCDSBlocks[1].accessibilityLabel()
        )
        XCTAssertEqual(joinedCDSBlocks[0].accessibilityLabel(), "MHC class I antigen")
        XCTAssertTrue(joinedCDSBlocks[0].toolTip?.contains("3..10") == true)

        let geneBlock = try XCTUnwrap(lane("gene", in: view).subviews.first)
        XCTAssertEqual(geneBlock.accessibilityLabel(), "Mafa-A1")
        XCTAssertEqual(visibleBlockLabel(in: geneBlock), "Mafa-A1")

        let exonBlocks = try lane("exon", in: view).subviews
        XCTAssertEqual(exonBlocks.map { $0.accessibilityLabel() ?? "" }, ["Exon 2", "Exon 3"])
        XCTAssertEqual(exonBlocks.map(visibleBlockLabel), ["Exon 2", "Exon 3"])

        assertGeometry(of: joinedCDSBlocks, in: try lane("CDS", in: view))
        let translationBlocks = try lane("translation", in: view).subviews
        XCTAssertEqual(
            translationBlocks.map { $0.accessibilityLabel() ?? "" },
            ["MHC class I antigen", "MHC class I antigen"]
        )
        assertGeometry(of: translationBlocks, in: try lane("translation", in: view))
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

    func testModeAndFactsActionsShowExactSelectableFullWidthText() throws {
        let view = makeView()
        let record = makeRecord()
        view.configure(record: record, observedSample: "CR1178")

        try modeButton("knownAlleleModeGenBank", in: view).performClick(nil)

        XCTAssertEqual(view.currentMode, .genBank)
        XCTAssertEqual(try modeButton("knownAlleleModeOverview", in: view).state, .off)
        XCTAssertEqual(try modeButton("knownAlleleModeGenBank", in: view).state, .on)
        let genBank = try XCTUnwrap(find("knownAlleleGenBankTextView", in: view) as? NSTextView)
        XCTAssertEqual(genBank.string, record.genBankText)
        XCTAssertFalse(genBank.isEditable)
        XCTAssertTrue(genBank.isSelectable)
        XCTAssertNil(find("knownAlleleFactsRail", in: view))
        XCTAssertEqual(try visibleScrollView(in: view).frame.width, view.bounds.width, accuracy: 0.5)

        try modeButton("knownAlleleModeOverview", in: view).performClick(nil)
        XCTAssertEqual(view.currentMode, .overview)
        let fastaButton = try XCTUnwrap(find("knownAlleleShowFASTAButton", in: view) as? NSButton)
        fastaButton.performClick(nil)

        XCTAssertEqual(view.currentMode, .fasta)
        let fasta = try XCTUnwrap(find("knownAlleleFASTATextView", in: view) as? NSTextView)
        XCTAssertEqual(fasta.string, record.fastaText)
        XCTAssertFalse(fasta.isEditable)
        XCTAssertTrue(fasta.isSelectable)
        XCTAssertNil(find("knownAlleleFactsRail", in: view))
        XCTAssertEqual(try visibleScrollView(in: view).frame.width, view.bounds.width, accuracy: 0.5)

        try modeButton("knownAlleleModeOverview", in: view).performClick(nil)
        let genBankButton = try XCTUnwrap(find("knownAlleleShowGenBankButton", in: view) as? NSButton)
        genBankButton.performClick(nil)
        XCTAssertEqual(view.currentMode, .genBank)

        try modeButton("knownAlleleModeFASTA", in: view).performClick(nil)
        XCTAssertEqual(view.currentMode, .fasta)
        XCTAssertEqual(try modeButton("knownAlleleModeFASTA", in: view).state, .on)
    }

    func testReconfigureResetsModeUpdatesContentAndDoesNotGrowHierarchy() throws {
        let view = makeView()
        view.configure(record: makeRecord(), observedSample: "CR1178")
        try modeButton("knownAlleleModeFASTA", in: view).performClick(nil)

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
        XCTAssertEqual(try modeButton("knownAlleleModeOverview", in: view).state, .on)
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
                feature(
                    type: "gene",
                    start: 0,
                    end: 24,
                    sourceOrdinal: 1,
                    qualifiers: ["gene": ["Mafa-A1"]]
                ),
                feature(
                    type: "CDS",
                    start: 2,
                    end: 10,
                    sourceOrdinal: 2,
                    qualifiers: ["product": ["MHC class I antigen"]]
                ),
                feature(
                    type: "CDS",
                    start: 14,
                    end: 22,
                    sourceOrdinal: 2,
                    qualifiers: ["product": ["Conflicting duplicate interval label"]]
                ),
                feature(
                    type: "exon",
                    start: 2,
                    end: 10,
                    sourceOrdinal: 3,
                    qualifiers: ["exon_number": ["2"]]
                ),
                feature(
                    type: "exon",
                    start: 14,
                    end: 22,
                    sourceOrdinal: 4,
                    qualifiers: ["number": ["3"]]
                ),
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
        sourceOrdinal: Int,
        qualifiers: [String: [String]] = [:]
    ) -> ONTMHCReferenceVisualizationFeature {
        ONTMHCReferenceVisualizationFeature(
            type: type,
            start: start,
            end: end,
            strand: "+",
            sourceOrdinal: sourceOrdinal,
            rawGenBankLocation: "\(start + 1)..\(end)",
            qualifiers: qualifiers
        )
    }

    private func modeButton(_ identifier: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(find(identifier, in: view) as? NSButton)
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

    private func visibleBlockLabel(in block: NSView) -> String {
        descendants(of: block).compactMap { $0 as? NSTextField }.first { !$0.isHidden }?.stringValue ?? ""
    }

    private func assertGeometry(
        of blocks: [NSView],
        in lane: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard blocks.count == 2 else {
            XCTFail("Expected two interval blocks, found \(blocks.count)", file: file, line: line)
            return
        }
        let expectedWidth = lane.bounds.width * 8 / 24
        XCTAssertEqual(blocks[0].frame.minX, lane.bounds.width * 2 / 24, accuracy: 1, file: file, line: line)
        XCTAssertEqual(blocks[0].frame.width, expectedWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(blocks[1].frame.minX, lane.bounds.width * 14 / 24, accuracy: 1, file: file, line: line)
        XCTAssertEqual(blocks[1].frame.width, expectedWidth, accuracy: 1, file: file, line: line)
        XCTAssertGreaterThan(blocks[1].frame.minX - blocks[0].frame.maxX, 1, file: file, line: line)
    }

    private func visibleScrollView(in root: NSView) throws -> NSScrollView {
        try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
    }
}
