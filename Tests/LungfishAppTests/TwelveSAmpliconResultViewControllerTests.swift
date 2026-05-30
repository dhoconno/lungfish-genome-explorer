import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class TwelveSAmpliconResultViewControllerTests: XCTestCase {
    func testTargetTableUsesFixedColumnsAndSampleEvidenceDetailPane() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        controller.configure(result: makeResult())

        XCTAssertEqual(controller.visibleTargetRowCount, 2)
        XCTAssertEqual(
            controller.tableColumnIdentifiers,
            [
                "scientificName",
                "commonNames",
                "taxonGroups",
                "taxids",
                "totalExactReads",
                "referenceTargets",
                "maxSamplePercent",
                "alternateMatchCount",
            ]
        )
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "scientificName"), "Homo sapiens")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "totalExactReads"), "15")
        XCTAssertEqual(controller.testingTargetText(row: 0, column: "alternateMatchCount"), "2")

        controller.selectTargetForTesting(row: 0)

        XCTAssertEqual(
            controller.testingDetailSampleRows.map(\.sampleID),
            ["SampleA", "Blank"]
        )
        XCTAssertEqual(controller.testingDetailSampleRows.map(\.exactReads), [13, 2])
        XCTAssertEqual(
            controller.testingAlternateMatchTexts,
            ["Heidelberg man (Homo heidelbergensis)", "Neanderthal (Homo neanderthalensis)"]
        )
        XCTAssertEqual(controller.summaryTextForTesting, "2 samples | 20 exact reads | 47.4% unresolved | 1 chimera candidate")
    }

    func testDoesNotCreatePerSampleColumnsForLargeCohorts() {
        let controller = TwelveSAmpliconResultViewController()
        controller.loadViewIfNeeded()

        controller.configure(result: makeResult(sampleCount: 120))

        XCTAssertFalse(controller.tableColumnIdentifiers.contains { $0.hasPrefix("sample:") })
        XCTAssertEqual(controller.tableColumnIdentifiers.count, 8)
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
