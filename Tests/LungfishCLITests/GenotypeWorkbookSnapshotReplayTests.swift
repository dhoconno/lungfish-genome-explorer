// GenotypeWorkbookSnapshotReplayTests.swift - genotype export-xlsx --snapshot, the leaf the genotype viewer's workbook runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.35 row B1, ARCH-12.35-B1 route (a). The viewer writes `capture.json` and `request.json` with
// `GenotypeWorkbookExport.write` and the row runs `genotype export-xlsx --snapshot`. Each test writes the two files as
// the viewer does, runs the parsed leaf in process with the managed openpyxl Python and reads its receipt.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class GenotypeWorkbookSnapshotReplayTests: XCTestCase {
    static let timestamp = "2026-10-18T00:00:00Z"

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "genotype-workbook-replay")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Condition 1. The capture is written with the service's one encoder, so the receipt's input digest of
    /// `capture.json` equals its `snapshot.sha256`.
    func testWorkbookCaptureFileDigestEqualsReceiptSnapshotDigest() async throws {
        let invocation = try writeInputs(options: [:])
        let receipt = try await replay(invocation)
        let inputs = try XCTUnwrap(receipt["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.compactMap { $0["path"] as? String }, [invocation.capture, invocation.request])
        let capture = try XCTUnwrap(inputs.first { $0["path"] as? String == invocation.capture })
        let snapshot = try XCTUnwrap(receipt["snapshot"] as? [String: Any])
        XCTAssertEqual(capture["sha256"] as? String, snapshot["sha256"] as? String)
        XCTAssertEqual(capture["sha256"] as? String, Self.digest(try Data(contentsOf: URL(fileURLWithPath: invocation.capture))))
        XCTAssertEqual(capture["sizeBytes"] as? Int, snapshot["sizeBytes"] as? Int)
    }

    // MARK: - Support

    static var python: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".lungfish", ".lungfish-debug"].flatMap { folder in
            ["python3", "python"].map { home.appendingPathComponent("\(folder)/conda/envs/openpyxl/bin/\($0)") }
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var outputURL: URL { root.appendingPathComponent("report.xlsx") }

    /// One call's capture as the viewer freezes it and a request with `options`, written as the viewer writes them.
    func writeInputs(options: [String: String]) throws -> GenotypeWorkbookExport.Invocation {
        let python = try XCTUnwrap(Self.python, "the managed openpyxl Python renders the workbook")
        let result = GenotypeTestFixtures.makeResult(calls: [
            GenotypeTestFixtures.makeCall(sample: "AnimalA", genotype: "Mafa-A*001", reads: 9),
        ])
        let capture = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: .empty(generatedAt: Self.timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: Self.timestamp, authority: .init(analysis: nil),
            filter: .init(matrixMinimumReads: 5))
        let urls = GenotypeWorkbookExport.inputURLs(besideOutput: outputURL)
        let invocation = GenotypeWorkbookExport.Invocation(
            captureURL: urls.capture, requestURL: urls.request, pythonURL: python, outputURL: outputURL, force: false
        )
        let request = GenotypeExcelExportService.ProvenanceRequest(
            workflowName: GenotypeWorkbookExport.requestWorkflowName, toolVersion: "test", argv: invocation.canonicalArgv(),
            options: options, defaults: ["worksheets": "all and current filtered view", "format": "xlsx"],
            runtimeContext: ["entryPoint": "Inspector Export to Excel", "condaEnvironment": "openpyxl", "python": python.path]
        )
        try GenotypeWorkbookExport.write(capture: capture, request: request, to: invocation)
        return invocation
    }

    /// Runs the parsed leaf for `invocation` and returns its receipt.
    func replay(_ invocation: GenotypeWorkbookExport.Invocation) async throws -> [String: Any] {
        let command = try GenotypeExportXlsxSubcommand.parse(
            Array(invocation.arguments().dropFirst(GenotypeWorkbookExport.commandPath.count))
        )
        try await command.run()
        let receiptURL = URL(fileURLWithPath: invocation.output).appendingPathExtension("provenance.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
    }
}

