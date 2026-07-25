import AppKit
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeCandidateAlleleDetailViewTests: XCTestCase {
    func testContentTypographyScalesCandidateTextWithoutReconfiguringScientificTracks() throws {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let view = makeView()
        let baselineFont = view.testingPrimaryContentFontPointSize
        let baselineDifferenceConfigurations = view.differenceTrackConfigurationCount
        let baselineReferenceConfigurations = view.referenceOverviewConfigurationCount
        let baselineDifferenceGeometry = view.testingDifferenceTrackGeometry

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.testingPrimaryContentFontPointSize, baselineFont * 2, accuracy: 0.01)
        XCTAssertEqual(view.differenceTrackConfigurationCount, baselineDifferenceConfigurations)
        XCTAssertEqual(view.referenceOverviewConfigurationCount, baselineReferenceConfigurations)
        XCTAssertEqual(view.testingDifferenceTrackGeometry, baselineDifferenceGeometry)

        settings.contentTextSizePreference = .custom(100)
        settings.save()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.testingPrimaryContentFontPointSize, baselineFont, accuracy: 0.01)
        XCTAssertEqual(view.differenceTrackConfigurationCount, baselineDifferenceConfigurations)
        XCTAssertEqual(view.referenceOverviewConfigurationCount, baselineReferenceConfigurations)
        XCTAssertEqual(view.testingDifferenceTrackGeometry, baselineDifferenceGeometry)
    }

    func testConfigureStartsInOverviewAndShowsCandidateAndClosestReferenceFacts() throws {
        let view = makeView()

        view.configure(
            candidate: makeCandidate(),
            closestReference: makeReference(),
            candidateSequence: String(repeating: "ACGT", count: 6),
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8,
            comments: [("Candidate note", "Review before release.")],
            warning: "Coverage is near the review threshold."
        )

        XCTAssertEqual(view.currentMode, .overview)
        XCTAssertEqual(try modeButton("candidateModeOverview", in: view).state, .on)
        XCTAssertEqual(text("candidateAlleleName", in: view), "Mafa-A1*067:01_2nt_nov")
        XCTAssertEqual(text("candidateStableClusterID", in: view), "cluster-a")
        XCTAssertNotNil(find("candidateClosestReferenceOverview", in: view))
        XCTAssertNotNil(find("candidateDifferenceTrack", in: view))
        XCTAssertEqual(
            text("candidateClosestReferenceGeometryLabel", in: view),
            "Closest-reference geometry: Mafa-A1*063:01 (NHP0068)"
        )

        XCTAssertEqual(text("candidateClassification", in: view), "Novel")
        XCTAssertEqual(text("candidateLocus", in: view), "Mafa-A1")
        XCTAssertEqual(text("candidateSupportClass", in: view), "Shared")
        XCTAssertEqual(text("candidateSampleCount", in: view), "2")
        XCTAssertEqual(text("candidateSampleIDs", in: view), "CR1178, CR1180")
        XCTAssertEqual(text("candidateOccurrenceCount", in: view), "2")
        XCTAssertEqual(text("candidateTotalReads", in: view), "14")
        XCTAssertEqual(text("candidateSelectedSample", in: view), "CR1178")
        XCTAssertEqual(text("candidateSelectedSampleReadCount", in: view), "8")
        XCTAssertEqual(text("candidateClosestAllele", in: view), "Mafa-A1*063:01")
        XCTAssertEqual(text("candidateClosestRawReferenceID", in: view), "NHP0068")
        XCTAssertEqual(text("candidateClosestReferenceClass", in: view), "Genomic DNA")
        XCTAssertEqual(text("candidateExtensionOf", in: view), "—")
        XCTAssertEqual(text("candidateSNPCount", in: view), "3")
        XCTAssertEqual(text("candidateInsertedBases", in: view), "2")
        XCTAssertEqual(text("candidateDeletedBases", in: view), "2")
        XCTAssertEqual(text("candidateLongGapBases", in: view), "20")
        XCTAssertEqual(text("candidateComparableBases", in: view), "20")
        XCTAssertEqual(text("candidateCoverage", in: view), "95.00%")
        XCTAssertEqual(text("candidateIdentity", in: view), "99.00%")
        XCTAssertEqual(text("candidateMappingQuality", in: view), "60")
        XCTAssertEqual(text("candidateAlignmentScore", in: view), "1800")
        XCTAssertEqual(text("candidateSequenceLength", in: view), "24 bp")
        XCTAssertEqual(text("candidateFASTARecordID", in: view), "cluster-a")
        XCTAssertEqual(text("candidateSequenceSHA256", in: view), String(repeating: "b", count: 64))
        XCTAssertEqual(text("candidateCommentLabel.0", in: view), "Candidate note")
        XCTAssertEqual(text("candidateCommentBody.0", in: view), "Review before release.")
        XCTAssertEqual(
            text("candidateWarning", in: view),
            "Coverage is near the review threshold."
        )

        let visible = visibleText(in: view)
        XCTAssertTrue(visible.contains("Reference-relative only"))
        XCTAssertFalse(visible.localizedCaseInsensitiveContains("synonymous"))
        XCTAssertFalse(visible.localizedCaseInsensitiveContains("nonsynonymous"))
        XCTAssertFalse(visible.localizedCaseInsensitiveContains("candidate exon"))
        XCTAssertFalse(visible.localizedCaseInsensitiveContains("candidate translation"))
        XCTAssertFalse(visible.contains("unmatched-to-reference.bam"))
        XCTAssertFalse(visible.contains("selected-read"))
    }

    func testPrincipalViewsExposeStableAccessibilityIdentifiers() throws {
        let view = makeView()
        view.configure(
            candidate: makeCandidate(),
            closestReference: makeReference(),
            candidateSequence: String(repeating: "ACGT", count: 6),
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8
        )

        for identifier in [
            "candidateHeader",
            "candidateAlleleName",
            "candidateStableClusterID",
            "candidateModeControl",
            "candidateModeOverview",
            "candidateModeGenBank",
            "candidateModeFASTA",
            "candidateClosestReferenceOverview",
            "candidateClosestReferenceRenderer",
            "candidateFactsRail",
            "candidateGenBankTextView",
            "candidateFASTATextView",
            "candidateFallbackNote",
        ] {
            let identified = try XCTUnwrap(find(identifier, in: view), identifier)
            XCTAssertEqual(identified.accessibilityIdentifier(), identifier)
        }
    }

    func testOverviewAdaptsWithoutClippingAtControllerMinimumWidth() throws {
        let view = GenotypeCandidateAlleleDetailView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 1)
        )
        view.configure(
            candidate: makeCandidate(),
            closestReference: makeReference(),
            candidateSequence: String(repeating: "ACGT", count: 6),
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8
        )
        view.frame.size.height = view.intrinsicContentSize.height
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.hasAmbiguousLayout)
        XCTAssertTrue(descendants(of: view).allSatisfy { !$0.hasAmbiguousLayout })

        let header = try XCTUnwrap(find("candidateHeader", in: view))
        let selector = try XCTUnwrap(find("candidateModeControl", in: view))
        let canvas = try XCTUnwrap(find("candidateClosestReferenceOverview", in: view))
        let difference = try XCTUnwrap(find("candidateDifferenceTrack", in: view))
        let facts = try XCTUnwrap(find("candidateFactsRail", in: view))
        let headerRect = header.convert(header.bounds, to: view)
        let selectorRect = selector.convert(selector.bounds, to: view)
        let canvasRect = canvas.convert(canvas.bounds, to: view)
        let differenceRect = difference.convert(difference.bounds, to: view)
        let factsRect = facts.convert(facts.bounds, to: view)
        for rect in [headerRect, selectorRect, canvasRect, differenceRect, factsRect] {
            assertContained(rect, in: view.bounds)
        }
        XCTAssertGreaterThan(canvasRect.width, 200)
        XCTAssertGreaterThan(differenceRect.width, 200)
        XCTAssertGreaterThan(factsRect.width, 200)
        XCTAssertGreaterThan(factsRect.height, 220)
        XCTAssertLessThanOrEqual(canvasRect.intersection(factsRect).height, 1)
    }

    func testGenBankAndFASTAModesShowExactReadOnlyCanonicalContent() throws {
        let view = makeView()
        let reference = makeReference()
        let sequence = String(repeating: "ACGT", count: 21)
        view.configure(
            candidate: makeCandidate(),
            closestReference: reference,
            candidateSequence: sequence,
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8
        )

        try modeButton("candidateModeGenBank", in: view).performClick(nil)

        XCTAssertEqual(view.currentMode, .genBank)
        XCTAssertEqual(
            text("candidateGenBankContext", in: view),
            "Canonical closest-reference GenBank: Mafa-A1*063:01 (NHP0068)"
        )
        let genBank = try textView("candidateGenBankTextView", in: view)
        XCTAssertEqual(genBank.string, reference.genBankText)
        XCTAssertFalse(genBank.isEditable)
        XCTAssertTrue(genBank.isSelectable)

        try modeButton("candidateModeFASTA", in: view).performClick(nil)

        XCTAssertEqual(view.currentMode, .fasta)
        let fasta = try textView("candidateFASTATextView", in: view)
        XCTAssertEqual(
            fasta.string,
            ">cluster-a Mafa-A1*067:01_2nt_nov classification=novel support=shared samples=2 reads=14\n"
                + String(repeating: "ACGT", count: 20) + "\nACGT\n"
        )
        XCTAssertFalse(fasta.isEditable)
        XCTAssertTrue(fasta.isSelectable)

        try button("candidateShowGenBankButton", in: view).performClick(nil)
        XCTAssertEqual(view.currentMode, .genBank)
        try button("candidateShowFASTAButton", in: view).performClick(nil)
        XCTAssertEqual(view.currentMode, .fasta)
    }

    func testDifferenceTrackParsesExtendedCIGAROnceAndClassifiesReferenceFeatures() throws {
        let view = makeView()
        view.configure(
            candidate: makeCandidate(cigar: "2=1X2=2I2=2D1=1X3=1X"),
            closestReference: makeReference(),
            candidateSequence: String(repeating: "ACGT", count: 6),
            selectedSampleID: nil,
            selectedSampleReadCount: nil
        )

        let track = try XCTUnwrap(
            find("candidateDifferenceTrack", in: view) as? GenotypeCandidateDifferenceTrackView
        )
        XCTAssertEqual(track.configurationCount, 1)
        XCTAssertEqual(track.markers, [
            .init(kind: .mismatch(.exonTwoOrThree), referenceRange: 2..<3, length: 1),
            .init(kind: .insertion, referenceRange: 5..<5, length: 2),
            .init(kind: .deletion, referenceRange: 7..<9, length: 2),
            .init(kind: .mismatch(.intronOrNonExon), referenceRange: 10..<11, length: 1),
            .init(kind: .mismatch(.otherExon), referenceRange: 14..<15, length: 1),
        ])
        XCTAssertEqual(
            track.accessibilityValue() as? String,
            "5 candidate difference markers: 3 substitutions (1 exon 2/3, 1 other exon, 1 intron/non-exon), 1 insertion, 1 deletion"
        )
        XCTAssertEqual(track.intrinsicContentSize.height, 58)

        view.configure(
            candidate: makeCandidate(cigar: "100000X"),
            closestReference: makeReference(sequenceLength: 100_000),
            candidateSequence: "A",
            selectedSampleID: nil,
            selectedSampleReadCount: nil
        )
        XCTAssertEqual(track.markers.count, 1, "Markers must be bounded by CIGAR operations, not bases.")
        XCTAssertEqual(track.configurationCount, 2)
    }

    func testDifferenceTrackRejectsMalformedAndOutOfBoundsCIGARWithoutPartialMarkers() throws {
        let track = GenotypeCandidateDifferenceTrackView(frame: .zero)
        let reference = makeReference()

        track.configure(
            referenceLength: reference.sequence.count,
            referenceStart: 1,
            cigar: "2=1XQ",
            features: reference.features
        )
        XCTAssertTrue(track.markers.isEmpty)
        XCTAssertNotNil(track.parsingIssue)

        track.configure(
            referenceLength: reference.sequence.count,
            referenceStart: 1,
            cigar: "25X",
            features: reference.features
        )
        XCTAssertTrue(track.markers.isEmpty)
        XCTAssertNotNil(track.parsingIssue)

        track.configure(
            referenceLength: reference.sequence.count,
            referenceStart: 0,
            cigar: "1X",
            features: reference.features
        )
        XCTAssertTrue(track.markers.isEmpty)
        XCTAssertNotNil(track.parsingIssue)
        XCTAssertTrue((track.accessibilityValue() as? String)?.hasPrefix("Difference track unavailable:") == true)
    }

    func testDifferenceTrackAppliesPositiveOneBasedReferenceStartToMarkerCoordinates() {
        let track = GenotypeCandidateDifferenceTrackView(frame: .zero)

        track.configure(
            referenceLength: 24,
            referenceStart: 5,
            cigar: "2=1X1I2D",
            features: []
        )

        XCTAssertNil(track.parsingIssue)
        XCTAssertEqual(track.markers, [
            .init(kind: .mismatch(.intronOrNonExon), referenceRange: 6..<7, length: 1),
            .init(kind: .insertion, referenceRange: 7..<7, length: 1),
            .init(kind: .deletion, referenceRange: 7..<9, length: 2),
        ])
    }

    func testDifferenceTrackEnforcesTenThousandOperationBound() {
        let track = GenotypeCandidateDifferenceTrackView(frame: .zero)
        let boundedCIGAR = String(repeating: "1I", count: 10_000)

        track.configure(
            referenceLength: 24,
            referenceStart: 1,
            cigar: boundedCIGAR,
            features: []
        )
        XCTAssertNil(track.parsingIssue)
        XCTAssertEqual(track.markers.count, 10_000)

        track.configure(
            referenceLength: 24,
            referenceStart: 1,
            cigar: boundedCIGAR + "1I",
            features: []
        )
        XCTAssertTrue(track.markers.isEmpty)
        XCTAssertTrue(track.parsingIssue?.contains("10000-operation display limit") == true)
    }

    func testConstraintSnapshotTreatsEquivalentConstraintReplacementAsStable() {
        let container = NSView()
        let child = NSView()
        container.addSubview(child)
        let first = child.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12)
        let replacement = child.leadingAnchor.constraint(
            equalTo: container.leadingAnchor,
            constant: 12
        )

        XCTAssertEqual(
            constraintSnapshot([replacement]),
            constraintSnapshot([first])
        )
    }

    func testOneHundredReconfigurationsAndModeSwitchesKeepHierarchyAndConstraintsBounded() throws {
        let view = makeView()
        let candidate = makeCandidate()
        let reference = makeReference()
        view.configure(
            candidate: candidate,
            closestReference: reference,
            candidateSequence: String(repeating: "ACGT", count: 6),
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8,
            comments: [("Candidate note", "Review before release.")]
        )
        // Warm each persistent mode once so AppKit's lazily-created text-system constraints
        // are included in the baseline; subsequent switching must remain strictly bounded.
        try modeButton("candidateModeGenBank", in: view).performClick(nil)
        try modeButton("candidateModeFASTA", in: view).performClick(nil)
        try modeButton("candidateModeOverview", in: view).performClick(nil)
        view.layoutSubtreeIfNeeded()
        let descendantCount = descendants(of: view).count
        let activeConstraintCount = activeConstraints(in: view).count
        let activeConstraintSnapshot = constraintSnapshot(activeConstraints(in: view))

        for index in 0..<100 {
            try modeButton(index.isMultiple(of: 2) ? "candidateModeGenBank" : "candidateModeFASTA", in: view)
                .performClick(nil)
            try modeButton("candidateModeOverview", in: view).performClick(nil)
            view.configure(
                candidate: candidate,
                closestReference: reference,
                candidateSequence: String(repeating: "ACGT", count: 6),
                selectedSampleID: "CR1178",
                selectedSampleReadCount: 8,
                comments: [("Candidate note", "Review before release.")]
            )
        }

        XCTAssertEqual(descendants(of: view).count, descendantCount)
        XCTAssertEqual(activeConstraints(in: view).count, activeConstraintCount)
        XCTAssertEqual(
            constraintSnapshot(activeConstraints(in: view)),
            activeConstraintSnapshot
        )
        XCTAssertEqual(view.currentMode, .overview)
        XCTAssertEqual(view.differenceTrackConfigurationCount, 1)
        XCTAssertEqual(view.fastaFormattingCount, 1)
        XCTAssertEqual(view.immutablePresentationApplicationCount, 1)
        XCTAssertEqual(view.differenceTrackPresentationApplicationCount, 1)
        XCTAssertEqual(view.fastaTextAssignmentCount, 1)
        XCTAssertEqual(view.genBankTextAssignmentCount, 1)
        XCTAssertEqual(view.referenceOverviewConfigurationCount, 1)
    }

    func testAlternatingSeenCandidatesReuseTwoCachedPresentationsWithoutGrowingHierarchy() throws {
        let view = makeView()
        let reference = makeReference()
        let candidateA = makeCandidate()
        let candidateB = makeCandidate(
            stableClusterID: "cluster-b",
            provisionalName: "Mafa-A1*068:01_1nt_nov",
            cigar: "1=1X22="
        )
        let sequenceA = String(repeating: "ACGT", count: 6)
        let sequenceB = String(repeating: "TGCA", count: 6)

        view.configure(
            candidate: candidateA,
            closestReference: reference,
            candidateSequence: sequenceA,
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8
        )
        view.configure(
            candidate: candidateB,
            closestReference: reference,
            candidateSequence: sequenceB,
            selectedSampleID: "CR1180",
            selectedSampleReadCount: 6
        )
        let descendantCount = descendants(of: view).count
        let activeConstraintCount = activeConstraints(in: view).count

        for index in 0..<100 {
            let usesA = index.isMultiple(of: 2)
            view.configure(
                candidate: usesA ? candidateA : candidateB,
                closestReference: reference,
                candidateSequence: usesA ? sequenceA : sequenceB,
                selectedSampleID: usesA ? "CR1178" : "CR1180",
                selectedSampleReadCount: index
            )
        }

        XCTAssertEqual(view.differenceTrackConfigurationCount, 2)
        XCTAssertEqual(view.fastaFormattingCount, 2)
        XCTAssertEqual(view.immutablePresentationApplicationCount, 102)
        XCTAssertEqual(view.differenceTrackPresentationApplicationCount, 102)
        XCTAssertEqual(view.fastaTextAssignmentCount, 102)
        XCTAssertEqual(view.genBankTextAssignmentCount, 1)
        XCTAssertEqual(view.referenceOverviewConfigurationCount, 1)
        XCTAssertEqual(descendants(of: view).count, descendantCount)
        XCTAssertEqual(activeConstraints(in: view).count, activeConstraintCount)
        XCTAssertEqual(text("candidateSelectedSampleReadCount", in: view), "99")
        XCTAssertEqual(
            try textView("candidateFASTATextView", in: view).string,
            ">cluster-b Mafa-A1*068:01_1nt_nov classification=novel support=shared samples=2 reads=14\n"
                + sequenceB + "\n"
        )
        let track = try XCTUnwrap(
            find("candidateDifferenceTrack", in: view) as? GenotypeCandidateDifferenceTrackView
        )
        XCTAssertEqual(track.markers.count, 1)
        XCTAssertEqual(track.markers.first?.referenceRange, 1..<2)
    }

    func testSameReferenceRawIDWithRefreshedPayloadReappliesReferenceDocumentsOnce() throws {
        let view = makeView()
        let candidate = makeCandidate()
        let sequence = String(repeating: "ACGT", count: 6)
        let originalReference = makeReference()
        let refreshedReference = ONTMHCReferenceVisualizationRecord(
            rawReferenceID: originalReference.rawReferenceID,
            sourceOrdinal: 2,
            alleleName: "Mafa-A1*064:01",
            locus: "Mafa-A1-refreshed",
            sequence: String(repeating: "C", count: 24),
            sequenceSHA256: "refreshed-checksum",
            recordFields: ["DEFINITION": ["Refreshed MHC class I allele"]],
            features: [
                feature(start: 3, end: 7, ordinal: 1, numberKey: "exon_number", number: "2"),
            ],
            annotatedTranslation: "REFRESHED",
            genBankText: "LOCUS       NHP0068 REFRESHED 24 bp DNA\n//\n",
            fastaText: ">NHP0068 Mafa-A1*064:01 refreshed\n" + String(repeating: "C", count: 24) + "\n",
            roles: [.init(role: .closestNovelReference, candidateStableClusterIDs: ["cluster-a"])]
        )

        view.configure(
            candidate: candidate,
            closestReference: originalReference,
            candidateSequence: sequence,
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8
        )
        view.configure(
            candidate: candidate,
            closestReference: refreshedReference,
            candidateSequence: sequence,
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 9
        )
        view.configure(
            candidate: candidate,
            closestReference: refreshedReference,
            candidateSequence: sequence,
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 10
        )

        XCTAssertEqual(view.referenceOverviewConfigurationCount, 2)
        XCTAssertEqual(view.genBankTextAssignmentCount, 2)
        XCTAssertEqual(view.differenceTrackConfigurationCount, 2)
        XCTAssertEqual(
            text("candidateClosestReferenceGeometryLabel", in: view),
            "Closest-reference geometry: Mafa-A1*064:01 (NHP0068)"
        )
        XCTAssertEqual(
            try textView("candidateGenBankTextView", in: view).string,
            refreshedReference.genBankText
        )
        let nucleotideStrip = try XCTUnwrap(find("knownAlleleNucleotideStrip", in: view))
        XCTAssertEqual(
            nucleotideStrip.accessibilityValue() as? String,
            refreshedReference.sequence
        )
        XCTAssertEqual(text("candidateSelectedSampleReadCount", in: view), "10")
    }

    func testMissingSequenceUsesFreshAnalysisFallbackIndependently() throws {
        let view = makeView()

        view.configure(
            candidate: makeCandidate(),
            closestReference: makeReference(),
            candidateSequence: nil,
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8,
            comments: [("Candidate note", "Review before release.")]
        )

        XCTAssertTrue(try XCTUnwrap(find("candidateModeControl", in: view)).isHidden)
        let fallback = try XCTUnwrap(text("candidateFallbackNote", in: view))
        XCTAssertTrue(fallback.contains("candidate sequence"))
        XCTAssertFalse(fallback.contains("closest-reference visualization"))
        XCTAssertTrue(fallback.contains("fresh analysis"))
        XCTAssertEqual(text("candidateClosestRawReferenceID", in: view), "NHP0068")
        XCTAssertFalse(
            try XCTUnwrap(find("candidateClosestReferenceOverview", in: view))
                .isHiddenOrHasHiddenAncestor
        )
        XCTAssertEqual(view.intrinsicContentSize.height, 560)
        assertFallbackNoteOccupiesVisibleLayout(in: view)
        assertCandidateFactsAndCommentsAreVisible(in: view)

        let visible = visibleText(in: view)
        XCTAssertFalse(visible.contains("unmatched-to-reference.bam"))
        XCTAssertFalse(visible.contains("selected-read"))
        XCTAssertFalse(visible.contains("2=1X"))
    }

    func testMissingReferenceUsesBoundedFreshAnalysisFallbackIndependently() throws {
        let view = makeView()
        let candidate = makeCandidate()

        view.configure(
            candidate: candidate,
            closestReference: nil,
            candidateSequence: String(repeating: "ACGT", count: 6),
            selectedSampleID: "CR1178",
            selectedSampleReadCount: 8,
            comments: [("Candidate note", "Review before release.")],
            warning: "Saved result predates candidate visualization artifacts."
        )

        XCTAssertEqual(view.currentMode, .overview)
        XCTAssertTrue(try XCTUnwrap(find("candidateModeControl", in: view)).isHidden)
        let fallback = try XCTUnwrap(text("candidateFallbackNote", in: view))
        XCTAssertFalse(fallback.contains("candidate sequence"))
        XCTAssertTrue(fallback.contains("closest-reference visualization"))
        XCTAssertTrue(fallback.contains("fresh analysis"))
        XCTAssertEqual(text("candidateAlleleName", in: view), "Mafa-A1*067:01_2nt_nov")
        XCTAssertEqual(text("candidateStableClusterID", in: view), "cluster-a")
        XCTAssertEqual(text("candidateClosestRawReferenceID", in: view), "Unavailable")
        XCTAssertTrue(
            try XCTUnwrap(find("candidateClosestReferenceOverview", in: view))
                .isHiddenOrHasHiddenAncestor
        )
        XCTAssertEqual(view.intrinsicContentSize.height, 250)
        XCTAssertEqual(
            text("candidateWarning", in: view),
            "Saved result predates candidate visualization artifacts."
        )
        assertFallbackNoteOccupiesVisibleLayout(in: view)
        assertCandidateFactsAndCommentsAreVisible(in: view)

        let descendantCount = descendants(of: view).count
        let activeConstraintCount = activeConstraints(in: view).count
        let activeConstraintSnapshot = constraintSnapshot(activeConstraints(in: view))
        for _ in 0..<100 {
            view.configure(
                candidate: candidate,
                closestReference: nil,
                candidateSequence: String(repeating: "ACGT", count: 6),
                selectedSampleID: "CR1178",
                selectedSampleReadCount: 8,
                comments: [("Candidate note", "Review before release.")],
                warning: "Saved result predates candidate visualization artifacts."
            )
        }
        XCTAssertEqual(descendants(of: view).count, descendantCount)
        XCTAssertEqual(activeConstraints(in: view).count, activeConstraintCount)
        XCTAssertEqual(
            constraintSnapshot(activeConstraints(in: view)),
            activeConstraintSnapshot
        )

        let visible = visibleText(in: view)
        XCTAssertFalse(visible.contains("unmatched-to-reference.bam"))
        XCTAssertFalse(visible.contains("selected-read"))
        XCTAssertFalse(visible.contains("2=1X"))
        XCTAssertEqual(
            visible.components(separatedBy: "Saved result predates candidate visualization artifacts.").count,
            2,
            "The warning should be rendered once."
        )
    }

    private func makeView() -> GenotypeCandidateAlleleDetailView {
        let view = GenotypeCandidateAlleleDetailView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 620)
        )
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func makeCandidate(
        stableClusterID: String = "cluster-a",
        provisionalName: String = "Mafa-A1*067:01_2nt_nov",
        cigar: String = "2=1X2=2I2=2D1=1X3=1X"
    ) -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: stableClusterID,
            provisionalName: provisionalName,
            locus: "Mafa-A1",
            classification: .novel,
            supportClass: .shared,
            closestReferenceName: "Mafa-A1*063:01",
            closestReferenceClass: .genomicDNA,
            snpCount: 3,
            insertedBases: 2,
            deletedBases: 2,
            longGapBases: 20,
            comparableBases: 20,
            shorterCoverage: 0.95,
            identity: 0.99,
            mappingQuality: 60,
            alignmentScore: 1_800,
            independentSampleCount: 2,
            occurrenceCount: 2,
            totalClusterReads: 14,
            supportingSampleIDs: ["CR1178", "CR1180"],
            fastaRecordID: stableClusterID,
            sequenceSHA256: String(repeating: "b", count: 64),
            selectedEvidence: .init(
                bamPath: "artifacts/alignments/unmatched-to-reference.bam",
                queryName: "selected-read-\(stableClusterID)",
                referenceName: "NHP0068",
                readGroupID: "CR1178",
                referenceStart: 1,
                cigar: cigar
            )
        )
    }

    private func makeReference(sequenceLength: Int = 24) -> ONTMHCReferenceVisualizationRecord {
        let sequence = String(repeating: "A", count: sequenceLength)
        return ONTMHCReferenceVisualizationRecord(
            rawReferenceID: "NHP0068",
            sourceOrdinal: 1,
            alleleName: "Mafa-A1*063:01",
            locus: "Mafa-A1",
            sequence: sequence,
            sequenceSHA256: "test-checksum",
            recordFields: ["DEFINITION": ["MHC class I allele"]],
            features: sequenceLength >= 18 ? [
                feature(start: 2, end: 6, ordinal: 1, numberKey: "exon_number", number: "2"),
                feature(start: 14, end: 18, ordinal: 2, numberKey: "number", number: "4"),
            ] : [],
            annotatedTranslation: nil,
            genBankText: "LOCUS       NHP0068 24 bp DNA\nFEATURES             Location/Qualifiers\n//\n",
            fastaText: ">NHP0068 Mafa-A1*063:01\n\(sequence)\n",
            roles: [.init(role: .closestNovelReference, candidateStableClusterIDs: ["cluster-a"])]
        )
    }

    private func feature(
        start: Int,
        end: Int,
        ordinal: Int,
        numberKey: String,
        number: String
    ) -> ONTMHCReferenceVisualizationFeature {
        ONTMHCReferenceVisualizationFeature(
            type: "exon",
            start: start,
            end: end,
            strand: "+",
            sourceOrdinal: ordinal,
            rawGenBankLocation: "\(start + 1)..\(end)",
            qualifiers: [numberKey: [number]]
        )
    }

    private func button(_ identifier: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(find(identifier, in: view) as? NSButton)
    }

    private func modeButton(_ identifier: String, in view: NSView) throws -> NSButton {
        try button(identifier, in: view)
    }

    private func textView(_ identifier: String, in view: NSView) throws -> NSTextView {
        try XCTUnwrap(find(identifier, in: view) as? NSTextView)
    }

    private func find(_ identifier: String, in root: NSView) -> NSView? {
        ([root] + descendants(of: root)).first { $0.accessibilityIdentifier() == identifier }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func activeConstraints(in root: NSView) -> [NSLayoutConstraint] {
        ([root] + descendants(of: root)).flatMap(\.constraints).filter(\.isActive)
    }

    private struct ConstraintSignature: Hashable {
        let firstItem: ObjectIdentifier?
        let firstAttribute: Int
        let relation: Int
        let secondItem: ObjectIdentifier?
        let secondAttribute: Int
        let multiplier: CGFloat
        let constant: CGFloat
        let priority: Float
        let identifier: String?
    }

    private func constraintSnapshot(
        _ constraints: [NSLayoutConstraint]
    ) -> [ConstraintSignature: Int] {
        Dictionary(constraints.map { constraint in
            let signature = ConstraintSignature(
                firstItem: constraint.firstItem.map { ObjectIdentifier($0 as AnyObject) },
                firstAttribute: constraint.firstAttribute.rawValue,
                relation: constraint.relation.rawValue,
                secondItem: constraint.secondItem.map { ObjectIdentifier($0 as AnyObject) },
                secondAttribute: constraint.secondAttribute.rawValue,
                multiplier: constraint.multiplier,
                constant: constraint.constant,
                priority: constraint.priority.rawValue,
                identifier: constraint.identifier
            )
            return (signature, 1)
        }, uniquingKeysWith: +)
    }

    private func text(_ identifier: String, in root: NSView) -> String? {
        (find(identifier, in: root) as? NSTextField)?.stringValue
    }

    private func assertCandidateFactsAndCommentsAreVisible(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in [
            "candidateStableClusterID",
            "candidateClassification",
            "candidateSupportClass",
            "candidateTotalReads",
            "candidateClosestAllele",
            "candidateClosestRawReferenceID",
            "candidateClosestReferenceClass",
            "candidateExtensionOf",
            "candidateCommentLabel.0",
            "candidateCommentBody.0",
            "candidateFallbackNote",
        ] {
            guard let identified = find(identifier, in: root) else {
                XCTFail("Missing \(identifier)", file: file, line: line)
                continue
            }
            XCTAssertFalse(
                identified.isHiddenOrHasHiddenAncestor,
                "\(identifier) should remain visible in fallback.",
                file: file,
                line: line
            )
        }
    }

    private func assertFallbackNoteOccupiesVisibleLayout(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        root.layoutSubtreeIfNeeded()
        guard let fallback = find("candidateFallback", in: root),
              let note = find("candidateFallbackNote", in: root) else {
            XCTFail("Missing fallback layout", file: file, line: line)
            return
        }
        let noteFrame = note.convert(note.bounds, to: fallback)
        XCTAssertLessThan(
            fallback.bounds.height,
            1_000,
            "Fallback layout should remain bounded.",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            noteFrame.intersection(fallback.bounds).height,
            0,
            "Fallback explanation should occupy visible layout.",
            file: file,
            line: line
        )
    }

    private func visibleText(in root: NSView) -> String {
        ([root] + descendants(of: root))
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
            .joined(separator: "\n")
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
}
