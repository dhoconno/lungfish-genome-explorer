// EsVirituDetectionExportPinTests.swift - Pins the EsViritu detections export at the 12.31 base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M1 (QA 1). These pins hold today's in-app writer, `writeDelimitedDetections`, before
// `esviritu export detections` replaces it. With a search, a sort, a column filter, a sample selection and one
// metadata column set, the bytes still hold every detection (ARCH ruling 1.2, the builder applies none of the view's
// search, sort or filters), and the record names the tool `Lungfish.app` with its own argv. The M3 parity class reads
// these facts as side A.

import XCTest
import AppKit
@testable import LungfishEsVirituUI
import LungfishIO
import struct LungfishWorkflow.EsVirituBatchAggregatedManifest
import LungfishWorkflow
import LungfishKit
@testable import LungfishCore

@MainActor
private final class EsVirituRecordingFailurePresenter: ExportFailurePresenting {
    private(set) var alerts: [(title: String, message: String)] = []
    func presentExportFailure(title: String, message: String, in window: NSWindow?) {
        alerts.append((title, message))
    }
}

final class EsVirituDetectionExportPinTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituDetectionExportPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static let header = [
        "Sample ID", "Virus Name", "Accession", "Assembly", "Kingdom", "Phylum",
        "Class", "Order", "Family", "Genus", "Species", "Subspecies",
        "Read Count", "RPKMF", "Coverage", "Identity", "Covered Bases",
        "Nucleotide Diversity", "Assembly Length", "Filtered Reads",
        "Segment", "Length", "Group",
    ]

    @MainActor func testTSVBytesHoldEveryDetectionWhateverTheViewState() throws {
        let vc = try Self.configuredController()
        let outputURL = folder.appendingPathComponent("detections.tsv")
        try vc.writeDelimitedDetections(result: Self.result, separator: "\t", fileExtension: "tsv", to: outputURL)

        let expected = [
            Self.header.joined(separator: "\t"),
            "sample-A\tAlpha, virus\tNC_A\tGCF_A\tViruses\t\t\t\tTestviridae\t\tAlpha, virus\t\t40\t40.00\t1.00\t99.00\t100\t0.000000\t100\t1000\tS\t100\tcase",
            "sample-B\tBeta \"virus\"\tNC_B\tGCF_B\tViruses\t\t\t\tTestviridae\t\tBeta \"virus\"\t\t20\t20.00\t1.00\t99.00\t100\t0.000000\t100\t1000\t\t100\tcontrol",
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), expected)
        try Self.assertRecord(outputURL: outputURL, format: "tsv")
    }

    /// BIO ruling on 12.31 G1. A batch of two samples, as the view sets it for two (no current sample), writes each
    /// row's own sample values, so every line has as many fields as the header.
    @MainActor func testBatchOfTwoSamplesWritesEachRowsOwnMetadata() throws {
        let vc = try Self.configuredController()
        vc.samplePickerState.selectedSamples = ["sample-A", "sample-B"]
        vc.testDetectionTableView.metadataColumns.update(store: try Self.metadataStore(), sampleId: nil)
        let outputURL = folder.appendingPathComponent("detections.tsv")
        try vc.writeDelimitedDetections(result: Self.result, separator: "\t", fileExtension: "tsv", to: outputURL)

        let lines = try String(contentsOf: outputURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("sample-A\t") && lines[1].hasSuffix("\tcase"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("sample-B\t") && lines[2].hasSuffix("\tcontrol"), lines[2])
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
        let outputURL = folder.appendingPathComponent("detections.tsv")
        try vc.writeDelimitedDetections(result: oneSample, separator: "\t", fileExtension: "tsv", to: outputURL)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), [
            Self.header.joined(separator: "\t"),
            "sample-A\tAlpha, virus\tNC_A\tGCF_A\tViruses\t\t\t\tTestviridae\t\tAlpha, virus\t\t40\t40.00\t1.00\t99.00\t100\t0.000000\t100\t1000\tS\t100\tcase",
        ].joined(separator: "\n") + "\n")
    }

    /// The record names the metadata files whose values the payload holds, with their digests, and names neither
    /// when no metadata column is shown (BIO 6).
    @MainActor func testMetadataFilesAreInputsWhenAColumnIsShown() throws {
        let resultFolder = folder.appendingPathComponent("esviritu-batch", isDirectory: true)
        let metadataFolder = resultFolder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadataFolder.appendingPathComponent("sample_metadata.tsv"))
        try Data("[]".utf8).write(to: metadataFolder.appendingPathComponent("sample_metadata_edits.json"))
        let vc = try Self.configuredController()
        vc.batchURL = resultFolder

        let shown = folder.appendingPathComponent("shown.tsv")
        try vc.writeDelimitedDetections(result: Self.result, separator: "\t", fileExtension: "tsv", to: shown)
        let inputs = try Self.inputs(of: shown)
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(), [
            "sample_metadata.tsv", "sample_metadata_edits.json",
        ])
        XCTAssertTrue(inputs.allSatisfy { $0.checksumSHA256 != nil })

        vc.testDetectionTableView.metadataColumns.visibleColumns = []
        let hidden = folder.appendingPathComponent("hidden.tsv")
        try vc.writeDelimitedDetections(result: Self.result, separator: "\t", fileExtension: "tsv", to: hidden)
        XCTAssertEqual(try Self.inputs(of: hidden).map(\.path), [])
    }

    /// The record never names the batch manifest, a display cache that no payload byte comes from (BIO ruling on
    /// 12.31 G3, G3-1).
    @MainActor func testBatchAggregatedManifestIsNotAnInput() throws {
        let resultFolder = folder.appendingPathComponent("esviritu-batch", isDirectory: true)
        let metadataFolder = resultFolder.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        try Data("Sample\tGroup\nsample-A\tcase\nsample-B\tcontrol\n".utf8)
            .write(to: metadataFolder.appendingPathComponent("sample_metadata.tsv"))
        try Data("[]".utf8).write(to: metadataFolder.appendingPathComponent("sample_metadata_edits.json"))
        try Data("{}".utf8).write(to: resultFolder.appendingPathComponent(EsVirituBatchAggregatedManifest.filename))
        let vc = try Self.configuredController()
        vc.batchURL = resultFolder

        let shown = folder.appendingPathComponent("shown.tsv")
        try vc.writeDelimitedDetections(result: Self.result, separator: "\t", fileExtension: "tsv", to: shown)
        XCTAssertEqual(try Self.inputs(of: shown).map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(), [
            "sample_metadata.tsv", "sample_metadata_edits.json",
        ])

        vc.testDetectionTableView.metadataColumns.visibleColumns = []
        let hidden = folder.appendingPathComponent("hidden.tsv")
        try vc.writeDelimitedDetections(result: Self.result, separator: "\t", fileExtension: "tsv", to: hidden)
        XCTAssertEqual(try Self.inputs(of: hidden).map(\.path), [])
    }

    private static func inputs(of outputURL: URL) throws -> [ProvenanceFileDescriptor] {
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        return envelope.files.filter { $0.role == .input }
    }

    @MainActor func testCSVBytesQuoteOnlyFieldsTheBuilderEscapes() throws {
        let vc = try Self.configuredController()
        let outputURL = folder.appendingPathComponent("detections.csv")
        try vc.writeDelimitedDetections(result: Self.result, separator: ",", fileExtension: "csv", to: outputURL)

        let expected = [
            Self.header.joined(separator: ","),
            "sample-A,\"Alpha, virus\",NC_A,GCF_A,Viruses,,,,Testviridae,,\"Alpha, virus\",,40,40.00,1.00,99.00,100,0.000000,100,1000,S,100,case",
            "sample-B,\"Beta \"\"virus\"\"\",NC_B,GCF_B,Viruses,,,,Testviridae,,\"Beta \"\"virus\"\"\",,20,20.00,1.00,99.00,100,0.000000,100,1000,,100,control",
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), expected)
        try Self.assertRecord(outputURL: outputURL, format: "csv")
    }

    /// A failed write reaches `ResultExportCoordinator.reportFailure`, whose words UX 1 keeps.
    @MainActor func testFailureAlertWords() throws {
        let vc = try Self.configuredController()
        let blocked = folder.appendingPathComponent("detections.tsv", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let presenter = EsVirituRecordingFailurePresenter()
        do {
            try vc.writeDelimitedDetections(result: Self.result, separator: "\t", fileExtension: "tsv", to: blocked)
            XCTFail("a folder in the output's place fails the export")
        } catch {
            ResultExportCoordinator.reportFailure(
                fileName: blocked.lastPathComponent, error: error, window: nil, presenter: presenter
            )
            XCTAssertEqual(presenter.alerts.map(\.title), ["Export Failed"])
            XCTAssertEqual(presenter.alerts.map(\.message), ["Could not write detections.tsv: \(error.localizedDescription)"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: blocked).path))
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

    @MainActor private static func configuredController() throws -> EsVirituResultViewController {
        let vc = EsVirituResultViewController()
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

    /// The record facts lane 12.31 predicts will move (tool, kind, argv, workflow name) and the `resolved` keys,
    /// among them the search, sort and filters the builder never applied.
    private static func assertRecord(outputURL: URL, format: String) throws {
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        let argv = ["Lungfish.app", "export-esviritu-detections", "--format", format, "--output", outputURL.path]
        XCTAssertEqual(envelope.workflowName, "lungfish app esviritu detections export")
        XCTAssertEqual(envelope.toolName, "Lungfish.app")
        XCTAssertEqual(envelope.tool.name, "Lungfish.app")
        XCTAssertEqual(envelope.tool.kind, "gui")
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.durableReplayArgv, argv)
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved.keys.sorted(), [
            "columnFilterComposition", "columnFilters", "metadataColumns", "rowCount", "sampleId",
            "searchText", "selectedSamples", "sortDescriptors", "sourceSampleCount", "tableMode",
        ])
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 2, "every detection, whatever the filters")
        XCTAssertEqual(resolved["searchText"]?.stringValue, "beta")
        XCTAssertEqual(resolved["sortDescriptors"], .array([
            .dictionary(["key": .string("name"), "ascending": .boolean(true)]),
        ]))
        XCTAssertEqual(resolved["columnFilterComposition"]?.stringValue, "any")
        XCTAssertEqual(resolved["columnFilters"]?.arrayValue?.count, 1)
        XCTAssertEqual(resolved["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), ["Group"])
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample-A"])
        XCTAssertEqual(resolved["tableMode"]?.stringValue, "batchHierarchical")
        XCTAssertEqual(resolved["sampleId"]?.stringValue, "esviritu-pin")
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["format", "outputPath"])
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, "tsv")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
    }
}
