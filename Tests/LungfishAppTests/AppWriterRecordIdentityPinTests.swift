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

import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
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
}
