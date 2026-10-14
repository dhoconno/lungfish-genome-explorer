// SigningRecordVerification.swift - The provenance verify step of the narrow signing tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, BIO check 4. A writer with a narrow in-process test and no three-side run has no
// `assertSignaturesVerify` to prove its record verifies, so its test calls this on the record it checked was signed.
// The built `lungfish-cli provenance verify` must exit 0 with "Signature valid" on the record, and must exit nonzero
// on a copy of the record with one digit edited, checked against the signature and public key the record holds.
// An unedited control copy, checked the same way, must exit 0 with "Signature valid", so a copy that fails only
// because of where it sits cannot pass the tamper check.

import Foundation
import XCTest
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

enum SigningRecordVerification {
    /// Runs the check on `record`, with the edited copy under `scratch`. `testClass` finds the built CLI beside the test bundle.
    static func assertVerifies(
        _ record: URL, in scratch: URL, testClass: AnyClass, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let products = Bundle(for: testClass).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH", file: file, line: line
        )
        let verify = await RouteParityHarness.runCLI(cli, arguments: ["provenance", "verify", record.path], timeout: .seconds(60))
        XCTAssertEqual(verify.status, 0, "\(record.lastPathComponent): \(verify.detail)", file: file, line: line)
        XCTAssertTrue(verify.stdout.contains("Signature valid"), "\(record.lastPathComponent): \(verify.stdout)", file: file, line: line)

        let text = try String(contentsOf: record, encoding: .utf8)
        let edited = try XCTUnwrap(RouteParityHarness.editingOneDigit(of: text), "\(record.lastPathComponent) holds no digit", file: file, line: line)
        let folder = scratch.appendingPathComponent("tampered", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(record.lastPathComponent)
        try edited.write(to: copy, atomically: true, encoding: .utf8)
        let tampered = await RouteParityHarness.verifyCopy(copy, of: record, cli: cli)
        XCTAssertNotEqual(tampered.status, 0, "a one-digit edit of \(record.lastPathComponent) still verifies", file: file, line: line)
        XCTAssertFalse(tampered.stdout.contains("Signature valid"), "\(tampered.stdout)", file: file, line: line)
        await RouteParityHarness.assertUneditedCopyVerifies(record, in: scratch, cli: cli, file: file, line: line)
    }
}
