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

    private func makeResult(
        sampleMetadata: ResolvedSampleMetadata? = nil,
        sampleMetadataManifest: TwelveSSampleMetadataSnapshotManifest? = nil
    ) -> TwelveSAmpliconResultBundleData {
        let bundleURL = URL(fileURLWithPath: "/tmp/example.lungfish12s")
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
