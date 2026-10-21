// GenotypeWorkbookReceiptIdentityTests.swift - The tool, kind and workflow the genotype workbook receipts name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import XCTest

/// Pins of the three genotype workbook receipts the goldens hold (Phase 2.13 lane 13.51 M0). The workbook and pivot
/// receipts come from the CLI `--bundle` path of `genotype export-xlsx` and `genotype export-pivot-xlsx`, and the
/// bundle receipt from the cohort pipeline. Each pin names the receipt's tool, its kind, its workflow, the request's
/// workflow, the head of its argv, the head of its durable replay and its own path.
final class GenotypeWorkbookReceiptIdentityTests: XCTestCase {
    private struct Pin {
        let path: String
        let requestWorkflow: String
        let argvHead: [String]
        let output: String
    }

    private static let pins: [Pin] = [
        Pin(path: "genotype/exports/workbook.xlsx.provenance.json", requestWorkflow: "genotype.export.xlsx",
            argvHead: ["<RUN_ROOT>/bin/lungfish-cli", "genotype", "export-xlsx", "--bundle"],
            output: "<RUN_ROOT>/genotype/exports/workbook.xlsx"),
        Pin(path: "genotype/exports/pivot.xlsx.provenance.json", requestWorkflow: "genotype.export.pivot-xlsx",
            argvHead: ["<RUN_ROOT>/bin/lungfish-cli", "genotype", "export-pivot-xlsx", "--bundle"],
            output: "<RUN_ROOT>/genotype/exports/pivot.xlsx"),
        Pin(path: "genotype/bundle/SIMULATED-MHC-haplotypes.xlsx.provenance.json", requestWorkflow: "genotype.pipeline.excel",
            argvHead: ["lungfish-cli", "fastq", "genotype-cohort"],
            output: "<RUN_ROOT>/genotype/out/SIMULATED-MHC-haplotypes.lungfishgenotype/SIMULATED-MHC-haplotypes.xlsx"),
    ]

    private static var goldenRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/golden", isDirectory: true)
    }

    private func receipt(_ pin: Pin) throws -> [String: Any] {
        let url = Self.goldenRoot.appendingPathComponent(pin.path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], pin.path)
    }

    func testGoldenReceiptsNameTheirToolKindAndWorkflow() throws {
        for pin in Self.pins {
            let receipt = try receipt(pin)
            XCTAssertEqual(receipt["toolName"] as? String, "lungfish genotype Excel export", pin.path)
            XCTAssertNil(receipt["toolKind"], pin.path)
            XCTAssertEqual(receipt["workflowName"] as? String, pin.requestWorkflow, pin.path)
            XCTAssertNil(receipt["requestWorkflowName"], pin.path)
            XCTAssertEqual(receipt["schemaVersion"] as? Int, 1, pin.path)
            XCTAssertEqual(receipt["status"] as? String, "completed", pin.path)
        }
    }

    func testGoldenReceiptsKeepTheirArgvReplayAndPath() throws {
        for pin in Self.pins {
            let receipt = try receipt(pin)
            let argv = try XCTUnwrap(receipt["argv"] as? [String], pin.path)
            XCTAssertEqual(Array(argv.prefix(pin.argvHead.count)), pin.argvHead, pin.path)
            let replay = try XCTUnwrap(receipt["durableReplayArgv"] as? [String], pin.path)
            XCTAssertEqual(replay.first, "<RUN_ROOT>/bin/" + CLICommandIdentity.executableName, pin.path)
            XCTAssertEqual(Array(replay.dropFirst().prefix(3)), ["genotype", "export-xlsx", "--snapshot"], pin.path)
            XCTAssertEqual(replay.firstIndex(of: "--output").map { replay[$0 + 1] }, pin.output, pin.path)
            XCTAssertEqual(receipt["receiptPath"] as? String, pin.output + ".provenance.json", pin.path)
            XCTAssertEqual((receipt["executedArgv"] as? [String])?.count, 4, pin.path)
            XCTAssertNotNil(receipt["runtime"] as? [String: Any], pin.path)
        }
    }
}
