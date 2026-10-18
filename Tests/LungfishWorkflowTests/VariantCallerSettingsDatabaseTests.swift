// VariantCallerSettingsDatabaseTests.swift - The caller-settings text read from a variant database alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 item 5. `bundle export-annotation-table` writes the drawer's
/// caller-settings text from the variant database, the parameters first, then the command line.
final class VariantCallerSettingsDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("caller-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testParametersWinThenCommandLineThenNotRecorded() throws {
        let parameters = try makeDatabase("parameters", metadata: [
            "variant_caller_parameters_json": #"{"minimumDepth":10,"caller":"ivar"}"#,
            "variant_caller_command_line": "ivar variants -m 10",
        ])
        let command = try makeDatabase("command", metadata: ["variant_caller_command_line": "ivar variants -m 10"])
        let neither = try makeDatabase("neither", metadata: [:])

        XCTAssertEqual(VariantCallerSettingsSummary.text(databaseURL: parameters), "Caller: ivar; Minimum depth: 10")
        XCTAssertEqual(VariantCallerSettingsSummary.text(databaseURL: command), "ivar variants -m 10")
        XCTAssertEqual(VariantCallerSettingsSummary.text(databaseURL: neither), "Not recorded")
    }

    private func makeDatabase(_ name: String, metadata: [String: String]) throws -> URL {
        let vcf = directory.appendingPathComponent("\(name).vcf")
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t100\trs1\tA\tG\t50\tPASS\t.\n"
            .write(to: vcf, atomically: true, encoding: .utf8)
        let url = directory.appendingPathComponent("\(name).db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcf, outputURL: url)
        if !metadata.isEmpty {
            try VariantDatabase(url: url, readWrite: true).setMetadataValues(metadata)
        }
        return url
    }
}
