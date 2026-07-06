// EsVirituResultViewControllerSmokeTests.swift - Standalone smoke test for the EsViritu leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishWorkflow
import LungfishKit

final class EsVirituResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testViewControllerInstantiates() {
        let vc = EsVirituResultViewController()
        XCTAssertNotNil(vc.view)
    }

    @MainActor func testViralDetectionSearchFieldChangesAreDebounced() {
        let table = ViralDetectionTableView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        table.result = Self.esvirituResult([
            Self.viralAssembly(name: "Alpha virus", sampleId: "sample-A", assembly: "GCF_A", accession: "NC_A", reads: 40),
            Self.viralAssembly(name: "Beta virus", sampleId: "sample-B", assembly: "GCF_B", accession: "NC_B", reads: 20),
            Self.viralAssembly(name: "Gamma virus", sampleId: "sample-C", assembly: "GCF_C", accession: "NC_C", reads: 10),
        ])
        let initialFilterCount = table.testingFilterApplicationCount

        table.testingSubmitSearchText("a")
        table.testingSubmitSearchText("al")
        table.testingSubmitSearchText("alpha")

        XCTAssertEqual(table.testingFilterApplicationCount, initialFilterCount)

        let deadline = Date().addingTimeInterval(1.0)
        while table.testingFilterApplicationCount == initialFilterCount && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(table.testingFilterApplicationCount, initialFilterCount + 1)
        XCTAssertEqual(table.testDisplayedAssemblyCount, 1)
    }

    @MainActor func testDelimitedDetectionExportWritesScientificProvenanceSidecar() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituDetectionExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = Self.esvirituResult([
            Self.viralAssembly(name: "Alpha virus", sampleId: "sample-A", assembly: "GCF_A", accession: "NC_A", reads: 40),
            Self.viralAssembly(name: "Beta virus", sampleId: "sample-B", assembly: "GCF_B", accession: "NC_B", reads: 20),
        ])
        let vc = EsVirituResultViewController()
        _ = vc.view
        vc.isBatchMode = true
        vc.samplePickerState = ClassifierSamplePickerState(allSamples: Set(["sample-A", "sample-B"]))
        vc.samplePickerState.selectedSamples = ["sample-A"]

        let outputURL = tempDir.appendingPathComponent("detections.tsv")
        try vc.writeDelimitedDetections(result: result, separator: "\t", fileExtension: "tsv", to: outputURL)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app esviritu detections export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 2)
        XCTAssertEqual(
            envelope.options.resolvedDefaults["selectedSamples"]?.arrayValue?.compactMap(\.stringValue),
            ["sample-A"]
        )
        XCTAssertEqual(envelope.options.resolvedDefaults["tableMode"]?.stringValue, "batchHierarchical")
        XCTAssertEqual(envelope.options.resolvedDefaults["searchText"]?.stringValue, "")
    }

    private static func esvirituResult(_ assemblies: [ViralAssembly]) -> LungfishIO.EsVirituResult {
        LungfishIO.EsVirituResult(
            sampleId: "esviritu-ui",
            detections: assemblies.flatMap(\.contigs),
            assemblies: assemblies,
            taxProfile: [],
            coverageWindows: [],
            totalFilteredReads: 1_000,
            detectedFamilyCount: 1,
            detectedSpeciesCount: 1,
            runtime: nil,
            toolVersion: nil
        )
    }

    private static func viralAssembly(
        name: String,
        sampleId: String,
        assembly: String,
        accession: String,
        reads: Int
    ) -> ViralAssembly {
        let detection = ViralDetection(
            sampleId: sampleId,
            name: name,
            description: name,
            length: 100,
            segment: nil,
            accession: accession,
            assembly: assembly,
            assemblyLength: 100,
            kingdom: "Viruses",
            phylum: nil,
            tclass: nil,
            order: nil,
            family: "Testviridae",
            genus: nil,
            species: name,
            subspecies: nil,
            rpkmf: Double(reads),
            readCount: reads,
            coveredBases: 100,
            meanCoverage: 1,
            avgReadIdentity: 99,
            pi: 0,
            filteredReadsInSample: 1_000
        )
        return ViralAssembly(
            assembly: assembly,
            assemblyLength: 100,
            name: name,
            family: "Testviridae",
            genus: nil,
            species: name,
            totalReads: reads,
            rpkmf: Double(reads),
            meanCoverage: 1,
            avgReadIdentity: 99,
            contigs: [detection]
        )
    }
}
