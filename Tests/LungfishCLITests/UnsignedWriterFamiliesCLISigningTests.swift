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
// The key is never set in this process, so the case cannot sign the record of another test. With no key the writer
// takes the same path as before and writes the same bytes, which the existing pins of the S1 commands hold.

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
        guard let cli = CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        ) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let fixture = try VariantEditFixture.make(in: root, withTrackManifest: true)
        let output = root.appendingPathComponent("exports/sample-a.vcf")
        let keyFile = root.appendingPathComponent("signing-key.txt")
        try "unsigned-families-cli-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)

        var environment = ProcessInfo.processInfo.environment
        environment[ProvenanceSigningConfiguration.signingKeyEnvironmentKey] = nil
        environment[ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey] = keyFile.path
        let log = root.appendingPathComponent("cli.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let logHandle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = cli
        process.arguments = [
            "variants", "extract-sample", fixture.bundleURL.path,
            "--sample", "SAMPLE_A", "--output", output.path, "--quiet",
        ]
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let exited = finished.wait(timeout: .now() + 30) == .success
        if !exited { process.terminate() }
        try? logHandle.close()
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard exited else { return XCTFail("lungfish-cli did not exit within 30 seconds. Its output: \(text)") }
        XCTAssertEqual(process.terminationStatus, 0, "lungfish-cli failed. Its output: \(text)")

        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: output.path), "the command published no VCF. Its output: \(text)")
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
}
