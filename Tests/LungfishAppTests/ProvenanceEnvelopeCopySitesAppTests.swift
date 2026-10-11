// ProvenanceEnvelopeCopySitesAppTests.swift - What the App sites that copy a recorded envelope keep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, scope row B3, plan decisions P5 and E13. The Workflow sites are pinned in
// `ProvenanceEnvelopeCopySitesTests`, and this file pins the three that sit in LungfishApp, the sample
// sheet metadata append (`FASTQIngestionService.swift:706`), the in-place ingestion merge (`:922`) and
// the sample metadata edit (`SampleMetadataBundleImportService.swift:363`). Each test sends the three
// sources of `EnvelopeCopySources` through the site and checks what the copy holds.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

final class ProvenanceEnvelopeCopySitesAppTests: XCTestCase {
    private typealias CopySources = EnvelopeCopySources

    // MARK: FASTQIngestionService, line 706

    func testSampleSheetMetadataAppendCopiesEachSourceFaithfully() throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let bundle = try project.folder("Imports/SampleA.lungfishfastq")
            let fastq = bundle.appendingPathComponent("SampleA.fastq.gz")
            try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: fastq)
            let sampleSheet = try ProvenanceCompatScenarios.write(
                "sample,r1,collection_site\nSampleA,\(fastq.path),Site 12\n",
                to: project.root.appendingPathComponent("samples.csv")
            )
            let base = try CopySources.baseEnvelope(workflowName: "fastq import", output: fastq)
            try ProvenanceWriter(signingProvider: nil).write(base, to: bundle)
            let sidecar = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            try CopySources.rewriteSidecar(at: sidecar, as: kind)
            let source = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
            let pair = FASTQFilePair(
                r1: fastq,
                r2: nil,
                sampleNameOverride: "SampleA",
                metadata: ["collection_site": "Site 12"],
                sampleSheetURL: sampleSheet
            )

            try FASTQIngestionService.testingSaveSampleSheetMetadata(pair: pair, bundleURL: bundle)

            let copy = try CopySources.capture(
                site: "fastq-sample-sheet", kind: kind, sidecar: sidecar, projectRoot: project.root
            )
            CopySources.assertFaithfulCopy(
                site: "FASTQIngestionService:706", kind: kind, copy: copy,
                keeping: source
            )
            XCTAssertEqual(copy.steps.last?.toolName, "lungfish-app fastq sample-sheet-metadata")
            XCTAssertEqual(copy.steps.count, source.steps.count + 1)
        }
    }

    // MARK: FASTQIngestionService, line 922

    func testInPlaceIngestionMergeCopiesEachSourceFaithfully() async throws {
        for kind in CopySources.Kind.allCases {
            let project = try ProvenanceCompatScenarios.makeProject()
            defer { project.cleanup() }
            let bundle = try project.folder("Imports/Sample.lungfishfastq")
            let importedFASTQ = bundle.appendingPathComponent("Sample.fastq")
            let optimizedFASTQ = bundle.appendingPathComponent("Sample.fastq.gz")
            // The record names a file the ingestion does not replace, so the merge rewrites no path.
            let recordedOutput = try ProvenanceCompatScenarios.write("@r\nACGT\n+\n!!!!\n", to: bundle.appendingPathComponent("Other.fastq"))
            try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: optimizedFASTQ)
            let base = try CopySources.baseEnvelope(workflowName: "fastq import", output: recordedOutput)
            try ProvenanceWriter(signingProvider: nil).write(base, to: bundle)
            let sidecar = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            try CopySources.rewriteSidecar(at: sidecar, as: kind)
            let source = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))

            let optimizationStep = StepExecution(
                toolName: "clumpify.sh",
                toolVersion: "test-bbtools",
                command: ["clumpify.sh", "in=\(importedFASTQ.path)", "out=\(optimizedFASTQ.path)"],
                inputs: [],
                outputs: [ProvenanceRecorder.fileRecord(url: optimizedFASTQ, format: .fastq, role: .output)],
                exitCode: 0,
                wallTime: 1.25
            )
            let result = FASTQIngestionResult(
                outputFile: optimizedFASTQ,
                wasClumpified: true,
                qualityBinning: .illumina4,
                originalFilenames: [importedFASTQ.lastPathComponent],
                originalSizeBytes: 15,
                finalSizeBytes: 4,
                pairingMode: .singleEnd,
                provenanceSteps: [optimizationStep]
            )
            let config = FASTQIngestionConfig(
                inputFiles: [importedFASTQ],
                outputDirectory: bundle,
                threads: 4,
                deleteOriginals: true,
                qualityBinning: .illumina4,
                skipClumpify: false
            )
            let ingestion = IngestionMetadata(
                isClumpified: true,
                isCompressed: true,
                pairingMode: .singleEnd,
                qualityBinning: QualityBinningScheme.illumina4.rawValue,
                originalFilenames: [importedFASTQ.lastPathComponent],
                ingestionDate: Date(timeIntervalSince1970: 1),
                originalSizeBytes: 15
            )

            try await FASTQIngestionService.testingSaveInPlaceIngestionProvenance(
                result: result, config: config, ingestion: ingestion
            )

            let copy = try CopySources.capture(
                site: "fastq-in-place", kind: kind, sidecar: sidecar, projectRoot: project.root
            )
            CopySources.assertFaithfulCopy(
                site: "FASTQIngestionService:922", kind: kind, copy: copy,
                keeping: source
            )
            XCTAssertEqual(copy.workflowName, source.workflowName, "the record stays the imported run")
            XCTAssertEqual(copy.steps.prefix(source.steps.count).map(\.id), source.steps.map(\.id))
            XCTAssertGreaterThan(copy.steps.count, source.steps.count, "the ingestion's steps follow")
        }
    }

    // MARK: SampleMetadataBundleImportService, line 363

    func testSampleMetadataEditCopiesEachSourceFaithfully() throws {
        for kind in CopySources.Kind.allCases {
            let root = try TestTempDirectory.make(prefix: "EnvelopeCopyPinSampleMetadata")
            defer { TestTempDirectory.cleanup(root) }
            let bundle = root.appendingPathComponent("result.lungfish", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: bundle.appendingPathComponent("manifest.json"))
            let sourceURL = root.appendingPathComponent("metadata.tsv")
            let metadata = Data("sample\tcohort\nS1\tcontrol\n".utf8)
            try metadata.write(to: sourceURL)
            let scan = try SampleMetadataStore.scanForSampleColumn(csvData: metadata, knownSampleIds: ["S1"])
            let imported = try SampleMetadataBundleImportService().importMetadata(
                data: metadata,
                sourceURL: sourceURL,
                scanResult: scan,
                sampleColumnIndex: try XCTUnwrap(scan.bestColumn).index,
                knownSampleIds: ["S1"],
                bundleURL: bundle
            )
            let sidecar = bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            try CopySources.rewriteSidecar(at: sidecar, as: kind)
            let source = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))

            try imported.store.applyEdit(sampleId: "S1", column: "cohort", newValue: "treated")

            let copy = try CopySources.capture(
                site: "sample-metadata-edit", kind: kind, sidecar: sidecar, projectRoot: root
            )
            CopySources.assertFaithfulCopy(
                site: "SampleMetadataBundleImportService:363", kind: kind, copy: copy,
                keeping: source
            )
            XCTAssertEqual(copy.steps.last?.toolName, "Sample metadata edit")
            XCTAssertEqual(copy.steps.count, source.steps.count + 1)
            XCTAssertEqual(copy.options.resolvedDefaults["sampleMetadataEditCount"], .integer(1))
        }
    }
}
