// FastqIngestSIGTERMTests.swift - SIGTERM cancels `fastq ingest` and leaves the original in place
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2, plan decisions C5 and P2. The app's Cancel sends SIGTERM to
// `lungfish-cli`, and the in-place ingest deletes the user's original FASTQ file, so a cancel
// must leave that file as it was and publish no output. The leaf turns the signal into a cancel,
// removes the staging folder its output is built in, writes a `cancelled` record and exits 125
// inside the grace the app gives it before SIGKILL.
//
// The managed clumpify is a stand-in script in a conda root of this test's own. It records its
// pid, writes half an output where `out=` says, and waits, so the cancel lands while a tool
// holds a part file. `CLISIGTERMHarness` signals the built `lungfish-cli`, and the test reads
// the folder afterwards. It needs no real tool, so it runs where clumpify is absent.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class FastqIngestSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-ingest-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A stand-in for the managed `clumpify.sh`, where the CLI looks for it under `condaRoot`.
    private func installStandInClumpify(in condaRoot: URL) throws {
        let script = condaRoot.appendingPathComponent("envs/bbtools/bin/clumpify.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        echo $$ > "$CLUMPIFY_PID_FILE"
        for argument in "$@"; do
          case "$argument" in
            out=*) printf 'half' > "${argument#out=}" ;;
          esac
        done
        exec /bin/sleep 300
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Every file or folder directly in `folder`, hidden ones included.
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testSIGTERMLeavesTheOriginalAndNoHalfWrittenOutputAndRecordsTheCancel() async throws {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        try installStandInClumpify(in: condaRoot)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("clumpify.pid")

        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try FastqIngestPublishDurabilityTests.reads.write(to: input, atomically: true, encoding: .utf8)
        let originalBytes = try Data(contentsOf: input)
        // 2.11 S8. An input outside a project stages in the system temp folder on its volume, here the test's own.
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)

        let cli = try CLISIGTERMHarness.launchCLI(
            ["fastq", "ingest", input.path, "--delete-originals", "--quiet"],
            environment: [
                "TMPDIR": systemTemp.path,
                "LUNGFISH_CONDA_ROOT": condaRoot.path,
                "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
                "CLUMPIFY_PID_FILE": pidFile.path,
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }

        // The stand-in runs, so the leaf is listening for SIGTERM and its output is half written.
        guard let clumpifyPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The leaf never started the stand-in clumpify.\(stop.diagnostics)")
        }
        let hidden = try names(in: folder).filter { $0.hasPrefix(".") && $0 != ProvenanceRecorder.provenanceFilename }
        XCTAssertEqual(hidden, [], "nothing stages beside the input")
        let staged = try names(in: systemTemp)
        XCTAssertEqual(staged.count, 1, "the leaf builds its output in one folder in the system temp folder: \(staged)")
        if let staging = staged.first {
            XCTAssertTrue(staging.hasPrefix("lungfish-ingest-"), staging)
            let part = try names(in: systemTemp.appendingPathComponent(staging, isDirectory: true)).filter { $0 != OwnedWorkDirectoryMarker.fileName }
            XCTAssertEqual(part, ["SRR9.fastq.gz"], "a half-written output exists while the tool runs")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("SRR9.fastq.gz").path),
            "nothing is published under the final name while the tool runs"
        )

        let recordURL = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            try ProvenanceEnvelopeReader.load(fromSidecar: recordURL)?.status.rawValue
        }
        XCTAssertTrue(stop.tree.contains(clumpifyPID), "the stand-in belongs to the leaf's tree \(stop.tree)")

        // The folder holds the original, as it was, and the cancelled record. No part file,
        // no hidden folder, no output and no sidecar remain.
        XCTAssertEqual(try names(in: folder), [ProvenanceRecorder.provenanceFilename, "SRR9_1.fastq"])
        XCTAssertEqual(try names(in: systemTemp), [], "the cancel removes the staging folder")
        XCTAssertEqual(try Data(contentsOf: input), originalBytes, "the original is as it was")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: recordURL))
        XCTAssertEqual(record.workflowName, "lungfish fastq ingest")
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertTrue(record.outputs.isEmpty, "a cancelled run claims no output")
        XCTAssertTrue(stop.standardError.isEmpty || stop.standardError.contains("cancel"), stop.diagnostics)
    }

    /// Lane A47 M3, ruling section 1. A file that holds a record already, here the sidecar of the
    /// download it came with, has a history. The leaf finds it with the lookup the merge uses, so a
    /// cancel writes nothing, since a merge would point the old outputs at a file never published,
    /// and the folder stays as it was. M2 looked for a root record only and added a `cancelled` one.
    func testSIGTERMWritesNothingWhereARecordStands() async throws {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        try installStandInClumpify(in: condaRoot)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("clumpify.pid")
        let fixture = try FastqIngestImportRecordFixture.makeSidecarOnly(in: root, reads: FastqIngestPublishDurabilityTests.reads)
        let before = try digests(in: fixture.folder)
        XCTAssertNil(before[ProvenanceRecorder.provenanceFilename], "no root record stands in the folder")
        XCTAssertNotNil(
            before[ProvenanceRecorder.fileSidecarURL(for: fixture.fastq).lastPathComponent],
            "the download's record stands as the file's own sidecar"
        )

        // 2.11 S8. The CLI stages in the system temp folder, here the test's own, so the cancel is read where the stage sits.
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)

        let cli = try CLISIGTERMHarness.launchCLI(
            ["fastq", "ingest", fixture.fastq.path, "--delete-originals", "--quiet"],
            environment: [
                "TMPDIR": systemTemp.path,
                "LUNGFISH_CONDA_ROOT": condaRoot.path,
                "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
                "CLUMPIFY_PID_FILE": pidFile.path,
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard await CLISIGTERMHarness.waitForProcessID(in: pidFile) != nil else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The leaf never started the stand-in clumpify.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.cancel(cli)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        XCTAssertEqual(try names(in: systemTemp), [], "the cancel removes the staging folder from the system temp folder")
        XCTAssertEqual(try digests(in: fixture.folder), before, "the folder is byte for byte as it was, with no record added and nothing staged beside the input")
    }

    /// S32 review fix 8, the kill-9 test of plan decision SW7 (a). SIGKILL gives the leaf no chance to clean up, so
    /// its stage stays in the system temp folder with the marker that names the CLI, and nothing is left beside the
    /// input. The launch sweep, with the real process inspector, leaves the stage while the CLI lives and removes
    /// it once the CLI is gone, which is the disposal a killed run is promised.
    func testAKilledIngestLeavesAMarkedFolderThatTheLaunchSweepRemoves() async throws {
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        try installStandInClumpify(in: condaRoot)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("clumpify.pid")

        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("SRR9_1.fastq")
        try FastqIngestPublishDurabilityTests.reads.write(to: input, atomically: true, encoding: .utf8)
        let originalBytes = try Data(contentsOf: input)
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
        let physicalTemp = systemTemp.resolvingSymlinksInPath()

        let cli = try CLISIGTERMHarness.launchCLI(
            ["fastq", "ingest", input.path, "--delete-originals", "--quiet"],
            environment: [
                "TMPDIR": systemTemp.path,
                "LUNGFISH_CONDA_ROOT": condaRoot.path,
                "LUNGFISH_STORAGE_ROOT": root.appendingPathComponent("storage", isDirectory: true).path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
                "CLUMPIFY_PID_FILE": pidFile.path,
            ],
            workingDirectory: root,
            testClass: Self.self
        )
        defer { cli.stop() }
        guard let clumpifyPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile) else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The leaf never started the stand-in clumpify.\(stop.diagnostics)")
        }
        // The stand-in execs `sleep 300` and outlives its parent, so the test ends it.
        defer { kill(clumpifyPID, SIGKILL) }

        // The tool holds a part file, so the run is under way and its stage stands in the system temp folder.
        let staged = try names(in: systemTemp)
        XCTAssertEqual(staged.count, 1, "the leaf builds its output in one folder in the system temp folder: \(staged)")
        let stageName = try XCTUnwrap(staged.first)
        XCTAssertTrue(stageName.hasPrefix("lungfish-ingest-"), stageName)
        let marker = try OwnedWorkDirectoryMarkerStore.load(
            from: physicalTemp.appendingPathComponent(stageName, isDirectory: true),
            expectedProjectURL: physicalTemp
        )
        XCTAssertEqual(marker.processIdentifier, cli.processIdentifier, "the marker names the CLI that made the stage")
        let whileRunning = SystemTempScratchSweep.sweep(root: systemTemp)
        XCTAssertEqual(whileRunning.refused[stageName], .liveCreator, "the sweep leaves the stage of a run that lives")
        XCTAssertTrue(whileRunning.removed.isEmpty, "\(whileRunning.removed)")

        kill(cli.processIdentifier, SIGKILL)
        let exited = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) { !cli.isRunning }
        XCTAssertTrue(exited, "SIGKILL ends the CLI")

        // Nothing ran the leaf's cleanup, so the stage stays in the system temp folder and nothing is beside the input.
        XCTAssertEqual(try names(in: folder), ["SRR9_1.fastq"], "a killed run leaves nothing beside the input")
        XCTAssertEqual(try names(in: systemTemp), [stageName], "a killed run leaves its stage in the system temp folder")

        // The next launch's sweep, with no injected inspector, finds the creator gone and removes the stage.
        let outcome = SystemTempScratchSweep.sweep(root: systemTemp)
        XCTAssertEqual(outcome.removed.map(\.lastPathComponent), [stageName], "\(outcome.refused)")
        XCTAssertEqual(try names(in: systemTemp), [], "the sweep removed the stage")
        XCTAssertEqual(try names(in: folder), ["SRR9_1.fastq"])
        XCTAssertEqual(try Data(contentsOf: input), originalBytes, "the original is as it was")
    }

    /// The SHA-256 of every file directly in `folder` by name, and a marker for a folder.
    private func digests(in folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try names(in: folder) {
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            result[name] = isDirectory.boolValue ? "folder" : try ProvenanceFileHasher.sha256(of: url)
        }
        return result
    }
}
