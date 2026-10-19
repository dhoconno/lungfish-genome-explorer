// SequenceAnnotationTrackSigningReplayTests.swift - The records of annotate-orfs and delete-annotation-track are signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.22 (S64), milestone M2 step 1. `SequenceAnnotationTrackWorkflow.writeProvenance` and
// `writeDeletionProvenance` built `ProvenanceWriter(signingProvider: nil)`, so `sequence annotate-orfs` and
// `sequence delete-annotation-track` left the bundle's record, the one the result opens first, unsigned with a key
// set, on the Sequence menu's CLI route and on the in-process call alike. Phase 2.10 lane Q-SIGN fixed the other
// writers of the file and left these two for 2.11 (Q-SIGN-b.md, "Sites left"). Each family runs once with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a throwaway key under the case root, on side A (the in-process call),
// side C (the built CLI) and side C' (the recorded command replayed), and fails when a side leaves the bundle's
// record unsigned. `assertSignaturesVerify` runs `lungfish-cli provenance verify` on every signed record, then on a
// copy with one digit edited, which must fail.
//
// It sets a process variable and launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class SequenceAnnotationTrackSigningReplayTests: XCTestCase {
    private nonisolated static let bundleName = "Fixture.lungfishref"

    private nonisolated static func bundle(in root: URL) -> URL {
        root.appendingPathComponent(bundleName, isDirectory: true)
    }

    /// The bundle's record in a side root, which both commands write and the result opens first.
    private nonisolated static func openingRecord(in root: URL) -> URL {
        bundle(in: root).appendingPathComponent(ProvenanceWriter.provenanceFilename)
    }

    func testAnORFTrackRecordLosesNoSignatureOnTheCLIRoute() async throws {
        let cli = try builtCLI()
        let scratch = try TestTempDirectory.make(prefix: "annotate-orfs-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(60))
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("orfs", isDirectory: true),
            fixture: { root in try self.writeFixture(root, inputs: scratch) },
            sideA: { root in await self.orfsSideA(root) },
            sideC: { root in await self.sideC(cli: cli, arguments: Self.orfsArguments(Self.bundle(in: root))) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    func testADeletedTrackRecordLosesNoSignatureOnTheCLIRoute() async throws {
        let cli = try builtCLI()
        let scratch = try TestTempDirectory.make(prefix: "delete-track-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(60))
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("delete", isDirectory: true),
            fixture: { root in try self.writeFixture(root, inputs: scratch) },
            sideA: { root in await self.deleteSideA(root) },
            sideC: { root in await self.sideC(cli: cli, arguments: Self.deleteArguments(Self.bundle(in: root))) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    // MARK: - A failed signed run

    /// Phase 2.10 fix FX-QSIGN, ARCH Fix 3, for the two commands that now sign. A signed run publishes the record, then
    /// its signature, then its public key. A failure on the key reaches the run's rollback, which must give back the
    /// record and leave no signature beside it. A non-empty folder at the key's name makes the key's publication fail
    /// after the signature's. Before this lane the two commands never touched the key, so the run succeeded.
    func testAFailedSignedTrackDeletionLeavesNoSignatureBesideTheRestoredRecord() async throws {
        let scratch = try TestTempDirectory.make(prefix: "delete-track-signing-rollback")
        defer { TestTempDirectory.cleanup(scratch) }
        let (root, bundle, record) = try rollbackFixture(in: scratch)
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the first run")
        let created = await orfsSideA(root)
        XCTAssertEqual(created.end, .completed, created.detail)
        let before = try Data(contentsOf: record)
        let manifestBefore = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))

        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }
        let keyURL = try blockPublicKey(of: record)
        do {
            _ = try await SequenceAnnotationTrackWorkflow.deleteTrack(.init(
                bundleURL: bundle, trackID: "orfs_chr1",
                command: [CLICommandIdentity.executableName] + Self.deleteArguments(bundle),
                explicitOptions: [:], defaultOptions: [:], resolvedOptions: [:], toolVersion: "test"
            ))
            XCTFail("the deletion succeeded though the public key could not be published")
        } catch {
            XCTAssertTrue("\(error)".contains(keyURL.lastPathComponent), "the deletion failed for another reason: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: record), before, "the failed deletion did not give back the record it replaced")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path),
            "the signature stays beside the restored record, a signature over bytes the record no longer holds"
        )
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("manifest.json")), manifestBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("annotations/orfs_chr1.db").path))
    }

    func testAFailedSignedORFRunLeavesNoSignatureBesideTheRestoredRecord() async throws {
        let scratch = try TestTempDirectory.make(prefix: "annotate-orfs-signing-rollback")
        defer { TestTempDirectory.cleanup(scratch) }
        let (root, bundle, record) = try rollbackFixture(in: scratch)
        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the first run")
        let created = await deleteSideA(root)
        XCTAssertEqual(created.end, .completed, created.detail)
        let before = try Data(contentsOf: record)
        let manifestBefore = try Data(contentsOf: bundle.appendingPathComponent("manifest.json"))

        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }
        let keyURL = try blockPublicKey(of: record)
        let failed = await orfsSideA(root)
        XCTAssertEqual(failed.end, .failed, "the run succeeded though the public key could not be published")
        XCTAssertTrue(failed.detail.contains(keyURL.lastPathComponent), "the run failed for another reason: \(failed.detail)")

        XCTAssertEqual(try Data(contentsOf: record), before, "the failed run did not give back the record it replaced")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path),
            "the signature stays beside the restored record, a signature over bytes the record no longer holds"
        )
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("manifest.json")), manifestBefore)
        for leftover in ["annotations/orfs_chr1.bed", "annotations/orfs_chr1.db"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(leftover).path), leftover)
        }
    }

    private func rollbackFixture(in scratch: URL) throws -> (root: URL, bundle: URL, record: URL) {
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFixture(root, inputs: scratch)
        return (root, Self.bundle(in: root), Self.openingRecord(in: root))
    }

    /// Puts a non-empty folder where the record's public key goes, and returns that path.
    private func blockPublicKey(of record: URL) throws -> URL {
        let keyURL = ProvenanceSigningConfiguration.publicKeyURL(for: record)
        try FileManager.default.createDirectory(at: keyURL, withIntermediateDirectories: true)
        try "blocks the key".write(to: keyURL.appendingPathComponent("blocker.txt"), atomically: true, encoding: .utf8)
        return keyURL
    }

    // MARK: - The sides

    private func builtCLI() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
    }

    /// One reference bundle of one 40-base chromosome with an ORF at its start and an `imported` annotation track.
    private func writeFixture(_ root: URL, inputs: URL) throws {
        let bundle = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: inputs)
        try (">chr1\nATGAAATAG" + String(repeating: "ACGTACGTAC", count: 3) + "A\n")
            .write(to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8)
    }

    private nonisolated static func orfsArguments(_ bundle: URL) -> [String] {
        [
            "sequence", "annotate-orfs", bundle.path, "--sequence", "chr1", "--start", "0", "--end", "40",
            "--frames", "+1", "--table", "1", "--min-length", "6", "--track-id", "orfs_chr1", "--track-name", "ORFs chr1",
        ]
    }

    private nonisolated static func deleteArguments(_ bundle: URL) -> [String] {
        ["sequence", "delete-annotation-track", bundle.path, "--track-id", "imported", "--quiet"]
    }

    /// Side A. The in-process call, with the request the leaf builds.
    private func orfsSideA(_ root: URL) async -> RouteParitySideOutcome {
        let bundle = Self.bundle(in: root)
        do {
            let result = try await SequenceAnnotationTrackWorkflow.run(.init(
                bundleURL: bundle,
                sequenceName: "chr1",
                start: 0,
                end: 40,
                frames: [.plus1],
                tableID: 1,
                trackID: "orfs_chr1",
                trackName: "ORFs chr1",
                kind: .orf(minLength: 6, includePartial: false, allowAlternativeStarts: false),
                command: [CLICommandIdentity.executableName] + Self.orfsArguments(bundle),
                explicitOptions: [:],
                defaultOptions: [:],
                resolvedOptions: [:],
                toolVersion: "test"
            ))
            return RouteParitySideOutcome(end: .completed, detail: "\(result.featureCount) ORFs")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    private func deleteSideA(_ root: URL) async -> RouteParitySideOutcome {
        let bundle = Self.bundle(in: root)
        do {
            let result = try await SequenceAnnotationTrackWorkflow.deleteTrack(.init(
                bundleURL: bundle,
                trackID: "imported",
                command: [CLICommandIdentity.executableName] + Self.deleteArguments(bundle),
                explicitOptions: [:],
                defaultOptions: [:],
                resolvedOptions: [:],
                toolVersion: "test"
            ))
            return RouteParitySideOutcome(end: .completed, detail: "Deleted \(result.trackID)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The built CLI on the arguments the Sequence menu's row runs, which returns the command side C' replays.
    private func sideC(cli: URL, arguments: [String]) async -> RouteParitySideOutcome {
        let run = await RouteParityHarness.runCLI(cli, arguments: arguments, timeout: .seconds(60))
        let command = ([CLICommandIdentity.executableName] + arguments)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
        return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command)
    }
}
