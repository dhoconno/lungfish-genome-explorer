import AppKit
import LungfishCore
import LungfishKit
import XCTest
@testable import LungfishTwelveSUI
@testable import LungfishIO

@MainActor
final class TwelveSAmpliconResultViewControllerTests: XCTestCase {
    func testPrimaryContentTypographyUsesResolvedMetricsWithoutRecomputingResults() throws {
        try preservingTwelveSContentTextSizePreference {
            let settings = AppSettings.shared
            settings.contentTextSizePreference = .system
            settings.save()
            let provider = MutableTwelveSFontProvider(pointSize: 13)
            let controller = TwelveSAmpliconResultViewController()
            controller.view.frame = NSRect(x: 0, y: 0, width: 860, height: 640)
            controller.testingSetContentPreferredFontProvider(provider)
            controller.configure(result: makeResult())
            controller.showUnresolvedForTesting()
            controller.setSearchTextForTesting("a")
            controller.testingSetUnresolvedSort(key: "sequenceID", ascending: true)
            controller.testingSelectUnresolvedRow(0)
            controller.testingSetActiveTableColumnWidth(identifier: "sequence", width: 223)
            controller.testingSetActiveTableScrollOriginY(7)

            try withSafeTwelveSHostWindow(
                content: controller.view,
                size: controller.view.frame.size
            ) { window in
                controller.view.layoutSubtreeIfNeeded()
                let searchField = controller.testingHeaderSearchField
                XCTAssertTrue(window.makeFirstResponder(searchField))
                let responder = try XCTUnwrap(window.firstResponder)
                let baseline = controller.testingPrimaryContentMetrics
                let baselineState = controller.testingPreservedState
                let baselineComputations = controller.testingScientificComputationCounts
                let baselineTypographyCounts = controller.testingTypographyApplicationCounts

                provider.pointSize = 24
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()

                let enlarged = controller.testingPrimaryContentMetrics
                XCTAssertEqual(enlarged.titleFontPointSize, 18 * 24 / 13, accuracy: 0.01)
                XCTAssertEqual(enlarged.summaryFontPointSize, 12 * 24 / 13, accuracy: 0.01)
                XCTAssertEqual(enlarged.searchFontPointSize, 24, accuracy: 0.01)
                XCTAssertEqual(enlarged.targetCellFontPointSize, 24, accuracy: 0.01)
                XCTAssertEqual(enlarged.unresolvedCellFontPointSize, 11 * 24 / 13, accuracy: 0.01)
                XCTAssertGreaterThan(enlarged.targetRowHeight, baseline.targetRowHeight)
                XCTAssertGreaterThan(enlarged.unresolvedRowHeight, baseline.unresolvedRowHeight)
                XCTAssertGreaterThan(enlarged.targetHeaderHeight, baseline.targetHeaderHeight)
                XCTAssertGreaterThan(enlarged.unresolvedHeaderHeight, baseline.unresolvedHeaderHeight)
                XCTAssertGreaterThan(enlarged.searchHeight, baseline.searchHeight)
                XCTAssertEqual(controller.testingPreservedState, baselineState)
                XCTAssertEqual(controller.testingScientificComputationCounts, baselineComputations)
                XCTAssertEqual(
                    controller.testingTypographyApplicationCounts,
                    .init(
                        controller: baselineTypographyCounts.controller + 1,
                        targetTable: baselineTypographyCounts.targetTable + 1,
                        unresolvedTable: baselineTypographyCounts.unresolvedTable + 1
                    )
                )
                XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(window.firstResponder)), ObjectIdentifier(responder))
                XCTAssertFalse(controller.testingHasAmbiguousPrimaryLayout)

                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()
                let repeated = controller.testingPrimaryContentMetrics
                XCTAssertEqual(repeated, enlarged)
                XCTAssertEqual(controller.testingPreservedState, baselineState)
                XCTAssertEqual(controller.testingScientificComputationCounts, baselineComputations)
                XCTAssertEqual(
                    controller.testingTypographyApplicationCounts,
                    .init(
                        controller: baselineTypographyCounts.controller + 2,
                        targetTable: baselineTypographyCounts.targetTable + 2,
                        unresolvedTable: baselineTypographyCounts.unresolvedTable + 2
                    )
                )

                provider.pointSize = 13
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()
                let recovered = controller.testingPrimaryContentMetrics
                XCTAssertEqual(recovered.titleFontPointSize, baseline.titleFontPointSize, accuracy: 0.01)
                XCTAssertEqual(recovered.summaryFontPointSize, baseline.summaryFontPointSize, accuracy: 0.01)
                XCTAssertEqual(recovered.searchFontPointSize, baseline.searchFontPointSize, accuracy: 0.01)
                XCTAssertEqual(recovered.targetRowHeight, baseline.targetRowHeight, accuracy: 0.01)
                XCTAssertEqual(recovered.unresolvedRowHeight, baseline.unresolvedRowHeight, accuracy: 0.01)
                XCTAssertEqual(
                    controller.testingActiveTableColumnWidths["sequence"] ?? 0,
                    223,
                    accuracy: 0.01
                )
                XCTAssertEqual(controller.testingPreservedState, baselineState)
                XCTAssertEqual(controller.testingScientificComputationCounts, baselineComputations)

                settings.contentTextSizePreference = .custom(100)
                settings.save()
                controller.view.layoutSubtreeIfNeeded()
                let customBaseline = controller.testingPrimaryContentMetrics
                XCTAssertEqual(customBaseline.titleFontPointSize, 18, accuracy: 0.01)
                XCTAssertEqual(customBaseline.summaryFontPointSize, 12, accuracy: 0.01)
                XCTAssertEqual(customBaseline.searchFontPointSize, 13, accuracy: 0.01)

                settings.contentTextSizePreference = .custom(200)
                settings.save()
                controller.view.layoutSubtreeIfNeeded()
                let customEnlarged = controller.testingPrimaryContentMetrics
                XCTAssertEqual(customEnlarged.titleFontPointSize, 36, accuracy: 0.01)
                XCTAssertEqual(customEnlarged.summaryFontPointSize, 24, accuracy: 0.01)
                XCTAssertEqual(customEnlarged.searchFontPointSize, 26, accuracy: 0.01)
                XCTAssertEqual(customEnlarged.targetCellFontPointSize, 26, accuracy: 0.01)
                XCTAssertEqual(customEnlarged.unresolvedCellFontPointSize, 22, accuracy: 0.01)
                NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(controller.testingPrimaryContentMetrics, customEnlarged)

                settings.contentTextSizePreference = .custom(100)
                settings.save()
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(controller.testingPrimaryContentMetrics, customBaseline)
                XCTAssertEqual(controller.testingPreservedState, baselineState)
                XCTAssertEqual(controller.testingScientificComputationCounts, baselineComputations)
            }
        }
    }

    func testTypographyObserverTearsDownWithController() {
        weak var released: TwelveSAmpliconResultViewController?
        autoreleasepool {
            let controller = TwelveSAmpliconResultViewController()
            _ = controller.view
            released = controller
        }
        XCTAssertNil(released)
    }

    func testTargetTableUsesFixedColumnsAndSampleEvidenceDetailPane() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        controller.configure(result: makeResult())

        XCTAssertEqual(controller.visibleTargetRowCount, 3)
        XCTAssertEqual(
            controller.tableColumnIdentifiers,
            [
                "sampleName",
                "scientificName",
                "commonNames",
                "taxonGroups",
                "taxids",
                "totalExactReads",
                "samplePercent",
                "referenceTargets",
                "alternateMatchCount",
            ]
        )
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "sampleName"), "Sample A")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "totalExactReads"), "13")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "alternateMatchCount"), "2")

        controller.selectTargetForTesting(row: 0)

        XCTAssertEqual(
            controller.testingDetailSampleRows.map(\.sampleID),
            ["SampleA"]
        )
        XCTAssertEqual(controller.testingDetailSampleRows.map(\.exactReads), [13])
        XCTAssertEqual(
            controller.testingAlternateMatchTexts,
            ["Heidelberg man (Homo heidelbergensis)", "Neanderthal (Homo neanderthalensis)"]
        )
        XCTAssertEqual(controller.summaryTextForTesting, "2 samples | 20 exact reads | 47.4% unresolved | 1 chimera candidate")
    }

    func testTargetTableShowsOneRowPerSampleWithSpeciesReads() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        controller.applyDisplayState(TwelveSResultDisplayState(filterText: "homo"))

        XCTAssertEqual(controller.visibleTargetRowCount, 2)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "sampleName"), "Sample A")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "totalExactReads"), "13")
        XCTAssertEqual(controller.testingTargetText(row: 1, column: "sampleName"), "Blank")
        XCTAssertEqual(controller.testingTargetText(row: 1, column: "scientificName"), "Homo sapiens")
        XCTAssertEqual(controller.testingTargetText(row: 1, column: "totalExactReads"), "2")
        XCTAssertFalse(controller.tableColumnIdentifiers.contains("topSample"))
    }

    func testDoesNotCreatePerSampleColumnsForLargeCohorts() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        controller.configure(result: makeResult(sampleCount: 120))

        XCTAssertFalse(controller.tableColumnIdentifiers.contains { $0.hasPrefix("sample:") })
        XCTAssertEqual(controller.tableColumnIdentifiers.count, 9)
    }

    func testAppliesInspectorMinimumExactReadFilter() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        controller.applyDisplayState(TwelveSResultDisplayState(minimumExactReads: 10))

        XCTAssertEqual(controller.visibleTargetRowCount, 1)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")
    }

    func testAppliesInspectorTextFilterAcrossScientificNameAndPotentialMatches() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        controller.applyDisplayState(TwelveSResultDisplayState(filterText: "canis"))

        XCTAssertEqual(controller.visibleTargetRowCount, 1)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Canis lupus familiaris")
    }

    func testInspectorTextFilterMatchesSampleNamesAfterProjection() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        controller.applyDisplayState(TwelveSResultDisplayState(filterText: "blank"))

        XCTAssertEqual(controller.visibleTargetRowCount, 1)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "sampleName"), "Blank")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "totalExactReads"), "2")
    }

    func testLargeSparseTargetFilterStaysInteractive() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeLargeSparseResult(targetCount: 90_000, sampleCount: 19, nonZeroTargetCount: 4_000))

        let start = CFAbsoluteTimeGetCurrent()
        controller.applyDisplayState(TwelveSResultDisplayState(filterText: "needle species 3999"))
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.35, "Filtering a sparse 90k-target 12S result should stay interactive")
        XCTAssertEqual(controller.visibleTargetRowCount, 1)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Needle species 3999")
    }

    func testRealBundlePerformanceWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_12S_PERF_BUNDLE"], !path.isEmpty else {
            throw XCTSkip("Set LUNGFISH_12S_PERF_BUNDLE to run the local 12S bundle performance check")
        }
        let bundleURL = URL(fileURLWithPath: path)

        let loadStart = CFAbsoluteTimeGetCurrent()
        let result = try TwelveSAmpliconResultBundle.loadResult(from: bundleURL, loadUnresolvedSequences: false)
        let loadElapsed = CFAbsoluteTimeGetCurrent() - loadStart

        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        let configureStart = CFAbsoluteTimeGetCurrent()
        controller.configure(result: result)
        let configureElapsed = CFAbsoluteTimeGetCurrent() - configureStart

        let filterStart = CFAbsoluteTimeGetCurrent()
        controller.applyDisplayState(TwelveSResultDisplayState(filterText: "homo"))
        let filterElapsed = CFAbsoluteTimeGetCurrent() - filterStart

        XCTAssertLessThan(loadElapsed, 2.0, "Loading the target summary should not parse unresolved sequences or rebuild aggregates repeatedly")
        XCTAssertLessThan(configureElapsed, 1.0, "Configuring the 12S viewport should use sparse cached rows")
        XCTAssertLessThan(filterElapsed, 0.35, "Filtering the 12S viewport should stay interactive")
        XCTAssertGreaterThan(controller.visibleTargetRowCount, 0)
    }

    func testViewportHeaderSearchFieldFiltersTargetRows() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        let searchField = findDescendant(ofType: NSSearchField.self, in: controller.view)
        XCTAssertEqual(searchField?.accessibilityIdentifier(), "twelve-s-search-field")
        XCTAssertEqual(searchField?.placeholderString, "Filter species or matches")

        controller.setSearchTextForTesting("canis")

        XCTAssertEqual(controller.visibleTargetRowCount, 1)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Canis lupus familiaris")
        XCTAssertEqual(searchField?.stringValue, "canis")
    }

    func testViewportSearchFieldMirrorsProgrammaticDisplayState() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        controller.applyDisplayState(TwelveSResultDisplayState(filterText: "homo"))

        let searchField = findDescendant(ofType: NSSearchField.self, in: controller.view)
        XCTAssertEqual(searchField?.stringValue, "homo")
    }

    func testUnresolvedModeShowsUnresolvedSequences() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        var summaries: [TwelveSResultDisplaySummary] = []
        controller.onDisplaySummaryChanged = { summaries.append($0) }
        controller.configure(result: makeResult())

        controller.showUnresolvedForTesting()

        XCTAssertEqual(controller.visibleUnresolvedRowCount, 2)
        XCTAssertEqual(summaries.last?.rowLabel, "Unmatched Sequences")
        XCTAssertEqual(summaries.last?.visibleRows, 2)
        XCTAssertEqual(summaries.last?.totalRows, 2)
        XCTAssertEqual(
            controller.tableColumnIdentifiers,
            ["sequenceID", "readCount", "sampleCount", "chimeraStatus", "sequence"]
        )
    }

    func testActionBarExportMenuOffersAllCLIBackedFormats() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(
            controller.testingExportMenuTitles,
            ["Export as CSV...", "Export as TSV...", "Export as Excel..."]
        )
        XCTAssertTrue(controller.testingHasProvenanceAction)
    }

    func testHeaderIsPinnedBelowWindowSafeArea() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        let titleLabel = findTextField(withString: "12S Amplicon Matches", in: controller.view)
        let headerRow = titleLabel?.superview

        XCTAssertNotNil(headerRow)
        let pinsHeaderToSafeArea = controller.view.constraints.contains { constraint in
            guard constraint.firstAttribute == .top,
                  constraint.secondAttribute == .top,
                  let firstItem = constraint.firstItem as AnyObject?,
                  let secondItem = constraint.secondItem as AnyObject?,
                  let headerRow
            else {
                return false
            }
            return firstItem === headerRow && secondItem === controller.view.safeAreaLayoutGuide
        }
        XCTAssertTrue(pinsHeaderToSafeArea)
    }

    func testInspectorTaxonAndHumanFiltersApplyToTargets() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        controller.applyDisplayState(TwelveSResultDisplayState(
            includedTaxonGroups: ["Mammal"],
            excludeHuman: true
        ))

        XCTAssertEqual(controller.visibleTargetRowCount, 1)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Canis lupus familiaris")
    }

    func testInspectorTaxonFiltersUseInferredGroupsWhenReferenceMetadataIsAbsent() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult(includeTaxonGroups: false))

        controller.applyDisplayState(TwelveSResultDisplayState(
            includedTaxonGroups: ["Mammal"],
            excludeHuman: true
        ))

        XCTAssertEqual(controller.visibleTargetRowCount, 1)
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Canis lupus familiaris")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "taxonGroups"), "Mammal")
    }

    func testUnresolvedFilterAndBlastRequestUseVisibleClusters() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())
        var request: TwelveSUnresolvedBlastRequest?
        controller.onUnresolvedBlastRequested = { request = $0 }

        controller.applyDisplayState(TwelveSResultDisplayState(minimumUnresolvedReads: 10))
        controller.showUnresolvedForTesting()
        controller.triggerUnresolvedBlastForTesting()

        XCTAssertEqual(controller.visibleUnresolvedRowCount, 1)
        XCTAssertEqual(request?.minimumReads, 10)
        XCTAssertEqual(request?.sequences.map(\.sequenceID), ["unresolved_1"])
    }

    func testBlastLoadingCreatesBottomDrawerHost() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        controller.showBlastLoading(phase: .submitting, requestId: nil)

        XCTAssertNotNil(findDescendant(ofType: BlastResultsDrawerContainerView.self, in: controller.view))
    }

    func testActiveTableHostsRowsAndSwitchesWithMode() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        XCTAssertEqual(controller.testingActiveMode, .targets)
        XCTAssertEqual(controller.testingActiveTableRowCount, 3)

        controller.showUnresolvedForTesting()
        XCTAssertEqual(controller.testingActiveMode, .unresolved)
        XCTAssertEqual(controller.testingActiveTableRowCount, 2)
    }

    func testDefaultTargetSortIsExactReadsDescending() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()
        controller.configure(result: makeResult())

        // Homo sapiens in Sample A (13 exact reads) sorts above dog (5) and Blank human (2).
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "sampleName"), "Sample A")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "totalExactReads"), "13")
        XCTAssertEqual(controller.testingTargetText(row: 1, column: "scientificName"), "Canis lupus familiaris")
    }

    private func makeResult(
        sampleCount: Int = 2,
        includeTaxonGroups: Bool = true
    ) -> TwelveSAmpliconResultBundleData {
        let bundleURL = URL(fileURLWithPath: "/tmp/example.lungfish12s")
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "example",
            analysisName: "Example",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            unresolvedTablePath: "unresolved-sequences.tsv",
            unresolvedFastaPath: "unresolved-sequences.fasta",
            provenancePath: ".lungfish-provenance.json"
        )
        let samples = (0..<sampleCount).map { index -> TwelveSAmpliconSampleResult in
            if index == 0 {
                return TwelveSAmpliconSampleResult(
                    sampleID: "SampleA",
                    displayName: "Sample A",
                    inputReads: 30,
                    exactMatchReads: 18,
                    unresolvedReads: 12,
                    ambiguousExactReads: 0,
                    chimeraCandidateReads: 3,
                    exactMatchPercent: 60,
                    unresolvedPercent: 40
                )
            }
            if index == 1 {
                return TwelveSAmpliconSampleResult(
                    sampleID: "Blank",
                    displayName: "Blank",
                    inputReads: 8,
                    exactMatchReads: 2,
                    unresolvedReads: 6,
                    ambiguousExactReads: 0,
                    chimeraCandidateReads: 0,
                    exactMatchPercent: 25,
                    unresolvedPercent: 75
                )
            }
            let sampleID = "Sample\(index)"
            return TwelveSAmpliconSampleResult(
                sampleID: sampleID,
                displayName: sampleID,
                inputReads: 0,
                exactMatchReads: 0,
                unresolvedReads: 0,
                ambiguousExactReads: 0,
                chimeraCandidateReads: 0,
                exactMatchPercent: 0,
                unresolvedPercent: 0
            )
        }
        let targets = [
            TwelveSAmpliconTarget(
                targetID: "human-a",
                displayName: "human (Homo sapiens)",
                scientificName: "Homo sapiens",
                commonName: "human",
                taxid: "9606",
                taxonGroup: includeTaxonGroups ? "Mammal" : nil,
                sourceHeader: "human (Homo sapiens)|also_matches=Heidelberg man (Homo heidelbergensis)",
                alternateMatches: [
                    TwelveSAlternateMatch(
                        displayName: "Heidelberg man (Homo heidelbergensis)",
                        scientificName: "Homo heidelbergensis",
                        commonName: "Heidelberg man",
                        taxid: "1425170",
                        taxonGroup: includeTaxonGroups ? "Mammal" : nil
                    ),
                ]
            ),
            TwelveSAmpliconTarget(
                targetID: "human-b",
                displayName: "ancient human (Homo sapiens)",
                scientificName: "Homo sapiens",
                commonName: "ancient human",
                taxid: "9606",
                taxonGroup: includeTaxonGroups ? "Mammal" : nil,
                sourceHeader: "ancient human (Homo sapiens)|also_matches=Neanderthal (Homo neanderthalensis)",
                alternateMatches: [
                    TwelveSAlternateMatch(
                        displayName: "Neanderthal (Homo neanderthalensis)",
                        scientificName: "Homo neanderthalensis",
                        commonName: "Neanderthal",
                        taxid: "63221",
                        taxonGroup: includeTaxonGroups ? "Mammal" : nil
                    ),
                ]
            ),
            TwelveSAmpliconTarget(
                targetID: "dog",
                displayName: "dog (Canis lupus familiaris)",
                scientificName: "Canis lupus familiaris",
                commonName: "dog",
                taxid: "9615",
                taxonGroup: includeTaxonGroups ? "Mammal" : nil
            ),
        ]
        return TwelveSAmpliconResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: TwelveSAmpliconResultArtifacts(
                referenceURL: bundleURL.appendingPathComponent("reference.fa"),
                targetTableURL: bundleURL.appendingPathComponent("targets.tsv"),
                countMatrixURL: bundleURL.appendingPathComponent("sample-target-counts.tsv"),
                sampleTableURL: bundleURL.appendingPathComponent("samples.tsv"),
                readFateURL: bundleURL.appendingPathComponent("read-fate.json"),
                unresolvedTableURL: bundleURL.appendingPathComponent("unresolved-sequences.tsv"),
                unresolvedFastaURL: bundleURL.appendingPathComponent("unresolved-sequences.fasta"),
                provenanceURL: bundleURL.appendingPathComponent(".lungfish-provenance.json")
            ),
            samples: samples,
            targets: targets,
            countRows: [
                "human-a": ["SampleA": 10, "Blank": 2],
                "human-b": ["SampleA": 3, "Blank": 0],
                "dog": ["SampleA": 5, "Blank": 0],
            ],
            readFate: TwelveSAmpliconReadFate(
                totalReads: 38,
                exactMatchReads: 20,
                unresolvedReads: 18,
                ambiguousExactReads: 0,
                chimeraCandidateReads: 3
            ),
            unresolvedSequences: [
                TwelveSUnresolvedSequence(
                    sequenceID: "unresolved_1",
                    sequence: "ACGTACGT",
                    readCount: 21,
                    sampleCounts: ["SampleA": 15, "Blank": 6],
                    chimeraStatus: .candidate
                ),
                TwelveSUnresolvedSequence(
                    sequenceID: "unresolved_2",
                    sequence: "TGCATGCA",
                    readCount: 4,
                    sampleCounts: ["Blank": 4],
                    chimeraStatus: .notDetected
                )
            ]
        )
    }

    private func makeLargeSparseResult(
        targetCount: Int,
        sampleCount: Int,
        nonZeroTargetCount: Int
    ) -> TwelveSAmpliconResultBundleData {
        let bundleURL = URL(fileURLWithPath: "/tmp/large-sparse.lungfish12s")
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "large-sparse",
            analysisName: "Large Sparse",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            unresolvedTablePath: "unresolved-sequences.tsv",
            unresolvedFastaPath: "unresolved-sequences.fasta",
            provenancePath: ".lungfish-provenance.json"
        )
        let samples = (0..<sampleCount).map { index in
            TwelveSAmpliconSampleResult(
                sampleID: "Sample\(index)",
                displayName: "Sample \(index)",
                inputReads: 1_000,
                exactMatchReads: 1_000,
                unresolvedReads: 0,
                ambiguousExactReads: 0,
                chimeraCandidateReads: 0,
                exactMatchPercent: 100,
                unresolvedPercent: 0
            )
        }
        let targets = (0..<targetCount).map { index in
            TwelveSAmpliconTarget(
                targetID: "target-\(index)",
                displayName: "needle species \(index) (Needle species \(index))",
                scientificName: "Needle species \(index)",
                commonName: "needle species \(index)",
                taxid: "\(100_000 + index)",
                taxonGroup: index % 2 == 0 ? "Mammal" : "Fish"
            )
        }
        var countRows: [String: [String: Int]] = [:]
        for index in 0..<nonZeroTargetCount {
            countRows["target-\(index)"] = ["Sample\(index % sampleCount)": index + 1]
        }
        return TwelveSAmpliconResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: TwelveSAmpliconResultArtifacts(
                referenceURL: bundleURL.appendingPathComponent("reference.fa"),
                targetTableURL: bundleURL.appendingPathComponent("targets.tsv"),
                countMatrixURL: bundleURL.appendingPathComponent("sample-target-counts.tsv"),
                sampleTableURL: bundleURL.appendingPathComponent("samples.tsv"),
                readFateURL: bundleURL.appendingPathComponent("read-fate.json"),
                unresolvedTableURL: bundleURL.appendingPathComponent("unresolved-sequences.tsv"),
                unresolvedFastaURL: bundleURL.appendingPathComponent("unresolved-sequences.fasta"),
                provenanceURL: bundleURL.appendingPathComponent(".lungfish-provenance.json")
            ),
            samples: samples,
            targets: targets,
            countRows: countRows,
            readFate: TwelveSAmpliconReadFate(
                totalReads: sampleCount * 1_000,
                exactMatchReads: sampleCount * 1_000,
                unresolvedReads: 0,
                ambiguousExactReads: 0,
                chimeraCandidateReads: 0
            ),
            unresolvedSequences: []
        )
    }

    private func findTextField(withString string: String, in root: NSView?) -> NSTextField? {
        guard let root else { return nil }
        if let textField = root as? NSTextField, textField.stringValue == string {
            return textField
        }
        for subview in root.subviews {
            if let match = findTextField(withString: string, in: subview) {
                return match
            }
        }
        return nil
    }

    private func findDescendant<T: NSView>(ofType type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T {
            return match
        }
        for subview in root.subviews {
            if let match = findDescendant(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private func preservingTwelveSContentTextSizePreference(
    _ body: () throws -> Void
) rethrows {
    let settings = AppSettings.shared
    let original = settings.contentTextSizePreference
    defer {
        settings.contentTextSizePreference = original
        settings.save()
    }
    try body()
}

@MainActor
private final class MutableTwelveSFontProvider: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }
}

@MainActor
private func withSafeTwelveSHostWindow<T>(
    content: NSView,
    size: NSSize,
    _ body: (NSWindow) throws -> T
) rethrows -> T {
    try autoreleasepool {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        content.frame = host.bounds
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        window.contentView = host
        defer {
            _ = window.makeFirstResponder(nil)
            content.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }
        return try body(window)
    }
}
