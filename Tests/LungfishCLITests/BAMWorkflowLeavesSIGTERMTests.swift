// BAMWorkflowLeavesSIGTERMTests.swift - A SIGTERM cancels the Inspector's four alignment workflow leaves
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54 M2 (decision P2, SWIFT 3). The app's Cancel sends SIGTERM to the leaf and gives it
// `operationGrace`. Each leaf turns the signal into a cancel of its service, records the run as
// cancelled, exits 125 and leaves no process behind. The built lungfish-cli runs against a stand-in
// samtools that writes its process ID and then sleeps, so the leaf is known to be at work when the
// signal arrives. No real tool and no network are needed. The parity class checks the same cancel
// through the app's transport, with the signal sent to the group and tree at once (SWIFT 3, S30 note 2).

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

final class BAMWorkflowLeavesSIGTERMTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bam-workflow-sigterm")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A conda root whose samtools answers a version probe and sleeps on any other call, after it wrote
    /// `$$`. The CLI reads the root from `LUNGFISH_CONDA_ROOT`, so the stand-in wins over any real samtools
    /// whatever app identity the built CLI has.
    private func stubCondaRoot(pidFile: URL) throws -> URL {
        let script = """
        #!/bin/sh
        case "$*" in
          *version*) echo "samtools 1.20"; exit 0 ;;
        esac
        echo $$ > '\(pidFile.path)'
        exec sleep 120
        """
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let binary = condaRoot.appendingPathComponent("envs/samtools/bin/samtools")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return condaRoot
    }

    /// Starts `arguments` against the stand-in, waits until samtools runs, sends one SIGTERM to the CLI
    /// and asserts exit 125 inside the grace, the cancelled record `recordStatus` reads, and no process left.
    /// Returns how the run ended, for a test that reads what the leaf printed.
    @discardableResult
    private func assertCancels(
        _ arguments: [String], recordStatus: @escaping () throws -> String?
    ) async throws -> CLISIGTERMHarness.Stop {
        let pidFile = root.appendingPathComponent("samtools.pid")
        let condaRoot = try stubCondaRoot(pidFile: pidFile)
        let run = try CLISIGTERMHarness.launchCLI(
            arguments, environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path], workingDirectory: root, testClass: Self.self
        )
        defer { run.stop() }
        let samtoolsPID = await CLISIGTERMHarness.waitForProcessID(in: pidFile)
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: recordStatus)
        XCTAssertNotNil(samtoolsPID, "the leaf never reached samtools. Standard output: \(stop.standardOutput)")
        return stop
    }

    /// The status of the one record under `bundle/provenance/cancelled`, or nil when there is none.
    private func cancelledRecordStatus(in bundle: URL) throws -> String? {
        let folder = bundle.appendingPathComponent("provenance/cancelled", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".lungfish-provenance.json") }
        XCTAssertEqual(names.count, 1, "one cancelled record, found \(names)")
        return try names.first.flatMap { try ProvenanceEnvelopeReader.load(fromSidecar: folder.appendingPathComponent($0))?.status.rawValue }
    }

    private func bundleURL() throws -> URL {
        try DerivedAlignmentTrackFixture.make(in: root).bundleURL
    }

    func testBamFilterTurnsSIGTERMIntoACancel() async throws {
        let bundle = try bundleURL()
        try await assertCancels(
            ["bam", "filter", "--bundle", bundle.path, "--alignment-track", DerivedAlignmentTrackFixture.sourceTrackID,
             "--output-track-name", "Mapped", "--mapped-only", "--format", "json"],
            recordStatus: { try self.cancelledRecordStatus(in: bundle) }
        )
        XCTAssertEqual(try BundleManifest.load(from: bundle).alignments.count, 2, "the bundle was not changed")
    }

    func testBamAnnotateTurnsSIGTERMIntoACancel() async throws {
        let bundle = try bundleURL()
        try await assertCancels(
            ["bam", "annotate", "--bundle", bundle.path, "--alignment-track", DerivedAlignmentTrackFixture.sourceTrackID,
             "--output-track-name", "Mapped Reads", "--format", "json"],
            recordStatus: { try self.cancelledRecordStatus(in: bundle) }
        )
        XCTAssertTrue(try BundleManifest.load(from: bundle).annotations.isEmpty, "the bundle was not changed")
    }

    func testBundleMarkDuplicatesTurnsSIGTERMIntoACancel() async throws {
        let bundle = try bundleURL()
        try await assertCancels(
            ["bundle", "mark-duplicates", bundle.path, "--format", "json"],
            recordStatus: { try self.cancelledRecordStatus(in: bundle) }
        )
    }

    func testBundleDeduplicateAlignmentsTurnsSIGTERMIntoACancel() async throws {
        let bundle = try bundleURL()
        let output = root.appendingPathComponent("Out.lungfishref")
        let sidecar = URL(fileURLWithPath: output.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)
        let stop = try await assertCancels(
            ["bundle", "deduplicate-alignments", bundle.path, "--output", output.path, "--format", "json"],
            recordStatus: { try ProvenanceEnvelopeReader.load(fromSidecar: sidecar)?.status.rawValue }
        )
        XCTAssertEqual(
            try BundleManifest.load(from: bundle).alignments.count, 2,
            "the source bundle was not changed"
        )
        // The service copied the bundle before samtools began, so the cancel must have removed the copy
        // (ruling on A54 deviation 4), and the leaf says so in its event and in its record.
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancelled deduplication leaves no copy")
        let note = "The source bundle was not changed, and no partial copy remains."
        XCTAssertTrue(stop.standardOutput.contains(note), "the failed event states the copy is gone: \(stop.standardOutput)")
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains(note), "the record states the copy is gone")
    }
}
