// BundleAlignmentTrackRemovalDurabilityTests.swift - The removal's record, its cancel and its partial ends
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M1 (2.7 E7, BIO 6, SWIFT 4). Removing a derived alignment track writes a
// record that names each removed file with the digest and size of its bytes, after the manifest no
// longer names the track and before any file goes. A cancel before the manifest changes leaves the
// bundle as it was and records the run as cancelled. A record that cannot be written puts the
// manifest back and removes nothing, and a file that cannot be deleted is left and reported. The
// name holds "Durability", so `scripts/testing/exfat-tests.sh --simulate` runs it too.

import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class BundleAlignmentTrackRemovalDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "track-removal-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func record(of fixture: DerivedAlignmentTrackFixture) throws -> ProvenanceEnvelope {
        let url = BundleAlignmentTrackRemovalRecord.recordURL(
            bundleURL: fixture.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
        )
        return try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: url), "no record at \(url.path)")
    }

    func testTheRecordNamesEachRemovedFileWithItsDigestAndTheSavedManifest() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let removedPaths = DerivedAlignmentTrackFixture.derivedArtifactPaths + [DerivedAlignmentTrackFixture.derivedSidecarPath]
        var digests: [String: String] = [:]
        for path in removedPaths {
            digests[path] = try Self.sha256(of: fixture.bundleURL.appendingPathComponent(path))
        }

        _ = try await BundleAlignmentTrackRemovalService().removeDerivedAlignmentTrack(
            bundleURL: fixture.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
        )

        let record = try Self.record(of: fixture)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(
            record.argv,
            BundleAlignmentTrackRemovalService.cliArgv(bundleURL: fixture.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID)
        )
        let manifestURL = fixture.bundleURL.appendingPathComponent(BundleManifest.filename)
        let output = try XCTUnwrap(record.outputs.first)
        XCTAssertEqual(record.outputs.count, 1)
        XCTAssertEqual(fixture.relativePath(of: URL(fileURLWithPath: output.path)), BundleManifest.filename)
        XCTAssertEqual(output.checksumSHA256, try Self.sha256(of: manifestURL), "the manifest as the removal saved it")
        let removal = try XCTUnwrap(record.steps.first { $0.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) })
        XCTAssertEqual(removal.inputs.map { fixture.relativePath(of: URL(fileURLWithPath: $0.path)) }, removedPaths)
        for input in removal.inputs {
            let path = fixture.relativePath(of: URL(fileURLWithPath: input.path))
            XCTAssertEqual(input.checksumSHA256, digests[path], path)
            XCTAssertNotNil(input.fileSize, path)
        }
        XCTAssertEqual(removal.dependsOn.count, 1, "the removal step follows the manifest step")
        // Every route records LungfishAppVersion.short, never the version of a host such as xctest.
        let versions: [String?] = [record.workflowVersion, record.toolVersion, record.runtimeIdentity.appVersion]
            + record.steps.map { $0.toolVersion }
        XCTAssertEqual(versions, [String?](repeating: LungfishAppVersion.short, count: versions.count))
    }

    func testACancelBeforeTheManifestChangesRecordsCancelledAndChangesNothing() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let filesBefore = fixture.relativeFiles()
        let manifestBefore = try Data(contentsOf: fixture.bundleURL.appendingPathComponent(BundleManifest.filename))

        let task = Task {
            // The cancel below ends the sleep at once, so the removal starts in a cancelled task.
            try? await Task.sleep(for: .seconds(30))
            return try await BundleAlignmentTrackRemovalService().removeDerivedAlignmentTrack(
                bundleURL: fixture.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled removal must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertEqual(try Data(contentsOf: fixture.bundleURL.appendingPathComponent(BundleManifest.filename)), manifestBefore)
        XCTAssertEqual(
            fixture.relativeFiles(),
            (filesBefore + ["provenance/removals/aln-derived.lungfish-provenance.json"]).sorted()
        )
        let record = try Self.record(of: fixture)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.outputs, [], "a cancelled removal claims no result")
    }

    func testARecordThatCannotBeWrittenPutsTheManifestBackAndRemovesNothing() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let filesBefore = fixture.relativeFiles()
        struct RecordWriteFailed: Error {}
        let service = BundleAlignmentTrackRemovalService(recordWriter: { _, _ in throw RecordWriteFailed() })

        do {
            _ = try await service.removeDerivedAlignmentTrack(
                bundleURL: fixture.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
            )
            XCTFail("a removal whose record fails must throw")
        } catch {
            XCTAssertTrue(error is RecordWriteFailed, "\(error)")
        }

        XCTAssertEqual(
            try BundleManifest.load(from: fixture.bundleURL).alignments.map(\.id),
            [DerivedAlignmentTrackFixture.sourceTrackID, DerivedAlignmentTrackFixture.derivedTrackID]
        )
        XCTAssertEqual(fixture.relativeFiles(), filesBefore)
    }

    func testAFileThatCannotBeDeletedIsLeftAndReported() async throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        let stuck = DerivedAlignmentTrackFixture.derivedArtifactPaths[1]
        let service = BundleAlignmentTrackRemovalService(
            fileManager: RefusingRemovalFileManager(refusing: fixture.bundleURL.appendingPathComponent(stuck).path)
        )

        let result = try await service.removeDerivedAlignmentTrack(
            bundleURL: fixture.bundleURL, trackID: DerivedAlignmentTrackFixture.derivedTrackID
        )

        XCTAssertEqual(result.leftoverArtifactURLs.map(fixture.relativePath(of:)), [stuck])
        XCTAssertEqual(
            try BundleManifest.load(from: fixture.bundleURL).alignments.map(\.id),
            [DerivedAlignmentTrackFixture.sourceTrackID]
        )
        XCTAssertEqual(
            fixture.relativeFiles(),
            (DerivedAlignmentTrackFixture.sourcePaths
                + [BundleManifest.filename, stuck, "provenance/removals/aln-derived.lungfish-provenance.json"]).sorted()
        )
        XCTAssertEqual(try Self.record(of: fixture).status, .completed)
    }
}

/// A file manager that refuses to remove one path.
final class RefusingRemovalFileManager: FileManager {
    private let refusedPath: String

    init(refusing path: String) {
        refusedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if url.standardizedFileURL.path == refusedPath {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
