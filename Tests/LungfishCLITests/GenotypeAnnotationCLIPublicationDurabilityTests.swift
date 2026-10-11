// GenotypeAnnotationCLIPublicationDurabilityTests.swift - The CLI genotype commands publish annotations.json and its record as one pair
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// `genotype apply-annotations` publishes `annotations.json` and its record
/// `annotations.json.lungfish-provenance.json` through the coordinator the GUI
/// uses, inside one `DurableReplace` transaction (row B8). Each case runs
/// natively and with every flagged rename taking its ExFAT fallback, and the
/// class runs under `exfat-tests.sh --simulate`.
final class GenotypeAnnotationCLIPublicationDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "genotype-cli-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// A crash point between the sidecar and its record leaves both old.
    /// Before row B8 the command renamed the sidecar into place and then wrote
    /// its records as a second publication, so a fault there left a new
    /// sidecar beside an old record.
    func testACrashPointBetweenTheSidecarAndItsRecordLeavesBothOld() async throws {
        for simulated in [false, true] {
            let fixture = try seed(label: simulated ? "exfat" : "apfs")
            let fault = FaultAfterTheSidecarChanges(sidecarURL: fixture.sidecarURL, oldBytes: fixture.oldSidecar)
            do {
                _ = try await DurableReplace.$overrideOperations.withValue(operations(fault, simulated: simulated)) {
                    try await GenotypeApplyAnnotationsSubcommand.apply(
                        bundleURL: fixture.bundleURL,
                        patchURL: fixture.patchURL
                    )
                }
                XCTFail("the fault must stop the command")
            } catch {}
            let mode = simulated ? "ExFAT" : "APFS"
            XCTAssertTrue(fault.fired, "\(mode): the fault fires once the sidecar holds new bytes")
            XCTAssertEqual(try Data(contentsOf: fixture.sidecarURL), fixture.oldSidecar, "\(mode): sidecar")
            XCTAssertEqual(try Data(contentsOf: fixture.recordURL), fixture.oldRecord, "\(mode): record")
            XCTAssertEqual(try leftovers(in: fixture.bundleURL), [], "\(mode): no stage or tombstone is left")
        }
    }

    func testThePairIsPublishedWithTheRecordCitingTheSidecarBytes() async throws {
        for simulated in [false, true] {
            let fixture = try seed(label: simulated ? "exfat" : "apfs")
            _ = try await DurableReplace.$overrideOperations.withValue(operations(nil, simulated: simulated)) {
                try await GenotypeApplyAnnotationsSubcommand.apply(
                    bundleURL: fixture.bundleURL,
                    patchURL: fixture.patchURL
                )
            }
            let mode = simulated ? "ExFAT" : "APFS"
            let published = try Data(contentsOf: fixture.sidecarURL)
            let sidecar = try GenotypeAnnotationSidecar.decode(published)
            XCTAssertEqual(sidecar.sampleNotes.map(\.body), ["old note", "patched note"], mode)
            let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: fixture.recordURL), mode)
            let output = try XCTUnwrap(record.outputs.first { $0.path.hasSuffix("/\(GenotypeAnnotationSidecar.filename)") }, mode)
            XCTAssertEqual(output.checksumSHA256, sha256(published), "\(mode): the record cites the published bytes")
            let prior = try XCTUnwrap(record.files.first { $0.path.hasSuffix("/\(GenotypeAnnotationSidecar.filename)") && $0.role == .input }, mode)
            XCTAssertEqual(prior.checksumSHA256, sha256(fixture.oldSidecar), "\(mode): the prior input cites the old bytes")
            let rootRecord = try XCTUnwrap(
                ProvenanceEnvelopeReader.load(fromSidecar: fixture.bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)),
                mode
            )
            XCTAssertEqual(rootRecord.workflowName, "lungfish genotype apply-annotations", mode)
            XCTAssertEqual(try leftovers(in: fixture.bundleURL), [], "\(mode): no stage or tombstone is left")
        }
    }

    /// An ExFAT swap that stopped halfway leaves the old sidecar under a
    /// tombstone and nothing under the name. The command restores it under the
    /// lock before it reads, so the patch merges into the analyst's annotations
    /// instead of replacing them with an empty file.
    func testAnInterruptedSwapIsRestoredBeforeTheSnapshotIsRead() async throws {
        let fixture = try seed(label: "tombstone")
        let tombstone = fixture.bundleURL.appendingPathComponent(
            ".\(GenotypeAnnotationSidecar.filename)\(PortableRename.swapTombstoneInfix)\(UUID().uuidString)"
        )
        XCTAssertEqual(Darwin.rename(fixture.sidecarURL.path, tombstone.path), 0)

        _ = try await GenotypeApplyAnnotationsSubcommand.apply(
            bundleURL: fixture.bundleURL,
            patchURL: fixture.patchURL
        )

        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: fixture.sidecarURL))
        XCTAssertEqual(sidecar.sampleNotes.map(\.body), ["old note", "patched note"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

    // MARK: - Helpers

    private struct Fixture {
        let bundleURL: URL
        let sidecarURL: URL
        let recordURL: URL
        let patchURL: URL
        let oldSidecar: Data
        let oldRecord: Data
    }

    private struct Fault: Error {}

    /// Fails the first durable stage that starts once the sidecar no longer
    /// holds its old bytes, which is the record's publication.
    private final class FaultAfterTheSidecarChanges: @unchecked Sendable {
        private let lock = NSLock()
        private var didFire = false
        private let sidecarURL: URL
        private let oldBytes: Data

        init(sidecarURL: URL, oldBytes: Data) {
            self.sidecarURL = sidecarURL
            self.oldBytes = oldBytes
        }

        var fired: Bool { lock.withLock { didFire } }

        func step(_ step: DurableReplace.Step) throws {
            guard step == .staged else { return }
            let changed = (try? Data(contentsOf: sidecarURL)) != oldBytes
            let fire = lock.withLock { () -> Bool in
                guard changed, !didFire else { return false }
                didFire = true
                return true
            }
            if fire { throw Fault() }
        }
    }

    private func operations(_ fault: FaultAfterTheSidecarChanges?, simulated: Bool) -> DurableReplace.Operations {
        var rename = PortableRename.Operations()
        if simulated {
            rename.nativeRename = { sourceParent, source, destinationParent, destination, flags in
                if flags != 0 {
                    errno = ENOTSUP
                    return -1
                }
                return Darwin.renameatx_np(sourceParent, source, destinationParent, destination, flags)
            }
        }
        return DurableReplace.Operations(rename: rename, checkpoint: { try fault?.step($0) })
    }

    /// A genotype bundle inside a project that holds an old sidecar and an old
    /// record of it, and a patch that adds one note.
    private func seed(label: String) throws -> Fixture {
        let bundleURL = root.appendingPathComponent("\(label)/P.lungfish/Analyses/Result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let recordURL = ProvenanceRecorder.fileSidecarURL(for: sidecarURL)
        var old = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        old.sampleNotes = [.init(sample: "DW472", body: "old note", author: "analyst", timestamp: "2026-10-11T00:01:00Z")]
        let oldSidecar = try old.encoded()
        try oldSidecar.write(to: sidecarURL)
        let oldRecord = Data(#"{"generation":"old","file":"record"}"#.utf8)
        try oldRecord.write(to: recordURL)
        try Data(#"{"generation":"old","file":"root record"}"#.utf8)
            .write(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        var patch = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        patch.sampleNotes = [.init(sample: "DW472", body: "patched note", author: "analyst", timestamp: "2026-10-11T00:02:00Z")]
        let patchURL = root.appendingPathComponent("\(label)/patch.json")
        try patch.encoded().write(to: patchURL)
        return Fixture(
            bundleURL: bundleURL,
            sidecarURL: sidecarURL,
            recordURL: recordURL,
            patchURL: patchURL,
            oldSidecar: oldSidecar,
            oldRecord: oldRecord
        )
    }

    private func leftovers(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains(DurableReplace.stageInfix) || $0.contains(PortableRename.swapTombstoneInfix) }
            .sorted()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
