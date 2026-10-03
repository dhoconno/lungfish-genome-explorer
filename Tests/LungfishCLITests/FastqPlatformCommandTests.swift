// FastqPlatformCommandTests.swift - `lungfish-cli fastq platform` and the default `map` preset
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

final class FastqPlatformCommandTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-platform-command")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A bundle as an import before platform inference left it: dorado reads
    /// recorded as Illumina short reads, with no platform assignment.
    private func makeLegacyMislabelledBundle(named name: String = "Legacy") throws -> URL {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Imports/\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = try PlatformHeaderFixtures.copy("ont-dorado-samtags-tab.fastq", to: bundle, as: "\(name).fastq")
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads),
            for: fastq
        )
        return bundle
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testCheckReportsASuspectLabelWithItsOwnExitStatus() async throws {
        let bundle = try makeLegacyMislabelledBundle()
        let command = try FastqPlatformSubcommand.parse([bundle.deletingLastPathComponent().deletingLastPathComponent().path, "--check", "--quiet"])
        do {
            try await command.run()
            XCTFail("A suspect label must exit with the suspect status")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, FastqPlatformSubcommand.suspectExitCode)
        }

        let report = try FASTQPlatformLabelService.report(forBundle: bundle)
        XCTAssertEqual(report.check.verdict, .suspect)
        XCTAssertEqual(report.check.suggestedPlatform, .oxfordNanopore)
    }

    func testSetRewritesOnlyTheLabelAndRecordsProvenance() async throws {
        let bundle = try makeLegacyMislabelledBundle()
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let before = try sha256(fastq)

        try await FastqPlatformSubcommand.parse([bundle.path, "--set", "ont", "--quiet"]).run()

        XCTAssertEqual(try sha256(fastq), before, "The reads must not change")
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(metadata.assemblyReadType, .ontReads)
        XCTAssertEqual(metadata.platformAssignment?.source, .userCorrected)

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: FASTQMetadataStore.metadataURL(for: fastq))
        let data = PortablePath.resolveJSON(try Data(contentsOf: provenanceURL), forFileAt: provenanceURL)
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
        XCTAssertEqual(Array(envelope.argv.suffix(2)), ["--set", "ont"])
        XCTAssertEqual(envelope.options.explicit["previousPlatform"], .string("illumina"))

        // The label is decided now, so the check no longer questions it.
        XCTAssertEqual(try FASTQPlatformLabelService.report(forBundle: bundle).check.verdict, .decided)
    }

    func testConfirmKeepsTheLabelAndReadTypeAloneChangesOnlyTheReadType() async throws {
        let bundle = try makeLegacyMislabelledBundle()
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))

        try await FastqPlatformSubcommand.parse([bundle.path, "--confirm", "--quiet"]).run()
        var metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.sequencingPlatform, .illumina)
        XCTAssertEqual(metadata.platformAssignment?.source, .userConfirmed)

        try await FastqPlatformSubcommand.parse([bundle.path, "--read-type", "ont-reads", "--quiet"]).run()
        metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.sequencingPlatform, .illumina)
        XCTAssertEqual(metadata.assemblyReadType, .ontReads)
        XCTAssertEqual(metadata.platformAssignment?.source, .userCorrected)
    }

    func testValidation() {
        XCTAssertThrowsError(try FastqPlatformSubcommand.parse(["a.lungfishfastq", "--set", "sanger"]))
        XCTAssertThrowsError(try FastqPlatformSubcommand.parse(["a.lungfishfastq", "--set", "ont", "--confirm"]))
        XCTAssertNoThrow(try FastqPlatformSubcommand.parse(["a.lungfishfastq", "b.lungfishfastq", "--read-type", "auto"]))
        XCTAssertThrowsError(try FastqPlatformSubcommand.parse(["a.lungfishfastq", "--include-derivatives"]))
        XCTAssertNoThrow(try FastqPlatformSubcommand.parse(["a.lungfishfastq", "--set", "nanopore", "--read-type", "ont-reads"]))
    }

    func testTheCommandIsRegisteredUnderFastq() throws {
        let parsed = try LungfishCLI.parseAsRoot(["fastq", "platform", "a.lungfishfastq", "--set", "pacbio"])
        XCTAssertTrue(parsed is FastqPlatformSubcommand)
    }

    // MARK: - map without --preset

    func testMapDefaultPresetFollowsTheReadClassAndReadLength() throws {
        let nanopore = MapCommand.defaultPreset(tool: .minimap2, inputURLs: [PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq")])
        XCTAssertEqual(nanopore.mode, .minimap2MapONT)
        XCTAssertTrue(nanopore.note.contains("follows the input read class"), nanopore.note)

        let hifi = MapCommand.defaultPreset(tool: .minimap2, inputURLs: [PlatformHeaderFixtures.url("pacbio-revio-ccs.fastq")])
        XCTAssertEqual(hifi.mode, .minimap2MapHiFi)

        let illumina = MapCommand.defaultPreset(tool: .minimap2, inputURLs: [PlatformHeaderFixtures.url("illumina-novaseq6000.fastq")])
        XCTAssertEqual(illumina.mode, .defaultShortRead)

        let unknownLong = MapCommand.defaultPreset(tool: .minimap2, inputURLs: [PlatformHeaderFixtures.url("sra-renamed-long.fastq")])
        XCTAssertEqual(unknownLong.mode, .minimap2MapONT)
        XCTAssertTrue(unknownLong.note.contains(PlatformInference.untunedDefaultsNote), unknownLong.note)

        let unknownShort = MapCommand.defaultPreset(tool: .minimap2, inputURLs: [PlatformHeaderFixtures.url("sra-renamed-short.fastq")])
        XCTAssertEqual(unknownShort.mode, .defaultShortRead)

        let bowtie2 = MapCommand.defaultPreset(tool: .bowtie2, inputURLs: [PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq")])
        XCTAssertEqual(bowtie2.mode, .defaultShortRead)
    }

    func testAnExplicitPresetIsParsedAsGiven() throws {
        let command = try MapCommand.parse([
            PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq").path, "--reference", "/tmp/ref.fa", "--preset", "sr",
        ])
        XCTAssertEqual(command.preset, "sr")
    }
}
