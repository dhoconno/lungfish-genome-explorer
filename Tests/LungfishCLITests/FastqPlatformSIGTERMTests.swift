// FastqPlatformSIGTERMTests.swift - How a SIGTERM ends `fastq platform --set` (Phase 2.11 lane S61, K7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Inspector's platform notice runs `lungfish-cli fastq platform --set`, which reads the first reads
// of the bundle's FASTQ file before it rewrites the label. It runs no external tool. This test makes
// the FASTQ file a FIFO, so the command's read blocks until a writer sends the reads. The test opens
// the write end as soon as the command is reading, holds it, sends one SIGTERM, and only then sends
// the reads. The signal therefore reaches a command that is at work, and the label it has changed by
// the time the reads arrive must be restored.

import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

final class FastqPlatformSIGTERMTests: XCTestCase {
    /// Opens the write end of `fifo` once the command has it open for reading, so the command's read
    /// stays in flight. A write end opened without waiting fails until a reader exists.
    private func holdRead(of fifo: URL) async -> Int32? {
        for _ in 0..<1500 {
            let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                // A command that ends early must fail the test, not end the test runner with SIGPIPE
                // when the reads are written to a pipe that has no reader.
                _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                return descriptor
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// A SIGTERM while the command reads the reads cancels the run. It exits 125, restores the label it
    /// had rewritten, records the run as cancelled under the bundle and ends the stream with one
    /// `failed` line.
    func testSIGTERMCancelsAPlatformChangeAndRestoresTheLabel() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-platform-sigterm")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = root.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("Sample.fastq")
        XCTAssertEqual(mkfifo(fastq.path, 0o644), 0, "the reads file is a FIFO")
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads),
            for: fastq
        )
        let cli = try CLISIGTERMHarness.launchCLI(
            ["fastq", "platform", bundle.path, "--set", "ont", "--format", "json"],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard let writer = await holdRead(of: fastq) else {
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("The command never read the reads file.\(stop.diagnostics)")
        }
        // The reads arrive 1.5 s after the signal, so the command finishes its read with the cancel pending.
        let release = Task.detached {
            try? await Task.sleep(for: .milliseconds(1500))
            let reads = (1...4).map { "@read\($0) runid=a\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
            let bytes = Array(reads.utf8)
            _ = bytes.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
            close(writer)
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            try SIGTERMPinSupport.cancelledRecordStatus(inBundle: bundle)
        }
        await release.value

        XCTAssertEqual(
            stop.standardOutput.components(separatedBy: #""event":"failed""#).count - 1, 1,
            "the stream ends with one failed line: \(stop.standardOutput)"
        )
        XCTAssertEqual(
            FASTQMetadataStore.load(for: fastq)?.sequencingPlatform, .illumina,
            "the recorded platform was restored"
        )
    }

    /// A restore that fails must not be recorded as a restore (review S61, Fix 10). The command makes its
    /// backup before it reads, and the test makes that folder unreadable, so the restore after the cancel
    /// cannot copy the recorded label back. The command says so in its one `failed` line and in its
    /// record, and it exits with the output error status and not 125.
    func testASIGTERMWhoseRestoreFailsIsNotRecordedAsRestored() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-platform-restore-fails")
        defer { TestTempDirectory.cleanup(root) }
        // The command makes its backup folder in the temporary folder of the user, whatever TMPDIR says.
        let temporary = FileManager.default.temporaryDirectory
        let backupPrefix = "lungfish-fastq-platform-"
        func backupFolders() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
            return Set(names.filter { $0.hasPrefix(backupPrefix) })
        }
        let backupsBefore = backupFolders()
        let bundle = root.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("Sample.fastq")
        XCTAssertEqual(mkfifo(fastq.path, 0o644), 0, "the reads file is a FIFO")
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads),
            for: fastq
        )
        let cli = try CLISIGTERMHarness.launchCLI(
            ["fastq", "platform", bundle.path, "--set", "ont", "--format", "json"],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard let writer = await holdRead(of: fastq) else {
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("The command never read the reads file.\(stop.diagnostics)")
        }
        let backups = backupFolders().subtracting(backupsBefore)
        guard backups.count == 1, let backupName = backups.first else {
            close(writer)
            let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(5))
            return XCTFail("Expected one new backup folder in the temporary folder, found \(backups).\(stop.diagnostics)")
        }
        let backup = temporary.appendingPathComponent(backupName, isDirectory: true)
        XCTAssertEqual(chmod(backup.path, 0o000), 0, "the backup folder is made unreadable")
        defer {
            chmod(backup.path, 0o755)
            try? FileManager.default.removeItem(at: backup)
        }
        let release = Task.detached {
            try? await Task.sleep(for: .milliseconds(1500))
            let reads = (1...4).map { "@read\($0) runid=a\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
            let bytes = Array(reads.utf8)
            _ = bytes.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
            close(writer)
        }

        let stop = await CLISIGTERMHarness.cancel(cli, timeout: .seconds(20))
        await release.value

        XCTAssertEqual(
            stop.exitStatus, Int32(CLIExitCode.outputError.rawValue),
            "a restore that failed exits with the output error status, not 125.\(stop.diagnostics)"
        )
        XCTAssertEqual(
            stop.standardOutput.components(separatedBy: #""event":"failed""#).count - 1, 1,
            "the stream ends with one failed line: \(stop.standardOutput)"
        )
        XCTAssertTrue(
            stop.standardOutput.contains("restoring the recorded labels failed"),
            "the failed line says the restore failed: \(stop.standardOutput)"
        )
        let folder = bundle.appendingPathComponent("provenance/cancelled", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let recordText = names.first.flatMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) } ?? ""
        XCTAssertTrue(recordText.contains("Restoring the recorded labels failed"), "the record says the restore failed: \(recordText)")
        XCTAssertFalse(recordText.contains("were restored"), "the record does not claim the labels were restored")
    }
}
