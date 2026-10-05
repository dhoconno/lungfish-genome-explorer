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

    /// Backups the change snapshot made of a locked sidecar keep the lock, so
    /// the snapshot cannot discard them. Unlocks and removes the ones made
    /// since `existing` was listed.
    private func removeLockedSnapshotBackups(in folder: URL, except existing: Set<String>) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("lungfish-fastq-platform-") && !existing.contains(name) {
            let backup = folder.appendingPathComponent(name, isDirectory: true)
            for file in (try? fileManager.contentsOfDirectory(atPath: backup.path)) ?? [] {
                try? fileManager.setAttributes([.immutable: false], ofItemAtPath: backup.appendingPathComponent(file).path)
            }
            try? fileManager.removeItem(at: backup)
        }
    }

    /// A sidecar the command cannot replace (a locked file in a writable
    /// folder) fails the change with a non-zero exit, so the Operations row
    /// fails too, and no provenance names a label that was never written.
    /// Before the fix the write failed silently and the command exited 0.
    func testASidecarThatCannotBeWrittenFailsTheChange() async throws {
        let bundle = try makeLegacyMislabelledBundle()
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let sidecar = FASTQMetadataStore.metadataURL(for: fastq)
        let before = try Data(contentsOf: sidecar)
        let temporary = FileManager.default.temporaryDirectory
        let existingBackups = Set((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path)
            removeLockedSnapshotBackups(in: temporary, except: existingBackups)
        }

        do {
            try await FastqPlatformSubcommand.parse([bundle.path, "--set", "ont", "--quiet"]).run()
            XCTFail("A change whose metadata file was not written must fail")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, CLIExitCode.outputError.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: sidecar).path))
        XCTAssertThrowsError(try FASTQPlatformLabelService.apply(
            toBundle: bundle, platform: .oxfordNanopore, readType: nil, source: .userCorrected
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not be written"), error.localizedDescription)
        }
    }

    /// A sidecar that cannot be decoded is never replaced by a record that
    /// holds only the platform, which would drop its pairing record and read
    /// classification. The change is refused with a message and the file is
    /// kept as it was. Before the fix it was rewritten from scratch.
    func testAnUnreadableSidecarIsRefusedAndKept() async throws {
        let bundle = try makeLegacyMislabelledBundle()
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let sidecar = FASTQMetadataStore.metadataURL(for: fastq)
        let unreadable = Data(#"{"sequencingPlatform" : "illumina", "ingestion" : {"pairingMode" : "#.utf8)
        try unreadable.write(to: sidecar)

        do {
            try await FastqPlatformSubcommand.parse([bundle.path, "--set", "ont", "--quiet"]).run()
            XCTFail("A change to an unreadable metadata file must be refused")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, CLIExitCode.outputError.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: sidecar), unreadable)
        XCTAssertThrowsError(try FASTQPlatformLabelService.apply(
            toBundle: bundle, platform: .oxfordNanopore, readType: nil, source: .userCorrected
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not be read"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: sidecar), unreadable)
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
