// ProvenanceEnvelopeCopySitesAppTests.swift - What the App sites that copy a recorded envelope keep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4a, scope row B3, plan decisions P5 and E13. The Workflow sites are pinned in
// `ProvenanceEnvelopeCopySitesTests`, and this file pins the two that sit in LungfishApp, the sample
// sheet metadata append (`FASTQIngestionService.swift:706`) and the sample metadata edit
// (`SampleMetadataBundleImportService.swift:363`). The in-place ingestion merge was a third until
// Phase 2.11 (K3) deleted the in-process route. Each test sends the three sources of
// `EnvelopeCopySources` through the site and checks what the copy holds.

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
            XCTAssertEqual(copy.steps.last?.toolName, LungfishAppIdentity.recordedToolName)
            XCTAssertEqual(copy.steps.count, source.steps.count + 1)
        }
    }

    // MARK: SampleMetadataBundleImportService, line 363

    func testSampleMetadataEditCopiesEachSourceFaithfully() throws {
        for (kind, failedExit) in CopySources.sourcesWithFailedExit {
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
            try CopySources.rewriteSidecar(at: sidecar, as: kind, exitStatus: failedExit)
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
            if let failedExit {
                XCTAssertEqual(
                    copy.exitStatus, failedExit,
                    "a \(kind.rawValue) record keeps its exit status over the edit's 0"
                )
            }
        }
    }
}
