// FastqIngestSIGTERMTests.swift - SIGTERM cancels `fastq ingest` and leaves the original in place
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2, plan decisions C5 and P2. The app's Cancel sends SIGTERM to
// `lungfish-cli`, and the in-place ingest deletes the user's original FASTQ file, so a cancel
// must leave that file as it was and publish no output. The leaf turns the signal into a cancel,
// removes the hidden folder its output is built in, writes a `cancelled` record and exits 125
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

        let cli = try CLISIGTERMHarness.launchCLI(
            ["fastq", "ingest", input.path, "--delete-originals", "--quiet"],
            environment: [
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
        XCTAssertEqual(hidden.count, 1, "the leaf builds its output in one hidden folder beside the input: \(hidden)")
        if let staging = hidden.first {
            let part = try names(in: folder.appendingPathComponent(staging, isDirectory: true))
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
        XCTAssertEqual(try Data(contentsOf: input), originalBytes, "the original is as it was")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: recordURL))
        XCTAssertEqual(record.workflowName, "lungfish fastq ingest")
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertTrue(record.outputs.isEmpty, "a cancelled run claims no output")
        XCTAssertTrue(stop.standardError.isEmpty || stop.standardError.contains("cancel"), stop.diagnostics)
    }
}
