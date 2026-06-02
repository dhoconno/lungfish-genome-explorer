import AppKit
import LungfishTwelveSUI
import XCTest
@testable import LungfishCore
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class InspectorTwelveSModeTests: XCTestCase {
    func testTwelveSResultDocumentEnablesResultSummaryControls() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updateTwelveSAmpliconResultDocument(makeResult())
        inspector.updateTwelveSResultDisplaySummary(TwelveSResultDisplaySummary(
            rowLabel: "Unmatched Sequences",
            visibleRows: 3,
            totalRows: 5
        ))

        XCTAssertTrue(inspector.twelveSResultDisplaySectionViewModel.isAvailable)
        XCTAssertEqual(inspector.twelveSResultDisplaySectionViewModel.summaryRowLabel, "Unmatched Sequences")
        XCTAssertEqual(inspector.twelveSResultDisplaySectionViewModel.visibleRowCount, 3)
        XCTAssertEqual(inspector.twelveSResultDisplaySectionViewModel.totalRowCount, 5)
        XCTAssertEqual(inspector.testingSelectedTab, .resultSummary)
    }

    func testTwelveSResultDocumentExposesResolvedSampleMetadata() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updateTwelveSAmpliconResultDocument(makeResult(
            sampleMetadata: ResolvedSampleMetadata(
                columns: ["sample_id", "sample_name", "site"],
                sampleIDs: ["hilo-f09"],
                records: [
                    "hilo-f09": ["sample_name": "Hilo influent", "site": "Hilo WWTP"],
                ]
            ),
            sampleMetadataManifest: TwelveSSampleMetadataSnapshotManifest(
                precedence: ["analysisOverride", "fastqBundle", "fastqFolder", "intrinsic"],
                emptyOverrideCells: "empty analysis metadata cells do not clear lower-precedence values",
                sampleCount: 1,
                columns: ["sample_id", "sample_name", "site"],
                sources: [
                    SampleMetadataSourceSummary(
                        kind: .analysisOverride,
                        path: "/tmp/metadata.tsv",
                        totalRows: 1,
                        matchedSampleCount: 1,
                        unmatchedRowCount: 0,
                        missingSampleCount: 0
                    ),
                ],
                warnings: []
            )
        ))

        let metadataStore = inspector.twelveSResultDisplaySectionViewModel.sampleMetadataStore
        XCTAssertEqual(metadataStore?.matchedSampleIds, Set(["hilo-f09"]))
        XCTAssertEqual(metadataStore?.columnNames, ["sample_name", "site"])
        XCTAssertEqual(metadataStore?.records["hilo-f09"]?["site"], "Hilo WWTP")
        XCTAssertEqual(inspector.twelveSResultDisplaySectionViewModel.sampleMetadataSourceSummary, "Analysis metadata")
        XCTAssertEqual(inspector.twelveSResultDisplaySectionViewModel.sampleMetadataSourceDetails, [
            "Analysis metadata · 1 of 1 matched · metadata.tsv",
        ])
    }

    func testTwelveSResultDocumentDistinguishesFrozenSampleListFromMetadataFields() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updateTwelveSAmpliconResultDocument(makeResult(sampleMetadata: ResolvedSampleMetadata(
            columns: ["sample_id"],
            sampleIDs: ["hilo-f09"],
            records: ["hilo-f09": [:]]
        )))

        XCTAssertNil(inspector.twelveSResultDisplaySectionViewModel.sampleMetadataStore)
        XCTAssertEqual(
            inspector.twelveSResultDisplaySectionViewModel.sampleMetadataSourceSummary,
            "Sample IDs frozen in result bundle"
        )
    }

    func testTwelveSResultDocumentLoadsPersistedImportedMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InspectorTwelveSModeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("metadata", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        sample,site
        hilo-f09,Hilo WWTP
        """.write(to: bundleURL.appendingPathComponent("metadata/sample_metadata.tsv"), atomically: true, encoding: .utf8)

        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.updateTwelveSAmpliconResultDocument(makeResult(bundleURL: bundleURL))

        let metadataStore = inspector.twelveSResultDisplaySectionViewModel.sampleMetadataStore
        XCTAssertEqual(metadataStore?.records["hilo-f09"]?["site"], "Hilo WWTP")
    }

    func testTwelveSResultDocumentMakesDetailTabAvailable() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.updateTwelveSAmpliconResultDocument(makeResult())

        XCTAssertTrue(inspector.twelveSDetailSectionViewModel.isAvailable)
        XCTAssertFalse(inspector.twelveSDetailSectionViewModel.hasDetail)
    }

    func testUpdateTwelveSDetailPopulatesAndAutoSelectsDetailTabOnce() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.updateTwelveSAmpliconResultDocument(makeResult())
        XCTAssertEqual(inspector.testingSelectedTab, .resultSummary)

        let detail = TwelveSDetailPayload(kind: .target(.init(
            scientificName: "Homo sapiens", totalExactReads: 50, referenceTargetCount: 2,
            sampleEvidence: [], alternateTexts: ["Homo heidelbergensis"])))
        inspector.updateTwelveSDetail(detail)

        XCTAssertTrue(inspector.twelveSDetailSectionViewModel.hasDetail)
        XCTAssertEqual(inspector.twelveSDetailSectionViewModel.title, "Homo sapiens")
        // first single selection auto-switches to Detail
        XCTAssertEqual(inspector.testingSelectedTab, .twelveSDetail)

        // clearing (multi/empty selection) keeps the tab but drops the detail
        inspector.updateTwelveSDetail(nil)
        XCTAssertFalse(inspector.twelveSDetailSectionViewModel.hasDetail)
        XCTAssertEqual(inspector.testingSelectedTab, .twelveSDetail)
    }

    func testDetailViewModelExposesReferenceSequences() {
        let vm = TwelveSDetailSectionViewModel()
        vm.apply(TwelveSDetailPayload(kind: .target(.init(
            scientificName: "Homo sapiens", totalExactReads: 1, referenceTargetCount: 2,
            sampleEvidence: [], alternateTexts: [],
            referenceSequences: [.init(targetID: "a", sequence: "ACGT"), .init(targetID: "b", sequence: "TTTT")]))))
        XCTAssertEqual(vm.referenceSequences.map(\.targetID), ["a", "b"])
        // unresolved / empty selections expose no reference sequences
        vm.clear()
        XCTAssertTrue(vm.referenceSequences.isEmpty)
    }

    func testClearTwelveSDetailResetsAvailability() {
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.updateTwelveSAmpliconResultDocument(makeResult())
        inspector.clearTwelveSDetail()

        XCTAssertFalse(inspector.twelveSDetailSectionViewModel.isAvailable)
        XCTAssertFalse(inspector.twelveSDetailSectionViewModel.hasDetail)
    }

    private func makeResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfish12s"),
        sampleMetadata: ResolvedSampleMetadata? = nil,
        sampleMetadataManifest: TwelveSSampleMetadataSnapshotManifest? = nil
    ) -> TwelveSAmpliconResultBundleData {
        return TwelveSAmpliconResultBundleData(
            bundleURL: bundleURL,
            manifest: TwelveSAmpliconResultBundleManifest(
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
            ),
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
            samples: [
                TwelveSAmpliconSampleResult(
                    sampleID: "hilo-f09",
                    displayName: "hilo-f09",
                    inputReads: 0,
                    exactMatchReads: 0,
                    unresolvedReads: 0,
                    ambiguousExactReads: 0,
                    chimeraCandidateReads: 0,
                    exactMatchPercent: 0,
                    unresolvedPercent: 0
                ),
            ],
            targets: [],
            countRows: [:],
            readFate: TwelveSAmpliconReadFate(
                totalReads: 0,
                exactMatchReads: 0,
                unresolvedReads: 0,
                ambiguousExactReads: 0,
                chimeraCandidateReads: 0
            ),
            unresolvedSequences: [],
            sampleMetadata: sampleMetadata,
            sampleMetadataManifest: sampleMetadataManifest
        )
    }
}
