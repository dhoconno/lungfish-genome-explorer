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

    /// Phase 2.6 lane C6, review of lane C4 ruling 3. A change that throws after its `start` line, here
    /// because the folder is not a bundle, ended the event stream with no terminal event, and an app
    /// that reads events saw a run that never finished. It now ends in one `failed` line that carries
    /// the message, and the command still fails with the same error.
    func testAFolderThatIsNotABundleEndsTheEventStreamInOneFailedLine() async throws {
        let folder = root.appendingPathComponent("Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let command = try FastqPlatformSubcommand.parse([folder.path, "--set", "ont", "--format", "json"])

        var thrown: Error?
        let lines = try await standardOutputLines {
            do { try await command.run() } catch { thrown = error }
        }

        XCTAssertEqual(try XCTUnwrap(thrown).localizedDescription, "Not a .lungfishfastq bundle: \(folder.path)")
        let decoder = CLIEventLineDecoder()
        let events = try lines.map { try XCTUnwrap(try decoder.decode(line: $0), $0) }
        XCTAssertEqual(events.first, .start(message: "Recording the sequencing platform of 1 FASTQ bundle(s)"))
        XCTAssertEqual(events.last, .failed(message: "Not a .lungfishfastq bundle: \(folder.path)", detail: nil))
        XCTAssertEqual(
            events.filter { if case .failed = $0 { return true } else { return false } }.count, 1,
            "One failed line"
        )
        XCTAssertEqual(events.count, 2, "Nothing sits between the start and the failure: \(lines)")
    }

    /// The same failure with events off prints no event line, and the message is the one the
    /// command always gave.
    func testAFolderThatIsNotABundleWithEventsOffPrintsNoEventLine() async throws {
        let folder = root.appendingPathComponent("PlainText", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let command = try FastqPlatformSubcommand.parse([folder.path, "--set", "ont"])

        var thrown: Error?
        let lines = try await standardOutputLines {
            do { try await command.run() } catch { thrown = error }
        }

        XCTAssertEqual(try XCTUnwrap(thrown).localizedDescription, "Not a .lungfishfastq bundle: \(folder.path)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("{") }, "No event line with events off: \(lines)")
    }

    /// The standard output of a run, redirected to a file for its length, as the lines it printed.
    private func standardOutputLines(_ body: () async throws -> Void) async throws -> [String] {
        let file = root.appendingPathComponent("standard-output-\(UUID().uuidString).capture")
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard saved >= 0, descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)
        var failure: Error?
        do {
            try await body()
        } catch {
            failure = error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        if let failure { throw failure }
        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
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
