import AppKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeKnownAlleleDetailViewTests: XCTestCase {
    func testGenBankAndFASTATextTypographyScalesWithoutChangingReaderOrScientificState() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let record = makeRecord(
            genBankText: String(repeating: "LOCUS NHP0068\nFEATURES 1..24\n", count: 80),
            fastaText: ">NHP0068\n" + String(
                repeating: "ACGTACGTACGTACGTACGTACGTACGTACGT\n",
                count: 80
            )
        )
        let view = makeView()
        view.configure(record: record, observedSample: "CR1178")
        try modeButton("knownAlleleModeGenBank", in: view).performClick(nil)
        view.layoutSubtreeIfNeeded()
        let genBank = try XCTUnwrap(find("knownAlleleGenBankTextView", in: view) as? NSTextView)
        try modeButton("knownAlleleModeFASTA", in: view).performClick(nil)
        view.layoutSubtreeIfNeeded()
        let fasta = try XCTUnwrap(find("knownAlleleFASTATextView", in: view) as? NSTextView)
        try modeButton("knownAlleleModeGenBank", in: view).performClick(nil)
        view.layoutSubtreeIfNeeded()
        let genBankScroll = try XCTUnwrap(genBank.enclosingScrollView)
        let fastaScroll = try XCTUnwrap(fasta.enclosingScrollView)
        genBank.setSelectedRange(NSRange(location: 12, length: 9))
        fasta.setSelectedRange(NSRange(location: 9, length: 12))
        genBankScroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 24))
        fastaScroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 12))
        let baseline = try XCTUnwrap(genBank.font).pointSize
        let genBankIdentity = ObjectIdentifier(genBank)
        let fastaIdentity = ObjectIdentifier(fasta)
        let overviewConfigurationCount = view.testingOverviewConfigurationCount
        let scientificGeometry = view.testingScientificOverviewGeometry

        for preference in [
            ContentTextSizePreference.custom(90),
            .custom(150),
            .custom(200),
            .custom(150),
            .system,
            .custom(100),
        ] {
            settings.contentTextSizePreference = preference
            settings.save()
            if preference == .custom(150) {
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
            }
            view.layoutSubtreeIfNeeded()

            let expected = expectedSequencePointSize(
                baselineAtOneHundredPercent: baseline,
                preference: preference
            )
            XCTAssertEqual(genBank.font?.pointSize ?? 0, expected, accuracy: 0.01)
            XCTAssertEqual(fasta.font?.pointSize ?? 0, expected, accuracy: 0.01)
            XCTAssertEqual(genBank.string, record.genBankText)
            XCTAssertEqual(fasta.string, record.fastaText)
            XCTAssertEqual(genBank.selectedRange(), NSRange(location: 12, length: 9))
            XCTAssertEqual(fasta.selectedRange(), NSRange(location: 9, length: 12))
            XCTAssertEqual(genBankScroll.contentView.bounds.origin.y, 24, accuracy: 0.01)
            XCTAssertEqual(ObjectIdentifier(genBank), genBankIdentity)
            XCTAssertEqual(ObjectIdentifier(fasta), fastaIdentity)
            XCTAssertEqual(view.currentMode, .genBank)
            XCTAssertEqual(view.testingOverviewConfigurationCount, overviewConfigurationCount)
            XCTAssertEqual(view.testingScientificOverviewGeometry, scientificGeometry)
        }

        try modeButton("knownAlleleModeFASTA", in: view).performClick(nil)
        view.layoutSubtreeIfNeeded()
        fastaScroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 12))
        settings.contentTextSizePreference = .custom(200)
        settings.save()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fastaScroll.contentView.bounds.origin.y, 12, accuracy: 0.01)
        XCTAssertEqual(view.currentMode, .fasta)
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(fastaScroll.contentView.bounds.origin.y, 12, accuracy: 0.01)
        XCTAssertEqual(view.currentMode, .fasta)
    }

    func testContentTypographyScalesDetailTextWithoutReconfiguringScientificOverview() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let view = makeView()
        view.configure(record: makeRecord(), observedSample: "CR1178")
        let overviewConfigurationCount = view.testingOverviewConfigurationCount
        let baselineTitle = view.testingPrimaryContentFontPointSize
        let baselineScientificGeometry = view.testingScientificOverviewGeometry

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.testingPrimaryContentFontPointSize, baselineTitle * 2, accuracy: 0.01)
        XCTAssertEqual(view.testingOverviewConfigurationCount, overviewConfigurationCount)
        XCTAssertEqual(view.testingScientificOverviewGeometry, baselineScientificGeometry)

        settings.contentTextSizePreference = .custom(100)
        settings.save()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.testingPrimaryContentFontPointSize, baselineTitle, accuracy: 0.01)
        XCTAssertEqual(view.testingOverviewConfigurationCount, overviewConfigurationCount)
        XCTAssertEqual(view.testingScientificOverviewGeometry, baselineScientificGeometry)
    }

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

    func testFactsRailShowsAvailableRecordAndAnnotationFacts() throws {
        let view = makeView()
        let record = makeRecord(
            recordFields: [
                "LOCUS.MOLECULE_TYPE": ["DNA"],
                "DEFINITION": ["Mafa-A1 complete genomic allele."],
                "ORGANISM": ["Macaca fascicularis"],
                "COMMENT.Previous designations": ["Mafa-A1*06301; Mafa-A1*063:01:01"],
            ],
            features: [
                feature(
                    type: "gene",
                    start: 0,
                    end: 24,
                    sourceOrdinal: 1,
                    qualifiers: [
                        "gene": ["Mafa-A1"],
                        "note": ["curated genomic reference"],
                    ]
                ),
                feature(
                    type: "CDS",
                    start: 0,
                    end: 9,
                    sourceOrdinal: 2,
                    qualifiers: [
                        "product": ["MHC class I antigen"],
                        "translation": ["MKTWQ"],
                    ]
                ),
                feature(type: "CDS", start: 12, end: 18, sourceOrdinal: 2),
                feature(type: "exon", start: 0, end: 9, sourceOrdinal: 3),
                feature(type: "exon", start: 12, end: 18, sourceOrdinal: 4),
            ]
        )

        view.configure(record: record, observedSample: nil)

        XCTAssertEqual(text("knownAlleleMoleculeType", in: view), "DNA")
        XCTAssertEqual(
            text("knownAlleleDefinition", in: view),
            "Mafa-A1 complete genomic allele."
        )
        XCTAssertEqual(text("knownAlleleOrganism", in: view), "Macaca fascicularis")
        XCTAssertEqual(text("knownAlleleProduct", in: view), "MHC class I antigen")
        XCTAssertEqual(text("knownAlleleExonCount", in: view), "2")
        XCTAssertEqual(text("knownAlleleCDSLength", in: view), "15 bp")
        XCTAssertEqual(text("knownAlleleProteinLength", in: view), "5 aa")
        XCTAssertEqual(
            text("knownAllelePreviousDesignations", in: view),
            "Mafa-A1*06301; Mafa-A1*063:01:01"
        )
        XCTAssertEqual(text("knownAlleleNotes", in: view), "curated genomic reference")

        let facts = try identifiedView("knownAlleleFactsRail", in: view)
        let locus = try identifiedView("knownAlleleLocus", in: view)
        let locusInFacts = locus.convert(locus.bounds, to: facts)
        XCTAssertGreaterThan(locusInFacts.intersection(facts.bounds).height, 0)
    }

    func testFeatureHoverAndSelectionPopulateBoundedFactsArea() throws {
        let view = makeView()
        view.configure(record: makeRecord(), observedSample: nil)

        let featureInformation = try identifiedView("knownAlleleFeatureInformation", in: view)
        XCTAssertLessThanOrEqual(featureInformation.frame.height, 132)
        XCTAssertEqual(
            text("knownAlleleFeatureInformationText", in: view),
            "Hover over or select a feature to inspect its annotation."
        )

        let exonBlock = try XCTUnwrap(lane("exon", in: view).subviews.first)
        exonBlock.mouseEntered(with: try mouseEvent(type: .mouseEntered, in: exonBlock))
        let hoveredText = try XCTUnwrap(text("knownAlleleFeatureInformationText", in: view))
        XCTAssertTrue(hoveredText.contains("Exon"))
        XCTAssertTrue(hoveredText.contains("Number: 2"))
        XCTAssertTrue(hoveredText.contains("Coordinates: 3–10 (8 bp)"))
        XCTAssertTrue(hoveredText.contains("Strand: +"))
        XCTAssertTrue(hoveredText.contains("Source location: 3..10"))

        exonBlock.mouseDown(with: try mouseEvent(type: .leftMouseDown, in: exonBlock))
        exonBlock.mouseExited(with: try mouseEvent(type: .mouseExited, in: exonBlock))
        XCTAssertEqual(text("knownAlleleFeatureInformationText", in: view), hoveredText)

        try modeButton("knownAlleleModeGenBank", in: view).performClick(nil)
        try modeButton("knownAlleleModeOverview", in: view).performClick(nil)
        XCTAssertEqual(text("knownAlleleFeatureInformationText", in: view), hoveredText)

        let cdsBlock = try XCTUnwrap(lane("CDS", in: view).subviews.first)
        cdsBlock.mouseEntered(with: try mouseEvent(type: .mouseEntered, in: cdsBlock))
        let cdsText = try XCTUnwrap(text("knownAlleleFeatureInformationText", in: view))
        XCTAssertTrue(cdsText.contains("Product: MHC class I antigen"))
        XCTAssertTrue(cdsText.contains("Translation: 5 aa"))
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

    func testTranslationGeometryBelongsOnlyToMatchingAnnotatedSource() throws {
        let view = makeView()
        let joinedTranslationSource = [
            feature(
                type: "CDS",
                start: 2,
                end: 10,
                sourceOrdinal: 2,
                qualifiers: [
                    "product": ["Translated antigen"],
                    "translation": ["MATCHINGPEPTIDE"],
                ]
            ),
            feature(
                type: "CDS",
                start: 14,
                end: 22,
                sourceOrdinal: 2,
                qualifiers: ["product": ["Translated antigen"]]
            ),
            feature(
                type: "CDS",
                start: 10,
                end: 14,
                sourceOrdinal: 7,
                qualifiers: ["product": ["Unrelated CDS"]]
            ),
        ]

        view.configure(
            record: makeRecord(
                features: joinedTranslationSource,
                annotatedTranslation: "MATCHINGPEPTIDE"
            ),
            observedSample: nil
        )

        let ownedBlocks = try lane("translation", in: view).subviews
        XCTAssertEqual(ownedBlocks.count, 2)
        XCTAssertTrue(ownedBlocks.allSatisfy {
            $0.accessibilityIdentifier().contains(".translation.2.")
        })
        XCTAssertFalse(ownedBlocks.contains {
            $0.accessibilityIdentifier().contains(".translation.7.")
        })
        XCTAssertGreaterThan(ownedBlocks[1].frame.minX - ownedBlocks[0].frame.maxX, 1)

        view.configure(
            record: makeRecord(
                features: joinedTranslationSource.map { feature in
                    ONTMHCReferenceVisualizationFeature(
                        type: feature.type,
                        start: feature.start,
                        end: feature.end,
                        strand: feature.strand,
                        sourceOrdinal: feature.sourceOrdinal,
                        rawGenBankLocation: feature.rawGenBankLocation,
                        qualifiers: feature.qualifiers.filter { $0.key != "translation" }
                    )
                },
                annotatedTranslation: "MATCHINGPEPTIDE"
            ),
            observedSample: nil
        )

        XCTAssertEqual(try lane("translation", in: view).subviews.count, 0)
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

    func testRepeatedIdenticalCommentsDoNotRebuildTheFactsRailStack() {
        let view = makeView()
        let record = makeRecord()
        let comments = [("Row Comment", "Review this allele before release.")]
        view.configure(record: record, observedSample: "CR1178", comments: comments)
        XCTAssertEqual(view.testingCommentContentReplacementCount, 1)

        view.configure(record: record, observedSample: "CR1178", comments: comments)

        XCTAssertEqual(
            view.testingCommentContentReplacementCount,
            1,
            "Identical comments must not rebuild nested NSStackView constraints."
        )
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

    func testCommentsAreVisibleReplaceWithoutGrowthAndIncreaseOverviewAndFallbackHeight() throws {
        let record = makeRecord()
        let comments = [
            ("Row Comment", "Review the complete allele annotation before release."),
            ("Column Comment", "Sample metadata needs independent confirmation."),
            ("Cell Comment", "Resolve this allele and sample pairing."),
        ]
        let wide = makeView()
        wide.configure(record: record, observedSample: nil)
        let wideBaseHeight = wide.intrinsicContentSize.height

        wide.configure(record: record, observedSample: "CR1178", comments: comments)

        let section = try identifiedView("knownAlleleCommentsSection", in: wide)
        XCTAssertFalse(section.isHidden)
        XCTAssertEqual(text("knownAlleleCommentsTitle", in: wide), "Comments")
        for (label, body) in comments {
            XCTAssertTrue(textFields(in: section).contains { $0.stringValue == label })
            XCTAssertTrue(textFields(in: section).contains { $0.stringValue == body })
        }
        XCTAssertGreaterThan(wide.intrinsicContentSize.height, wideBaseHeight)
        let threeCommentHeight = wide.intrinsicContentSize.height
        let threeCommentCount = descendants(of: wide).count

        wide.configure(
            record: makeRecord(rawReferenceID: "NHP0099", alleleName: "Mafa-B*099:02"),
            observedSample: nil,
            comments: [("Row Comment", "Replacement note")]
        )

        let replacementText = textFields(in: wide).map(\.stringValue)
        XCTAssertTrue(replacementText.contains("Replacement note"))
        XCTAssertFalse(replacementText.contains(comments[0].1))
        XCTAssertEqual(descendants(of: wide).filter {
            $0.accessibilityIdentifier().hasPrefix("knownAlleleCommentRow.")
        }.count, 1)
        XCTAssertLessThan(wide.intrinsicContentSize.height, threeCommentHeight)
        XCTAssertLessThan(descendants(of: wide).count, threeCommentCount)

        wide.configure(record: record, observedSample: nil, comments: [])
        XCTAssertTrue(try identifiedView("knownAlleleCommentsSection", in: wide).isHidden)

        let narrow = GenotypeKnownAlleleDetailView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 1)
        )
        narrow.configure(record: record, observedSample: nil)
        let narrowBaseHeight = narrow.intrinsicContentSize.height
        narrow.configure(record: record, observedSample: nil, comments: comments)
        XCTAssertGreaterThan(narrow.intrinsicContentSize.height, narrowBaseHeight)
        let narrowShortHeight = narrow.intrinsicContentSize.height
        narrow.configure(
            record: record,
            observedSample: nil,
            comments: [("Row Comment", String(repeating: "Long wrapping comment. ", count: 20))]
        )
        XCTAssertGreaterThan(narrow.intrinsicContentSize.height, narrowShortHeight)

        let fallback = GenotypeKnownAlleleDetailView(frame: .zero)
        fallback.configureFallback(
            alleleName: "Mafa-DPB1*01:01",
            rawReferenceID: "legacy_DPB1_01",
            fields: [("Definition", "Legacy reference")],
            observedSample: nil
        )
        let fallbackBaseHeight = fallback.intrinsicContentSize.height
        fallback.configureFallback(
            alleleName: "Mafa-DPB1*01:01",
            rawReferenceID: "legacy_DPB1_01",
            fields: [("Definition", "Legacy reference")],
            observedSample: "CR1178",
            comments: comments
        )
        XCTAssertGreaterThan(fallback.intrinsicContentSize.height, fallbackBaseHeight)
        XCTAssertEqual(text("knownAlleleCommentsTitle", in: fallback), "Comments")
        XCTAssertTrue(textFields(in: fallback).contains { $0.stringValue == comments[2].1 })
    }

    func testModesAndFallbackProvideMeaningfulIntrinsicAndFittingHeightsFromZeroFrame() throws {
        let overview = GenotypeKnownAlleleDetailView(frame: .zero)
        overview.configure(record: makeRecord(), observedSample: "CR1178")
        assertSelfSizing(overview, minimumHeight: 280)

        let genBank = GenotypeKnownAlleleDetailView(frame: .zero)
        genBank.configure(record: makeRecord(), observedSample: nil)
        try modeButton("knownAlleleModeGenBank", in: genBank).performClick(nil)
        assertSelfSizing(genBank, minimumHeight: 320)
        XCTAssertGreaterThan(try visibleScrollView(in: genBank).frame.height, 200)

        let fasta = GenotypeKnownAlleleDetailView(frame: .zero)
        fasta.configure(record: makeRecord(), observedSample: nil)
        try modeButton("knownAlleleModeFASTA", in: fasta).performClick(nil)
        assertSelfSizing(fasta, minimumHeight: 320)
        XCTAssertGreaterThan(try visibleScrollView(in: fasta).frame.height, 200)

        let fallback = GenotypeKnownAlleleDetailView(frame: .zero)
        fallback.configureFallback(
            alleleName: "Mafa-DPB1*01:01",
            rawReferenceID: "legacy_DPB1_01",
            fields: [("Locus", "Mafa-DPB1"), ("Definition", "Legacy reference")],
            observedSample: "CR1178"
        )
        assertSelfSizing(fallback, minimumHeight: 180)
    }

    func testOverviewAdaptsWithoutAmbiguityAtControllerMinimumWidth() throws {
        let view = GenotypeKnownAlleleDetailView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 1)
        )
        view.configure(record: makeRecord(), observedSample: "CR1178")
        view.frame.size.height = view.intrinsicContentSize.height
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.hasAmbiguousLayout)
        XCTAssertTrue(descendants(of: view).allSatisfy { !$0.hasAmbiguousLayout })

        let overview = try identifiedView("knownAlleleOverview", in: view)
        let facts = try identifiedView("knownAlleleFactsRail", in: view)
        let canvasRect = overview.convert(overview.bounds, to: view)
        let factsRect = facts.convert(facts.bounds, to: view)
        assertContained(canvasRect, in: view.bounds)
        assertContained(factsRect, in: view.bounds)
        XCTAssertGreaterThan(canvasRect.width, 220)
        XCTAssertGreaterThan(factsRect.width, 220)
        XCTAssertGreaterThan(factsRect.height, 220)
        XCTAssertLessThanOrEqual(canvasRect.intersection(factsRect).height, 1)

        let ruler = try identifiedView("knownAlleleCoordinateRuler", in: view)
        let rulerRect = ruler.convert(ruler.bounds, to: view)
        assertContained(rulerRect, in: view.bounds)
        XCTAssertGreaterThan(rulerRect.width, 100)
    }

    func testFactsRailBackgroundUpdatesAcrossEffectiveAppearances() throws {
        let view = makeView()
        view.configure(record: makeRecord(), observedSample: nil)
        let facts = try identifiedView("knownAlleleFactsRail", in: view)
        XCTAssertFalse(facts.wantsLayer)

        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        view.layoutSubtreeIfNeeded()
        let lightComponents = try renderedBackgroundComponents(of: facts)

        view.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        view.layoutSubtreeIfNeeded()
        let darkComponents = try renderedBackgroundComponents(of: facts)

        XCTAssertNotEqual(lightComponents, darkComponents)
    }

    private func makeView() -> GenotypeKnownAlleleDetailView {
        let view = GenotypeKnownAlleleDetailView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func expectedSequencePointSize(
        baselineAtOneHundredPercent baseline: CGFloat,
        preference: ContentTextSizePreference
    ) -> CGFloat {
        let factor: CGFloat
        switch preference {
        case .system:
            factor = ContentTypography.current().font(for: .body).pointSize
                / max(NSFont.systemFontSize, 1)
        case .custom(let percent):
            factor = CGFloat(percent) / 100
        }
        return max(ContentTypography.minimumPointSize, baseline * factor)
    }

    private func makeRecord(
        rawReferenceID: String = "NHP0068",
        alleleName: String = "Mafa-A1*063:01",
        locus: String? = "Mafa-A1",
        sequence: String = "ACGTACGTACGTACGTACGTACGT",
        recordFields: [String: [String]] = ["definition": ["MHC class I allele"]],
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
            recordFields: recordFields,
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
                    qualifiers: [
                        "product": ["MHC class I antigen"],
                        "translation": ["MKTWQ"],
                    ]
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

    private func mouseEvent(type: NSEvent.EventType, in view: NSView) throws -> NSEvent {
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        if type == .mouseEntered || type == .mouseExited {
            return try XCTUnwrap(NSEvent.enterExitEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 1,
                userData: nil
            ))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
    }

    private func assertSelfSizing(
        _ view: GenotypeKnownAlleleDetailView,
        minimumHeight: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let intrinsicHeight = view.intrinsicContentSize.height
        XCTAssertGreaterThan(intrinsicHeight, minimumHeight, file: file, line: line)
        view.frame.size = NSSize(width: 600, height: intrinsicHeight)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, minimumHeight, file: file, line: line)
    }

    private func assertContained(
        _ rect: NSRect,
        in bounds: NSRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(rect.minX, bounds.minX - 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, bounds.minY - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.5, file: file, line: line)
    }

    private func renderedBackgroundComponents(of view: NSView) throws -> [CGFloat] {
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let color = try XCTUnwrap(representation.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
}
