// UnsignedWriterFamiliesCLISigningTests.swift - A CLI command's own record is signed when a key is set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.14 (K10), M3, family S1. The commands that write the record of their result with
// `ProvenanceWriter(signingProvider: nil)` left it unsigned whatever the environment said. This runs
// `lungfish-cli variants extract-sample` as a subprocess (no network and no managed tool, so it runs on any Mac) with
// `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` set in the child's environment only. The record at its final path must verify
// and name exactly one signature, made by the local provider.
//
// The key is never set in this process, so no case can sign the record of another test. With no key the writer
// takes the same path as before and writes the same bytes, which the existing pins of the S1 commands hold.
//
// The review of M3 (Fix 1) adds the rollback. With a key set the record and `<record>.signature.json` and `<record>.pub`
// are one unit, so a failed export must give back the old record and leave no pair beside it. The two rollback cases
// fail the export in the two windows. The key cannot be published (after the signature), and the VCF cannot be replaced
// (after the whole signed write).

import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class UnsignedWriterFamiliesCLISigningTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "unsigned-families-cli")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// `variants extract-sample` writes the record of the VCF it publishes through `VariantsCommand.writeProvenance`,
    /// one of the 13 S1 sites. The case enters through the real binary, as the app's Cancel and Run buttons do.
    func testVariantsExtractSampleRecordIsSignedWhenAKeyFileIsSet() throws {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let output = root.appendingPathComponent("exports/sample-a.vcf")
        let run = try runCLI(
            arguments: extractSampleArguments(bundle: fixture.bundleURL, output: output),
            keyFile: try writeThrowawayKeyFile()
        )
        XCTAssertEqual(run.status, 0, "lungfish-cli failed. Its output: \(run.text)")

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: output.path), "the command published no VCF. Its output: \(run.text)")
        let record = ProvenanceRecorder.fileSidecarURL(for: output)
        XCTAssertTrue(fileManager.fileExists(atPath: record.path), "the command left no record at \(record.path)")
        XCTAssertTrue(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path),
            "no signature beside the record of variants extract-sample though a key file is set"
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: record).path),
            "no public key beside the record of variants extract-sample though a key file is set"
        )
        XCTAssertTrue(
            try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid,
            "the record of variants extract-sample does not verify"
        )
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: record))
        XCTAssertEqual(
            envelope.signatures.map(\.provider), [ProvenanceSigningConfiguration.localProviderID],
            "the record must name exactly one signature, made by the local provider"
        )
    }

    /// Review of M3, Fix 1, window (b). With a key set the writer replaces the record, publishes the signature and then
    /// the key. A failure on the key came out of the signed write, so the rollback never ran and the new record and its
    /// signature stayed beside a VCF that was never replaced. A non-empty folder at the key's name makes the key's
    /// publication fail after the signature's.
    func testAFailedSignedVariantsExportLeavesNoSignatureBesideTheRestoredRecord() throws {
        let export = try exportWithNoKey()
        let keyURL = ProvenanceSigningConfiguration.publicKeyURL(for: export.record)
        try FileManager.default.createDirectory(at: keyURL, withIntermediateDirectories: true)
        try "blocks the key".write(to: keyURL.appendingPathComponent("blocker.txt"), atomically: true, encoding: .utf8)

        let run = try runCLI(arguments: export.arguments, keyFile: try writeThrowawayKeyFile())

        XCTAssertNotEqual(run.status, 0, "the export succeeded though the public key could not be published. Its output: \(run.text)")
        assertGivenBack(export, run: run)
    }

    /// Review of M3, Fix 1, window (a). The record and its pair are written, then the rename that publishes the new VCF
    /// fails. An immutable VCF makes that rename throw. The rollback put back the record and left the pair.
    func testAFailedVariantsPublishAfterTheSignedWriteLeavesNoSignatureBesideTheRestoredRecord() throws {
        let export = try exportWithNoKey()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: export.output.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: export.output.path) }

        let run = try runCLI(arguments: export.arguments, keyFile: try writeThrowawayKeyFile())

        XCTAssertNotEqual(run.status, 0, "the export succeeded though the VCF could not be replaced. Its output: \(run.text)")
        assertGivenBack(export, run: run)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: export.record).path),
            "\(ProvenanceSigningConfiguration.publicKeyURL(for: export.record).lastPathComponent) stays beside the restored record"
        )
    }

    // MARK: Helpers

    /// One export with neither key variable in the child, so the record R0 has no pair. Its bytes and the VCF's are kept.
    private struct UnsignedExport {
        let arguments: [String]
        let output: URL
        let record: URL
        let recordBytes: Data
        let vcfBytes: Data
    }

    private func exportWithNoKey() throws -> UnsignedExport {
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let output = root.appendingPathComponent("exports/sample-a.vcf")
        let arguments = extractSampleArguments(bundle: fixture.bundleURL, output: output)
        let first = try runCLI(arguments: arguments, keyFile: nil)
        XCTAssertEqual(first.status, 0, "the unsigned export failed. Its output: \(first.text)")
        let record = ProvenanceRecorder.fileSidecarURL(for: output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path),
            "an ambient signing key signed the first export"
        )
        return UnsignedExport(
            arguments: arguments,
            output: output,
            record: record,
            recordBytes: try Data(contentsOf: record),
            vcfBytes: try Data(contentsOf: output)
        )
    }

    /// The failed export leaves the old record, no signature beside it and the old VCF.
    private func assertGivenBack(_ export: UnsignedExport, run: (status: Int32, text: String)) {
        let signature = ProvenanceSigningConfiguration.signatureURL(for: export.record)
        XCTAssertEqual(
            try? Data(contentsOf: export.record), export.recordBytes,
            "the failed export did not give back the record it replaced. Its output: \(run.text)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: signature.path),
            "\(signature.lastPathComponent) stays beside the restored record, a signature over bytes the record no longer holds"
        )
        XCTAssertEqual(try? Data(contentsOf: export.output), export.vcfBytes, "the failed export changed the VCF")
    }

    private func extractSampleArguments(bundle: URL, output: URL) -> [String] {
        ["variants", "extract-sample", bundle.path, "--sample", "SAMPLE_A", "--output", output.path, "--quiet"]
    }

    private func writeThrowawayKeyFile() throws -> URL {
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "unsigned-families-cli-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        return keyFile
    }

    private struct CLIDidNotExit: Error, CustomStringConvertible {
        let output: String
        var description: String { "lungfish-cli did not exit within 120 seconds. Its output: \(output)" }
    }

    /// Runs `lungfish-cli` as a subprocess. The key file, when there is one, is set in the child's environment only and
    /// the key text never is, so this process stays keyless.
    private func runCLI(arguments: [String], keyFile: URL?) throws -> (status: Int32, text: String) {
        guard let cli = CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        ) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        var environment = ProcessInfo.processInfo.environment
        environment[ProvenanceSigningConfiguration.signingKeyEnvironmentKey] = nil
        environment[ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey] = keyFile?.path
        let log = root.appendingPathComponent("cli-\(UUID().uuidString).log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let exited = finished.wait(timeout: .now() + 120) == .success
        if !exited { process.terminate() }
        try? logHandle.close()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard exited else { throw CLIDidNotExit(output: text) }
        return (process.terminationStatus, text)
    }
}
