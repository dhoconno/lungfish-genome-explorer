// ReferenceBundleManualAnnotationLogSigningReplayTests.swift - The log that Add Annotation appends to is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.22 (S64), milestone M2 step 2. `ReferenceBundleManualAnnotationService.addAnnotation` appends an
// entry to `annotations/manual-annotation-provenance.json` and wrote the whole file with `Data.write(.atomic)`, so
// `sequence add-annotation` and the in-process add left an unsigned log with a key set (Q-SIGN-b.md, "Outside
// `ProvenanceWriter`"). The log is not an envelope and keeps its file format. The service now hands the bytes to
// `ProvenanceWriter.writeDocument`, which publishes them as a record is published and signs them over their raw bytes.
//
// - The family case runs the add on side A (in process), side C (the built CLI on the argv the Sequence menu's row
//   builds) and side C' (the recorded command replayed) under a throwaway key, with `assertNoSignatureLost` naming the
//   log as the record the result opens first, and `assertSignaturesVerify`.
// - The signature covers the whole file as it is at the write, every entry. A later keyless append removes the pair,
//   so the log reads as unsigned and never as tampered, and a later append with a key signs the file again.
//
// It sets a process variable and launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ReferenceBundleManualAnnotationLogSigningReplayTests: XCTestCase {
    private nonisolated static func bundle(in root: URL) -> URL {
        root.appendingPathComponent("Fixture.lungfishref", isDirectory: true)
    }

    /// The log, the only record `addAnnotation` writes and so the one the result opens first.
    private nonisolated static func openingRecord(in root: URL) -> URL {
        log(in: bundle(in: root))
    }

    private nonisolated static func log(in bundle: URL) -> URL {
        bundle.appendingPathComponent("annotations/manual-annotation-provenance.json")
    }

    private static func annotation(_ name: String) -> SequenceAnnotation {
        SequenceAnnotation(
            type: .primer,
            name: name,
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 4, end: 20)],
            strand: .reverse
        )
    }

    // MARK: - The family case

    func testTheLogLosesNoSignatureOnTheCLIRoute() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        let scratch = try TestTempDirectory.make(prefix: "add-annotation-log-signing")
        defer { TestTempDirectory.cleanup(scratch) }
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(60))
        let runs = try await harness.runSigned(
            in: scratch.appendingPathComponent("add", isDirectory: true),
            fixture: { root in _ = try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch) },
            sideA: { root in await self.sideA(root) },
            sideC: { root in await self.sideC(root, cli: cli) }
        )
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        RouteParityHarness.assertNoSignatureLost(runs, opening: Self.openingRecord)
        await harness.assertSignaturesVerify(runs, opening: Self.openingRecord)
    }

    // MARK: - The log under a key

    func testTheSignatureCoversTheWholeLogAfterEachAppend() async throws {
        let scratch = try TestTempDirectory.make(prefix: "add-annotation-log-append")
        defer { TestTempDirectory.cleanup(scratch) }
        let bundle = try makeBundle(in: scratch)
        let log = Self.log(in: bundle)
        let service = ReferenceBundleManualAnnotationService()
        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { saved.restore() }

        _ = try await service.addAnnotation(Self.annotation("first"), toBundleAt: bundle)
        let afterFirst = try ProvenanceSignatureVerifier.verify(provenanceURL: log).provenanceSHA256
        _ = try await service.addAnnotation(Self.annotation("second"), toBundleAt: bundle)

        XCTAssertTrue(RouteParityHarness.isSigned(log), "the log has no signature and public key though a key is set")
        let result = try ProvenanceSignatureVerifier.verify(provenanceURL: log)
        XCTAssertTrue(result.isValid)
        XCTAssertNotEqual(result.provenanceSHA256, afterFirst, "the second append left the first signature in place")
        let bytes = try Data(contentsOf: log)
        XCTAssertEqual(
            result.provenanceSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "a log is signed over its raw bytes"
        )
        XCTAssertEqual(try entryCount(of: log), 2)
        try await SigningRecordVerification.assertVerifies(log, in: scratch, testClass: Self.self)
    }

    // MARK: - A keyless append into a signed log

    func testAKeylessAppendIntoASignedLogLeavesItUnsignedAndNotTampered() async throws {
        let scratch = try TestTempDirectory.make(prefix: "add-annotation-log-keyless")
        defer { TestTempDirectory.cleanup(scratch) }
        let bundle = try makeBundle(in: scratch)
        let log = Self.log(in: bundle)
        let service = ReferenceBundleManualAnnotationService()
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(for: log)
        let publicKeyURL = ProvenanceSigningConfiguration.publicKeyURL(for: log)

        let saved = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        _ = try await service.addAnnotation(Self.annotation("signed"), toBundleAt: bundle)
        saved.restore()
        XCTAssertTrue(RouteParityHarness.isSigned(log), "the first append left no signature, so there is nothing to drop")

        XCTAssertNil(ProvenanceSigningConfiguration.defaultProvider(), "an ambient signing key would sign the second append")
        _ = try await service.addAnnotation(Self.annotation("keyless"), toBundleAt: bundle)

        XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL.path), "the stale signature stayed beside the new bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicKeyURL.path), "the stale public key stayed beside the new bytes")
        XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: log)) { error in
            XCTAssertEqual(
                error as? ProvenanceSignatureVerificationError, .signatureMissing(signatureURL.path),
                "the log reads as unsigned, never as a digest mismatch"
            )
        }
        XCTAssertEqual(try entryCount(of: log), 2, "the keyless append lost an entry")

        // A later append with a key signs the whole file again, the keyless entry included.
        let again = RouteParityHarness.SigningEnvironment(keyFile: try RouteParityHarness.writeSigningKey(in: scratch))
        defer { again.restore() }
        _ = try await service.addAnnotation(Self.annotation("signed again"), toBundleAt: bundle)
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: log).isValid)
        XCTAssertEqual(try entryCount(of: log), 3)
    }

    // MARK: - The sides and the fixture

    private func makeBundle(in scratch: URL) throws -> URL {
        let root = scratch.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try AnnotationEditRouteParityTests.makeBundle(in: root, inputs: scratch)
    }

    private func entryCount(of log: URL) throws -> Int {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])
        return try XCTUnwrap(json["entries"] as? [Any]).count
    }

    /// Side A. The in-process add both sites made at the base.
    private func sideA(_ root: URL) async -> RouteParitySideOutcome {
        do {
            let result = try await ReferenceBundleManualAnnotationService().addAnnotation(
                Self.annotation("-35 box"), toBundleAt: Self.bundle(in: root)
            )
            return RouteParitySideOutcome(end: .completed, detail: "\(result.featureCount) annotations")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The begin helper both sites call, then the built CLI on the argv it hands the launch. It returns the
    /// row's command, which side C' replays.
    private func sideC(_ root: URL, cli: URL) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        var launched: [String]?
        await AppDelegate.beginManualReferenceAnnotationOperation(
            annotation: Self.annotation("-35 box"), chromosome: "chr1", bundleURL: Self.bundle(in: root),
            routeContext: nil, reporter: reporter
        ) { _, argv in launched = argv }
        guard let launched, launched.first == CLICommandIdentity.executableName,
              let command = reporter.items.first?.cliCommand else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start or built no lungfish-cli argv")
        }
        let run = await RouteParityHarness.runCLI(cli, arguments: Array(launched.dropFirst()), timeout: .seconds(60))
        return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: command)
    }
}
