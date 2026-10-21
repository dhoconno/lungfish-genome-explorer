// AppWriterRecordIdentityPinTests.swift - What three app writers record as tool name, kind and argv[0], read together
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27 M2, deviation 1 of 13.27.md (the pins of M1 (3) that no test held) and ruling MD58 (2).
// Each test runs one app writer for real and reads the six facts its record holds about its tool in one assertion, so a
// change to any of them is seen beside the others. The values are what is true today. 13.27-c4 moved the FASTA names
// and the kind and argv[0] of the sample metadata record (review 13.27-M1 Fix 1 and Fix 2). The candidate display
// record still starts its argv with the `lungfish-cli` equivalent, a V1-6 site no list places. The annotation `toolName` and `app:` fields are pinned by the
// eight tests of 13.27-c in `SequenceAnnotationEditCommandTests` and `VariantsEditCommandTests`.
// 13.27-c5 (reviews 13.27-M3-BIO Fix 1, 2 and 5) adds the five writers that no test read, the barcode definition import,
// the workflow prepare record, the sample sheet metadata command, the classifier read extraction file record and the BAM
// import record.

import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishTestSupport

@MainActor
final class AppWriterRecordIdentityPinTests: XCTestCase {
    /// The six facts a record holds about its tool, named by the value paths of the record.
    private func facts(_ envelope: ProvenanceEnvelope) -> [String: String] {
        [
            "toolName": envelope.toolName,
            "tool.name": envelope.tool.name,
            "tool.kind": envelope.tool.kind ?? "<none>",
            "argv[0]": envelope.argv.first ?? "<none>",
            "steps[0].toolName": envelope.steps.first?.toolName ?? "<none>",
            "steps[0].argv[0]": envelope.steps.first?.argv.first ?? "<none>",
        ]
    }

    /// `GenotypeCandidateDisplayPersistence.swift:161,175,177`. The app names the tool and its kind, and the argv
    /// is the runnable `lungfish-cli` equivalent beside them (V1-6 of the lane brief).
    func testCandidateDisplayRecordNamesTheAppAndRunsTheCLICommand() async throws {
        let root = try TestTempDirectory.make(prefix: "app-writer-identity-display")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("Fixture.lungfishgenotype")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(#"{"analysis":"test-fixture"}"#.utf8).write(to: bundle.appendingPathComponent(ONTGenotypeResultBundleManifest.filename))
        _ = try await GenotypeCandidateDisplayPersistence.persist(
            display: ONTMHCCandidateDisplaySettings(showKnown: false),
            expectedDisplay: .default,
            bundleURL: bundle,
            author: "analyst"
        )
        let record = ProvenanceRecorder.fileSidecarURL(for: bundle.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: record))
        XCTAssertEqual(facts(envelope), [
            "toolName": LungfishAppIdentity.recordedToolName,
            "tool.name": LungfishAppIdentity.recordedToolName,
            "tool.kind": LungfishAppIdentity.recordedToolKind,
            "argv[0]": CLICommandIdentity.executableName,
            "steps[0].toolName": LungfishAppIdentity.recordedToolName,
            "steps[0].argv[0]": CLICommandIdentity.executableName,
        ])
    }

    /// `SampleMetadataBundleImportService.swift:65-72`. The app names itself, takes kind `gui` and starts the argv with
    /// its name (13.27-c4, P-KIND-1 and P-ARGV0-1). The record holds no step.
    func testSampleMetadataRecordNamesTheAppWithKindGUIAndStartsItsArgvWithTheAppName() throws {
        let root = try TestTempDirectory.make(prefix: "app-writer-identity-metadata")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("manifest.json"))
        let sourceURL = root.appendingPathComponent("metadata.tsv")
        let metadata = Data("donor\tsite\nalias-one\tHilo\n".utf8)
        try metadata.write(to: sourceURL)
        let identityIndex = try SampleIdentityIndex(samples: [
            .init(canonicalID: "S1", aliases: ["alias-one"], alignmentTrackIDs: [], readGroupIDs: ["rg-1"])
        ])
        let scan = try SampleMetadataStore.scanForSampleColumn(
            csvData: metadata,
            knownSampleIds: Set(identityIndex.metadataIdentifierMappings.keys)
        )
        let result = try SampleMetadataBundleImportService().importMetadata(
            data: metadata, sourceURL: sourceURL, scanResult: scan,
            sampleColumnIndex: try XCTUnwrap(scan.bestColumn).index,
            knownSampleIds: identityIndex.canonicalSampleIDs,
            identityIndex: identityIndex, bundleURL: bundleURL
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self, from: Data(contentsOf: try XCTUnwrap(result.provenanceURL))
        )
        XCTAssertEqual(facts(envelope), [
            "toolName": LungfishAppIdentity.recordedToolName,
            "tool.name": LungfishAppIdentity.recordedToolName,
            "tool.kind": LungfishAppIdentity.recordedToolKind,
            "argv[0]": LungfishAppIdentity.recordedToolName,
            "steps[0].toolName": "<none>",
            "steps[0].argv[0]": "<none>",
        ])
    }

    /// `SampleMetadataBundleImportService.swift:324`. The edit step the inspector appends starts its argv with the app's name.
    func testSampleMetadataEditStepStartsItsArgvWithTheAppName() throws {
        let root = try TestTempDirectory.make(prefix: "app-writer-identity-edit")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("manifest.json"))
        let sourceURL = root.appendingPathComponent("metadata.tsv")
        let metadata = Data("sample\tsite\nS1\tHilo\n".utf8)
        try metadata.write(to: sourceURL)
        let scan = try SampleMetadataStore.scanForSampleColumn(csvData: metadata, knownSampleIds: ["S1"])
        let result = try SampleMetadataBundleImportService().importMetadata(
            data: metadata, sourceURL: sourceURL, scanResult: scan,
            sampleColumnIndex: try XCTUnwrap(scan.bestColumn).index, knownSampleIds: ["S1"], bundleURL: bundleURL
        )
        try result.store.applyEdit(sampleId: "S1", column: "site", newValue: "Kona")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        let step = try XCTUnwrap(envelope.steps.last)
        XCTAssertEqual(step.toolName, "Sample metadata edit")
        XCTAssertEqual(step.argv.first, LungfishAppIdentity.recordedToolName)
        XCTAssertEqual(envelope.tool.kind, LungfishAppIdentity.recordedToolKind)
    }

    /// `FASTAOperationCatalog.swift:151,179,196,198`. The envelope, its step and the tool identity name the app
    /// (review 13.27-M1 Fix 1), the kind is `gui`, and the argv starts with the app's name.
    func testFASTASelectionRecordNamesTheSelectionAndTheAppAndStartsItsArgvWithTheAppName() throws {
        let bundleURL = try FASTAOperationCatalog.createTemporaryInputBundle(
            fastaRecords: [">seq1\nAACCGGTT\n"], suggestedName: "seq1", projectURL: nil
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))
        XCTAssertEqual(facts(envelope), [
            "toolName": LungfishAppIdentity.recordedToolName,
            "tool.name": LungfishAppIdentity.recordedToolName,
            "tool.kind": LungfishAppIdentity.recordedToolKind,
            "argv[0]": LungfishAppIdentity.recordedToolName,
            "steps[0].toolName": LungfishAppIdentity.recordedToolName,
            "steps[0].argv[0]": LungfishAppIdentity.recordedToolName,
        ])
    }

    /// `WorkflowOperationDialogState.swift:1456,1472,1473`. The barcode definition import record names the app, takes kind `gui`
    /// (review 13.27-M3-BIO Fix 1, row P-KIND-2) and starts its argv with the app's name. The writer
    /// `projectOwnedBarcodeDefinitionURL(for:)` has no caller at this head, so the test reaches it through its `internal` seam.
    func testBarcodeDefinitionImportRecordNamesTheApp() throws {
        let root = try TestTempDirectory.make(prefix: "app-writer-identity-barcode")
        defer { TestTempDirectory.cleanup(root) }
        let projectURL = root.appendingPathComponent("project.lungfish", isDirectory: true)
        let externalURL = root.appendingPathComponent("external/barcodes.csv")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: externalURL)
        let suite = makeTestDefaultsSuite(prefix: "AppWriterRecordIdentityPinTests")
        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            enablementStore: WorkflowLibraryEnablementStore(userDefaults: suite.defaults),
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: suite.defaults)
        )
        let importedURL = try state.projectOwnedBarcodeDefinitionURL(for: externalURL)
        XCTAssertEqual(importedURL.deletingLastPathComponent().lastPathComponent, "Barcode Definitions")
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(
            Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: importedURL))
        )
        XCTAssertEqual(facts(envelope), [
            "toolName": LungfishAppIdentity.recordedToolName,
            "tool.name": LungfishAppIdentity.recordedToolName,
            "tool.kind": LungfishAppIdentity.recordedToolKind,
            "argv[0]": LungfishAppIdentity.recordedToolName,
            "steps[0].toolName": "<none>",
            "steps[0].argv[0]": "<none>",
        ])
        XCTAssertTrue(ProvenanceAppStep.isAppStep(envelope.argv))
    }

    /// `WorkflowOperationExecutionService.swift:883,901`. The record that the ONT viewer bundle preparation writes names the
    /// app as its tool and starts its argv with the app's name. Its envelope carries no `tool.kind`, so the test reads the
    /// other facts. The writer is `internal` for this test.
    func testWorkflowOperationPrepareRecordNamesTheApp() throws {
        let root = try TestTempDirectory.make(prefix: "app-writer-identity-prepare")
        defer { TestTempDirectory.cleanup(root) }
        let sourceBundleURL = root.appendingPathComponent("source.lungfishref", isDirectory: true)
        let viewerBundleURL = root.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: viewerBundleURL, withIntermediateDirectories: true)
        let bamURL = root.appendingPathComponent("reads.bam")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: bamURL)
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [root.appendingPathComponent("reads.fastq")],
            referenceSourceURL: sourceBundleURL,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "reads-ont",
            analysisName: "ONT08"
        )
        try WorkflowOperationExecutionService().writeONTViewerBundleProvenance(
            workflowName: "ont-genotyping",
            sourceBundleURL: sourceBundleURL,
            bamURL: bamURL,
            viewerBundleURL: viewerBundleURL,
            request: request
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: viewerBundleURL))
        XCTAssertEqual(envelope.toolName, LungfishAppIdentity.recordedToolName)
        XCTAssertEqual(envelope.tool.name, LungfishAppIdentity.recordedToolName)
        XCTAssertNil(envelope.tool.kind)
        XCTAssertEqual(
            Array(envelope.argv.prefix(3)),
            [LungfishAppIdentity.recordedToolName, "workflow-operations", "prepare-ont-bam-viewer"]
        )
        XCTAssertTrue(ProvenanceAppStep.isAppStep(envelope.argv))
    }

    /// `FASTQIngestionService.swift:612`. The sample sheet metadata step starts its command with the app's name and keeps the
    /// words `fastq sample-sheet-metadata` after it.
    func testSampleSheetMetadataCommandStartsWithTheAppName() throws {
        let root = try TestTempDirectory.make(prefix: "app-writer-identity-samplesheet")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("SampleA.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("SampleA.fastq.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: fastqURL)
        let sampleSheetURL = root.appendingPathComponent("samples.csv")
        try "sample,r1,collection_site\nSampleA,\(fastqURL.path),Site 12\n".write(
            to: sampleSheetURL, atomically: true, encoding: .utf8
        )
        let importEnvelope = try ProvenanceRunBuilder(
            workflowName: "lungfish import fastq",
            workflowVersion: "2026.05",
            toolName: "lungfish import fastq",
            toolVersion: "2026.05"
        )
        .argv([CLICommandIdentity.executableName, "import", "fastq", fastqURL.path])
        .output(fastqURL, format: .fastq, role: .output)
        .runtime(ProvenanceRuntimeIdentity())
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 80), endedAt: Date(timeIntervalSince1970: 81))
        try ProvenanceWriter(signingProvider: nil).write(importEnvelope, to: bundleURL)
        let pair = FASTQFilePair(
            r1: fastqURL,
            r2: nil,
            sampleNameOverride: "SampleA",
            metadata: ["collection_site": "Site 12"],
            sampleSheetURL: sampleSheetURL
        )
        try FASTQIngestionService.testingSaveSampleSheetMetadata(pair: pair, bundleURL: bundleURL)
        let step = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL)?.steps.last)
        XCTAssertEqual(step.argv.first, LungfishAppIdentity.recordedToolName)
        XCTAssertEqual(Array(step.argv.dropFirst().prefix(2)), ["fastq", "sample-sheet-metadata"])
        XCTAssertTrue(ProvenanceAppStep.isAppStep(step.argv))
    }

    /// `TaxonomyReadExtractionAction.swift:647,693`. The classifier read extraction file record names one tool, the app, in its
    /// `toolName` and as argv[0] (review 13.27-M3-BIO Fix 5, row P-V16-3). The words after argv[0] stay the
    /// `extract reads --by-classifier` ones.
    func testClassifierReadExtractionFileProvenanceNamesTheApp() throws {
        let context = TaxonomyReadExtractionAction.Context(
            tool: .nvd,
            resultPath: URL(fileURLWithPath: "/tmp/nvd-results/fake.sqlite"),
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_001"], taxIds: [])],
            suggestedName: "nvd-extract"
        )
        let recorded = TaxonomyReadExtractionAction.optionsByRecordingFileProvenanceForTesting(
            ExtractionOptions(format: .fastq, includeUnmappedMates: false),
            context: context,
            destination: .file(URL(fileURLWithPath: "/tmp/out.fastq"))
        )
        let provenance = try XCTUnwrap(recorded.fileProvenance)
        XCTAssertEqual(provenance.toolName, LungfishAppIdentity.recordedToolName)
        XCTAssertEqual(provenance.argv.first, LungfishAppIdentity.recordedToolName)
        XCTAssertEqual(Array(provenance.argv.dropFirst().prefix(3)), ["extract", "reads", "--by-classifier"])
        XCTAssertTrue(ProvenanceAppStep.isAppStep(provenance.argv))
    }

    /// `BAMImportService+Provenance.swift:96,109,123`. The BAM import record and its two app steps name the app as their tool,
    /// and argv[0] is the one the caller gave, since the CLI passes its own words to this shared writer (R2 for it is a later row).
    func testBAMImportRecordNamesTheCaller() async throws {
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .samtools)
        } catch {
            throw XCTSkip("samtools is not installed in the managed conda root")
        }
        let fixtureBAM = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test.paired_end.sorted.bam")
        guard FileManager.default.fileExists(atPath: fixtureBAM.path) else {
            throw XCTSkip("sarscov2 BAM fixture missing")
        }
        let root = try TestTempDirectory.make(prefix: "app-writer-identity-bam")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("adopt.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try BundleManifest(
            name: "Adopt",
            identifier: "bundle.adopt",
            source: SourceInfo(organism: "Virus", assembly: "MN908947.3", database: "Test")
        ).save(to: bundleURL)
        let callerWords = ["caller-given-name", "import", "bam", fixtureBAM.path]
        _ = try await BAMImportService.importBAM(
            bamURL: fixtureBAM,
            bundleURL: bundleURL,
            name: "Adopted",
            materialization: .adoptCoordinateSorted,
            provenanceCommand: callerWords
        )
        let alignmentsURL = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let recordName = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: alignmentsURL.path)
                .first { $0.hasSuffix(".import.lungfish-provenance.json") }
        )
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(
            Data(contentsOf: alignmentsURL.appendingPathComponent(recordName))
        )
        XCTAssertEqual(envelope.toolName, LungfishAppIdentity.recordedToolName)
        XCTAssertEqual(envelope.tool.name, LungfishAppIdentity.recordedToolName)
        XCTAssertNil(envelope.tool.kind)
        XCTAssertEqual(envelope.argv, callerWords)
        XCTAssertEqual(
            envelope.steps.map(\.toolName),
            [LungfishAppIdentity.recordedToolName, LungfishAppIdentity.recordedToolName]
        )
        XCTAssertEqual(envelope.steps.compactMap(\.argv.first), ["caller-given-name", "caller-given-name"])
    }
}
