// BAMRemoveTrackSubcommandTests.swift - lungfish-cli bam remove-track, its words, its refusal and its cancel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M1. The Inspector's Remove Derived Alignment runs `bam remove-track`. The
// leaf prints the row's words as events, names its record when it completes, refuses a source
// alignment with exit 3 before anything changes, and turns SIGTERM into a cancel while it hashes
// the files (SWIFT 3). The SIGTERM check runs the built CLI on `CLISIGTERMHarness` with a sparse
// 64 GiB BAM, which the removal takes long enough to hash for the signal to find it at work.

import ArgumentParser
import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class BAMRemoveTrackSubcommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bam-remove-track")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private final class Lines: Sendable {
        private let state = Mutex<[String]>([])
        func append(_ line: String) { state.withLock { $0.append(line) } }
        var events: [CLIEvent] {
            let decoder = CLIEventLineDecoder()
            return state.withLock { $0 }.compactMap { try? decoder.decodeLine($0)?.event }
        }
    }

    private func recordURL(_ fixture: DerivedAlignmentTrackFixture) -> URL {
        BundleAlignmentTrackRemovalRecord.recordURL(bundleURL: fixture.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID)
    }

    func testTheLeafParsesTheCommandTheRowRecords() throws {
        let command = try BAMCommand.RemoveTrackSubcommand.parse([
            "--bundle", "/tmp/lane a51/Sample.lungfishref", "--track", "aln-derived", "--format", "json",
        ])
        XCTAssertEqual(command.bundlePath, "/tmp/lane a51/Sample.lungfishref")
        XCTAssertEqual(command.trackID, "aln-derived")
        XCTAssertThrowsError(try BAMCommand.RemoveTrackSubcommand.parse(["--bundle", "/tmp/x.lungfishref"]))
    }

    func testARemovalPrintsTheRowsWordsAndNamesItsRecord() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let command = try BAMCommand.RemoveTrackSubcommand.parse([
            "--bundle", fixture.bundleURL.path, "--track", DerivedAlignmentTrackFixture.derivedTrackID, "--format", "json",
        ])
        let lines = Lines()

        try await command.execute(eventsOn: true, quiet: false, emit: lines.append)

        let events = lines.events
        XCTAssertEqual(events.first, .start(message: "Removing Sample 1 filtered..."))
        guard case .complete(let outputs, let message)? = events.last else {
            return XCTFail("the run ends with complete: \(events)")
        }
        XCTAssertEqual(message, "Removed derived alignment track \"Sample 1 filtered\".")
        XCTAssertEqual(outputs, [recordURL(fixture).path])
        XCTAssertEqual(try BundleManifest.load(from: fixture.bundleURL).alignments.map(\.id), [DerivedAlignmentTrackFixture.sourceTrackID])
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: recordURL(fixture))?.status, .completed)
    }

    func testASourceAlignmentIsRefusedWithExit3AndNothingChanges() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let filesBefore = fixture.relativeFiles()
        let command = try BAMCommand.RemoveTrackSubcommand.parse([
            "--bundle", fixture.bundleURL.path, "--track", DerivedAlignmentTrackFixture.sourceTrackID, "--format", "json",
        ])
        let lines = Lines()

        do {
            try await command.execute(eventsOn: true, quiet: false, emit: lines.append)
            XCTFail("a source alignment must be refused")
        } catch let exit as ExitCode {
            XCTAssertEqual(exit.rawValue, CLIExitCode.inputError.rawValue)
        }

        guard case .failed(let message, _)? = lines.events.last else {
            return XCTFail("the refusal ends with failed: \(lines.events)")
        }
        XCTAssertEqual(message, BundleAlignmentTrackRemovalError.notDerivedTrack(DerivedAlignmentTrackFixture.sourceTrackID).localizedDescription)
        XCTAssertEqual(fixture.relativeFiles(), filesBefore)
    }

    func testSIGTERMWhileTheRemovalHashesCancelsItRecordsCancelledAndChangesNothing() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root, derivedBAMSize: 64 << 30)
        let bam = fixture.bundleURL.appendingPathComponent(DerivedAlignmentTrackFixture.derivedArtifactPaths[0])
        let manifestURL = fixture.bundleURL.appendingPathComponent(BundleManifest.filename)
        let manifestBefore = try Data(contentsOf: manifestURL)
        let record = recordURL(fixture)

        let cli = try CLISIGTERMHarness.launchCLI(
            ["bam", "remove-track", "--bundle", fixture.bundleURL.path, "--track", DerivedAlignmentTrackFixture.derivedTrackID, "--format", "json"],
            testClass: Self.self
        )
        defer { cli.stop() }

        let pid = cli.processIdentifier
        let atWork = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            OpenFileProbe.process(pid, holdsOpen: bam.path)
        }
        guard atWork else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never opened the BAM to hash it.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            try ProvenanceEnvelopeReader.load(fromSidecar: record)?.status.rawValue
        }
        XCTAssertTrue(stop.standardOutput.contains("Removal cancelled"), stop.diagnostics)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore, "a cancel leaves the manifest as it was")
        for path in DerivedAlignmentTrackFixture.derivedArtifactPaths + [DerivedAlignmentTrackFixture.derivedSidecarPath] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.bundleURL.appendingPathComponent(path).path), path)
        }
    }
}
