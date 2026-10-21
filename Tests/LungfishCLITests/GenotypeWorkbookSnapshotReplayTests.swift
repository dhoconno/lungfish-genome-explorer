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

// MARK: - The receipt

extension GenotypeWorkbookSnapshotReplayTests {
    /// Condition 4 and BIO. The receipt carries the original request's options, defaults and runtime context under
    /// the leaf's own keys. A key both hold takes the leaf's value and keeps the original's under `original.<key>`.
    func testSnapshotReplayReceiptCarriesTheCapturedThresholds() async throws {
        let original = [
            "matrixMinimumReads": "5",
            "matrixMinimumPercent": "2.5",
            "minimumSupportPercent": "7.5",
            "matrixMinimumPrevalencePercent": "10",
            "annotationsInBundle": "the bundle has no annotations.json",
            "quickFilterPredicate": #"{"field":"sample","value":"AnimalA"}"#,
            "replacingExisting": "false",
            "output": outputURL.path,
            "snapshot": "/elsewhere/capture.json",
        ]
        let invocation = try writeInputs(options: original)
        let receipt = try await replay(invocation)
        let options = try XCTUnwrap(receipt["options"] as? [String: String])
        for key in ["matrixMinimumReads", "matrixMinimumPercent", "minimumSupportPercent", "matrixMinimumPrevalencePercent",
                    "annotationsInBundle", "quickFilterPredicate", "replacingExisting", "output"] {
            XCTAssertEqual(options[key], original[key], key)
        }
        XCTAssertEqual(options["snapshot"], invocation.capture, "the leaf's key wins")
        XCTAssertEqual(options["original.snapshot"], "/elsewhere/capture.json", "the original's value is kept")
        XCTAssertEqual(options["original.output"], outputURL.path)
        XCTAssertEqual(options["provenanceRequest"], invocation.request)
        XCTAssertEqual(options["force"], "false")
        let defaults = try XCTUnwrap(receipt["resolvedDefaults"] as? [String: String])
        XCTAssertEqual(defaults, ["worksheets": "all and current filtered view", "format": "xlsx", "force": "false"])
        let context = try XCTUnwrap(receipt["runtimeContext"] as? [String: String])
        XCTAssertEqual(context["entryPoint"], "Inspector Export to Excel")
        XCTAssertEqual(context["condaEnvironment"], "openpyxl")
        XCTAssertNotNil(context["python"])
        XCTAssertEqual(context["originalWorkflowName"], GenotypeWorkbookExport.requestWorkflowName)
        XCTAssertEqual(context["captureMode"], "durable-scientific-snapshot")
    }

    /// Condition 5. The receipt records the canonical argv, the row's command, and never the binary's own path.
    func testSnapshotReplayRecordsTheCanonicalArgv() async throws {
        let invocation = try writeInputs(options: [:])
        let receipt = try await replay(invocation)
        XCTAssertEqual(receipt["argv"] as? [String], invocation.canonicalArgv())
        XCTAssertEqual((receipt["argv"] as? [String])?.first, CLICommandIdentity.executableName)
        XCTAssertEqual(receipt["requestWorkflowName"] as? String, "genotype.export.excel.replay")
    }

    /// Lane 13.51. The receipt of the `--snapshot` replay names its tool, its kind and its workflow, keeps the
    /// original request's workflow, and names the durable replay of the same leaf and its own path.
    func testSnapshotReplayReceiptNamesItsToolKindAndWorkflow() async throws {
        let invocation = try writeInputs(options: [:])
        let receipt = try await replay(invocation)
        XCTAssertEqual(receipt["toolName"] as? String, CLICommandIdentity.executableName)
        XCTAssertEqual(receipt["toolKind"] as? String, "cli")
        XCTAssertEqual(receipt["workflowName"] as? String, "lungfish genotype export-xlsx")
        XCTAssertEqual(receipt["requestWorkflowName"] as? String, "genotype.export.excel.replay")
        XCTAssertTrue(GenotypeExcelExportService.isWorkbookReceipt(receipt))
        for value in ["Lungfish", "Lungfish.app", "lungfish-app", GenotypeExcelExportService.legacyReceiptToolName] {
            XCTAssertFalse(Self.strings(in: receipt).contains(value), "no value names \(value) as a tool")
        }
        XCTAssertEqual((receipt["runtimeContext"] as? [String: String])?["originalWorkflowName"],
                       GenotypeWorkbookExport.requestWorkflowName)
        let replay = try XCTUnwrap(receipt["durableReplayArgv"] as? [String])
        XCTAssertEqual(Array(replay.dropFirst().prefix(3)), GenotypeWorkbookExport.commandPath + ["--snapshot"])
        XCTAssertEqual(receipt["receiptPath"] as? String, invocation.output + ".provenance.json")
    }

    /// Every string value of a decoded JSON value, keys left out.
    static func strings(in value: Any) -> [String] {
        switch value {
        case let text as String: return [text]
        case let array as [Any]: return array.flatMap { strings(in: $0) }
        case let object as [String: Any]: return object.values.flatMap { strings(in: $0) }
        default: return []
        }
    }
}

