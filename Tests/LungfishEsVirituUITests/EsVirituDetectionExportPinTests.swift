// EsVirituDetectionExportPinTests.swift - Pins the EsViritu detections export bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M1 (QA 1). These pins held the in-app writer, `writeDelimitedDetections`, until
// `esviritu export detections` replaced it. They now hold the builder the leaf calls, fed by the view's metadata
// columns. With a search, a sort, a column filter, a sample selection and one metadata column set, the bytes still
// hold every detection (ARCH ruling 1.2, the builder applies none of the view's search, sort or filters). The old
// writer's record facts are side A of `EsVirituExportCLIGUIParityReplayTests`, which freezes that writer, and the
// leaf's record is pinned by `EsVirituExportDetectionsCommandTests`.

import LungfishTestSupport
import XCTest
import AppKit
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishWorkflow
import LungfishKit
@testable import LungfishCore

final class EsVirituDetectionExportPinTests: XCTestCase {
    static let header = [
        "Sample ID", "Virus Name", "Accession", "Assembly", "Kingdom", "Phylum",
        "Class", "Order", "Family", "Genus", "Species", "Subspecies",
        "Read Count", "RPKMF", "Coverage", "Identity", "Covered Bases",
        "Nucleotide Diversity", "Assembly Length", "Filtered Reads",
        "Segment", "Length", "Group",
    ]

    @MainActor func testTSVBytesHoldEveryDetectionWhateverTheViewState() throws {
        let vc = try Self.configuredController()
        let expected = [
            Self.header.joined(separator: "\t"),
            "sample-A\tAlpha, virus\tNC_A\tGCF_A\tViruses\t\t\t\tTestviridae\t\tAlpha, virus\t\t40\t40.00\t1.00\t99.0\t100\t0.000000\t100\t1000\tS\t100\tcase",
            "sample-B\tBeta \"virus\"\tNC_B\tGCF_B\tViruses\t\t\t\tTestviridae\t\tBeta \"virus\"\t\t20\t20.00\t1.00\t99.0\t100\t0.000000\t100\t1000\t\t100\tcontrol",
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(Self.bytes(vc, result: Self.result, separator: "\t"), expected)
    }

    /// BIO ruling on 12.31 G1. A batch of two samples, as the view sets it for two (no current sample), writes each
    /// row's own sample values, so every line has as many fields as the header.
    @MainActor func testBatchOfTwoSamplesWritesEachRowsOwnMetadata() throws {
        let vc = try Self.configuredController()
        vc.samplePickerState.selectedSamples = ["sample-A", "sample-B"]
        vc.testDetectionTableView.metadataColumns.update(store: try Self.metadataStore(), sampleId: nil)

        let lines = Self.bytes(vc, result: Self.result, separator: "\t").split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.count == 3 && lines[1].hasPrefix("sample-A\t") && lines[1].hasSuffix("\tcase"), "\(lines)")
        XCTAssertTrue(lines.count == 3 && lines[2].hasPrefix("sample-B\t") && lines[2].hasSuffix("\tcontrol"), "\(lines)")
        XCTAssertEqual(lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).count }, [23, 23, 23])
    }

    /// One sample in the file keeps today's bytes.
    @MainActor func testOneSampleBytesAreUnchanged() throws {
        let vc = try Self.configuredController()
        let oneSample = LungfishIO.EsVirituResult(
            sampleId: "sample-A", detections: [Self.result.detections[0]], assemblies: [], taxProfile: [],
            coverageWindows: [], totalFilteredReads: 1_000, detectedFamilyCount: 1, detectedSpeciesCount: 1,
            runtime: nil, toolVersion: nil
        )
        XCTAssertEqual(Self.bytes(vc, result: oneSample, separator: "\t"), [
            Self.header.joined(separator: "\t"),
            "sample-A\tAlpha, virus\tNC_A\tGCF_A\tViruses\t\t\t\tTestviridae\t\tAlpha, virus\t\t40\t40.00\t1.00\t99.0\t100\t0.000000\t100\t1000\tS\t100\tcase",
        ].joined(separator: "\n") + "\n")
    }

    @MainActor func testCSVBytesQuoteOnlyFieldsTheBuilderEscapes() throws {
        let vc = try Self.configuredController()
        let expected = [
            Self.header.joined(separator: ","),
            "sample-A,\"Alpha, virus\",NC_A,GCF_A,Viruses,,,,Testviridae,,\"Alpha, virus\",,40,40.00,1.00,99.0,100,0.000000,100,1000,S,100,case",
            "sample-B,\"Beta \"\"virus\"\"\",NC_B,GCF_B,Viruses,,,,Testviridae,,\"Beta \"\"virus\"\"\",,20,20.00,1.00,99.0,100,0.000000,100,1000,,100,control",
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(Self.bytes(vc, result: Self.result, separator: ","), expected)
    }

    /// The batch result breaks read-count ties by sample id and then by assembly accession (BIO ruling on 12.31 G1).
    func testTiedAssembliesOrderBySampleThenAccession() {
        func assembly(_ accession: String, sample: String, reads: Int) -> ViralAssembly {
            ViralAssembly(
                assembly: accession, assemblyLength: 100, name: accession, family: nil, genus: nil, species: nil,
                totalReads: reads, rpkmf: 0, meanCoverage: 0, avgReadIdentity: 0,
                contigs: [Self.detection(name: accession, sampleId: sample, id: accession, reads: reads, segment: nil)]
            )
        }
        let unordered = [
            assembly("GCF_2", sample: "sample-B", reads: 20),
            assembly("GCF_9", sample: "sample-A", reads: 20),
            assembly("GCF_1", sample: "sample-A", reads: 20),
            assembly("GCF_5", sample: "sample-C", reads: 50),
        ]
        XCTAssertEqual(
            unordered.sorted(by: EsVirituDetectionExport.assemblyPrecedes).map(\.assembly),
            ["GCF_5", "GCF_1", "GCF_9", "GCF_2"]
        )
    }

    // MARK: - Fixture

    /// The bytes the leaf writes for these detections and the view's metadata columns, from the builder it calls.
    @MainActor private static func bytes(
        _ vc: EsVirituResultViewController,
        result: LungfishIO.EsVirituResult,
        separator: String
    ) -> String {
        let metadata = vc.testDetectionTableView.metadataColumns
        let sampleIds = Set(result.detections.map(\.sampleId))
        return EsVirituDetectionExport.buildDelimitedExport(
            result: result,
            separator: separator,
            metadataHeaders: metadata.exportHeaders,
            metadataValuesBySample: Dictionary(uniqueKeysWithValues: sampleIds.map { ($0, metadata.exportValues(for: $0)) })
        )
    }

    @MainActor private static func configuredController() throws -> EsVirituResultViewController {
        let vc = EsVirituResultViewController()
        let layouts = TestDefaultsSuite(prefix: "EsVirituDetectionExportPinTests")
        vc.testDetectionTableView.metadataColumns.userDefaults = layouts.defaults
        vc.testBatchTableView.metadataColumns.userDefaults = layouts.defaults
        _ = vc.view
        vc.isBatchMode = true
        vc.samplePickerState = ClassifierSamplePickerState(allSamples: Set(["sample-A", "sample-B"]))
        vc.samplePickerState.selectedSamples = ["sample-A"]
        let table = vc.testDetectionTableView
        table.testingSubmitSearchText("beta")
        table.columnHeaderFilterMenu(sortByKey: "name", ascending: true)
        table.columnHeaderFilterMenu(
            replaceFilterFor: "reads",
            with: ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "30")
        )
        table.columnHeaderFilterMenu(setComposition: .any)
        table.metadataColumns.visibleColumns = ["Group"]
        table.metadataColumns.update(store: try metadataStore(), sampleId: "sample-A")
        return vc
    }

    private static func metadataStore() throws -> SampleMetadataStore {
        try SampleMetadataStore(
            csvData: Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8),
            knownSampleIds: ["sample-A", "sample-B"]
        )
    }

    static let result = LungfishIO.EsVirituResult(
        sampleId: "esviritu-pin",
        detections: [
            detection(name: "Alpha, virus", sampleId: "sample-A", id: "A", reads: 40, segment: "S"),
            detection(name: "Beta \"virus\"", sampleId: "sample-B", id: "B", reads: 20, segment: nil),
        ],
        assemblies: [],
        taxProfile: [],
        coverageWindows: [],
        totalFilteredReads: 1_000,
        detectedFamilyCount: 1,
        detectedSpeciesCount: 2,
        runtime: nil,
        toolVersion: nil
    )

    private static func detection(name: String, sampleId: String, id: String, reads: Int, segment: String?) -> ViralDetection {
        ViralDetection(
            sampleId: sampleId, name: name, description: name, length: 100, segment: segment,
            accession: "NC_\(id)", assembly: "GCF_\(id)", assemblyLength: 100, kingdom: "Viruses",
            phylum: nil, tclass: nil, order: nil, family: "Testviridae", genus: nil, species: name,
            subspecies: nil, rpkmf: Double(reads), readCount: reads, coveredBases: 100, meanCoverage: 1,
            avgReadIdentity: 99, pi: 0, filteredReadsInSample: 1_000
        )
    }
}
