// AssemblyCompatibilityTests.swift - Tests for the v1 assembly compatibility matrix
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class AssemblyCompatibilityTests: XCTestCase {
    func testIlluminaShortReadsEnableOnlySPAdesMEGAHITAndSKESA() {
        XCTAssertEqual(
            Set(AssemblyCompatibility.supportedTools(for: .illuminaShortReads)),
            [.spades, .megahit, .skesa]
        )
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .spades, for: .illuminaShortReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .flye, for: .illuminaShortReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .hifiasm, for: .illuminaShortReads))
    }

    func testONTReadsEnableFlyeAndHifiasm() {
        XCTAssertEqual(
            Set(AssemblyCompatibility.supportedTools(for: .ontReads)),
            [.flye, .hifiasm]
        )
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .flye, for: .ontReads))
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .hifiasm, for: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .spades, for: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .megahit, for: .ontReads))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .skesa, for: .ontReads))
    }

    func testPacBioHiFiEnablesOnlyHifiasm() {
        XCTAssertEqual(
            Set(AssemblyCompatibility.supportedTools(for: .pacBioHiFi)),
            [.hifiasm]
        )
        XCTAssertTrue(AssemblyCompatibility.isSupported(tool: .hifiasm, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .spades, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .flye, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .megahit, for: .pacBioHiFi))
        XCTAssertFalse(AssemblyCompatibility.isSupported(tool: .skesa, for: .pacBioHiFi))
    }

    func testPacBioHiFiDisplayNameUsesHiFiCCSLabel() {
        XCTAssertEqual(AssemblyReadType.pacBioHiFi.displayName, "PacBio HiFi/CCS")
    }

    /// Mixed read classes used to block the run. The owner ruled that read
    /// class only sets defaults, so the user picks the read class and runs.
    func testMixedDetectedReadTypesWarnAndAskForTheReadClassInV1() {
        let evaluation = AssemblyCompatibility.evaluate(detectedReadTypes: [.illuminaShortReads, .ontReads])

        XCTAssertFalse(evaluation.isBlocked)
        XCTAssertNil(evaluation.resolvedReadType)
        XCTAssertTrue(evaluation.requiresReadTypeConfirmation)
        XCTAssertEqual(evaluation.warningMessage, AssemblyCompatibility.hybridAssemblyUnsupportedMessage)
        XCTAssertEqual(evaluation.supportedTools, AssemblyTool.allCases)
    }

    func testMixedSinglePassSequenceStillWarnsOnHybridInput() {
        let singlePassSequence = IteratorSequence(
            AnyIterator([AssemblyReadType.ontReads, .illuminaShortReads].makeIterator())
        )

        let evaluation = AssemblyCompatibility.evaluate(detectedReadTypes: singlePassSequence)

        XCTAssertFalse(evaluation.isBlocked)
        XCTAssertEqual(evaluation.warningMessage, AssemblyCompatibility.hybridAssemblyUnsupportedMessage)
    }

    func testReadTypeDecisionWarnsInsteadOfRefusing() {
        let mismatch = AssemblyCompatibility.decideReadType(
            detections: [.illuminaShortReads], tool: .flye, explicitReadType: nil, lengthDefault: nil
        )
        XCTAssertEqual(mismatch.readType, .ontReads)
        XCTAssertEqual(mismatch.warnings.count, 1)

        let unknown = AssemblyCompatibility.decideReadType(
            detections: [nil], tool: nil, explicitReadType: nil, lengthDefault: .ontReads
        )
        XCTAssertEqual(unknown.readType, .ontReads)
        XCTAssertEqual(unknown.warnings, [PlatformInference.untunedDefaultsNote])
        XCTAssertEqual(AssemblyCompatibility.defaultTool(for: unknown.readType), .flye)
        XCTAssertEqual(AssemblyCompatibility.defaultTool(for: nil), .spades)

        let explicit = AssemblyCompatibility.decideReadType(
            detections: [.ontReads, .illuminaShortReads], tool: .spades, explicitReadType: .illuminaShortReads, lengthDefault: nil
        )
        XCTAssertEqual(explicit, AssemblyReadTypeDecision(readType: .illuminaShortReads, warnings: []))
    }

    func testPacBioSubreadsDoNotAutoClassifyAsHiFi() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-read-type-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let fastq = """
        @m64001_190101_000000/123/subreads
        ACGT
        +
        !!!!
        """
        try Data(fastq.utf8).write(to: fixtureURL)

        XCTAssertNil(AssemblyReadType.detect(fromFASTQ: fixtureURL))
    }

    func testGenericPacBioZMWHeadersDoNotAutoClassifyAsHiFi() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-read-type-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let fastq = """
        @m64001_190101_000000/12345/0_1000 zmw=12345
        ACGT
        +
        !!!!
        """
        try Data(fastq.utf8).write(to: fixtureURL)

        XCTAssertNil(AssemblyReadType.detect(fromFASTQ: fixtureURL))
    }

    func testPacBioCCSHeadersClassifyAsHiFi() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-read-type-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let fastq = """
        @m64001_190101_000000/123/ccs
        ACGT
        +
        !!!!
        """
        try Data(fastq.utf8).write(to: fixtureURL)

        XCTAssertEqual(AssemblyReadType.detect(fromFASTQ: fixtureURL), .pacBioHiFi)
    }

    func testWorkflowPlatformPacBioDoesNotAutoClassifyAsHiFi() {
        XCTAssertNil(AssemblyReadType.detect(fromWorkflowPlatform: .pacbio))
    }

    func testWorkflowPlatformsStillMapIlluminaAndONT() {
        XCTAssertEqual(AssemblyReadType.detect(fromWorkflowPlatform: .illumina), .illuminaShortReads)
        XCTAssertEqual(AssemblyReadType.detect(fromWorkflowPlatform: .ont), .ontReads)
    }

    func testGzippedIlluminaFixtureStillClassifiesAsShortReads() {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/test_1.fastq.gz")

        XCTAssertEqual(AssemblyReadType.detect(fromFASTQ: fixtureURL), .illuminaShortReads)
    }

    func testBundleInputResolvesPrimaryFASTQForReadTypeDetection() throws {
        let bundleURL = try makeFASTQBundle(
            fastqName: "reads.fastq",
            fastqContents: """
            @A00488:17:H7WFLDMXX:1:1101:10000:1000 1:N:0:ATCACG
            ACGT
            +
            !!!!
            """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: bundleURL), .illuminaShortReads)
    }

    func testBundleInputFallsBackToPersistedSequencingPlatformWhenHeaderIsUnknown() throws {
        let bundleURL = try makeFASTQBundle(
            fastqName: "reads.fastq",
            fastqContents: """
            @unknown-read
            ACGT
            +
            !!!!
            """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let primaryFASTQURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore),
            for: primaryFASTQURL
        )

        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: bundleURL), .ontReads)
    }

    func testPersistedAssemblyReadTypeOverridesHeaderDetection() throws {
        let bundleURL = try makeFASTQBundle(
            fastqName: "reads.fastq",
            fastqContents: """
            @A00488:17:H7WFLDMXX:1:1101:10000:1000 1:N:0:ATCACG
            ACGT
            +
            !!!!
            """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let primaryFASTQURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .ontReads),
            for: primaryFASTQURL
        )

        XCTAssertEqual(AssemblyReadType.detect(fromInputURL: bundleURL), .ontReads)
    }

    private func makeFASTQBundle(
        fastqName: String,
        fastqContents: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssemblyCompatibilityTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("sample.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(fastqContents.utf8).write(to: bundleURL.appendingPathComponent(fastqName))
        return bundleURL
    }
}
