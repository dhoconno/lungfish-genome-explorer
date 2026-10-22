// ImportFastqOptionsTests.swift - The settings group and the shared run that import fastq and fetch sra download --bundle use
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, ruling A45-M3 section 1. The group holds the seven flags of
// `CLIImportRunner.buildCLIArguments`, `import fastq` forwards its old property names, and
// `FASTQImportRun` reports through the reporter it is given and prints no start, summary or complete line.

import ArgumentParser
import Foundation
import XCTest
import LungfishWorkflow
@testable import LungfishCLI

final class ImportFastqOptionsTests: XCTestCase {
    private let allSeven = [
        "--platform", "ont", "--pairing", "paired", "--quality-binning", "illumina4", "--compression", "fast",
        "--recipe", "vsp2", "--no-optimize-storage", "--clumping-tool", "bbtools",
    ]

    func testTheGroupParsesTheSevenSettingsOfTheSheet() throws {
        let options = try ImportFastqOptions.parse(allSeven)
        XCTAssertEqual(options.platform, "ont")
        XCTAssertEqual(options.pairing, "paired")
        XCTAssertEqual(options.qualityBinning, "illumina4")
        XCTAssertEqual(options.compression, "fast")
        XCTAssertEqual(options.recipe, "vsp2")
        XCTAssertTrue(options.noOptimizeStorage)
        XCTAssertEqual(options.clumpingTool, "bbtools")
    }

    func testTheGroupKeepsTheDefaultsImportFastqHadBefore() throws {
        let options = try ImportFastqOptions.parse([])
        XCTAssertEqual(options.platform, "auto")
        XCTAssertEqual(options.pairing, "auto")
        XCTAssertNil(options.qualityBinning)
        XCTAssertEqual(options.compression, "balanced")
        XCTAssertEqual(options.recipe, "none")
        XCTAssertFalse(options.noOptimizeStorage)
        XCTAssertNil(options.clumpingTool)
    }

    func testImportFastqForwardsTheNamesItHadBeforeTheGroup() throws {
        let command = try ImportCommand.FastqSubcommand.parse(["a.fastq", "--project", "P.lungfish"] + allSeven)
        XCTAssertEqual(command.platform, "ont")
        XCTAssertEqual(command.pairing, "paired")
        XCTAssertEqual(command.qualityBinning, "illumina4")
        XCTAssertEqual(command.compression, "fast")
        XCTAssertEqual(command.recipe, "vsp2")
        XCTAssertTrue(command.noOptimizeStorage)
        XCTAssertEqual(command.clumpingTool, "bbtools")
        XCTAssertEqual(command.input, ["a.fastq"])
    }

    func testImportFastqHelpStillNamesEachSetting() {
        let help = ImportCommand.FastqSubcommand.helpMessage()
        for flag in ["--platform", "--pairing", "--quality-binning", "--compression", "--recipe", "--no-optimize-storage", "--clumping-tool"] {
            XCTAssertTrue(help.contains(flag), "\(flag) in\n\(help)")
        }
    }

    // MARK: - The shared run

    private final class Recorder: FASTQImportReporting, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var failures: [String] = []
        var text: [String] { lock.withLock { lines } }
        var failed: [String] { lock.withLock { failures } }

        func text(_ line: String) { lock.withLock { lines.append(line) } }
        func pairingNotice(sample: String, message: String) { lock.withLock { lines.append("notice \(sample): \(message)") } }
        func log(_ event: ImportLogEvent) {}
        func fail(_ message: String, detail: String?, exitCode: CLIExitCode) -> ExitCode {
            lock.withLock { failures.append(message) }
            return exitCode.exitCode
        }
        func failedEvent(_ message: String) { lock.withLock { failures.append(message) } }
    }

    private func makeReads() throws -> (folder: URL, r1: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-fastq-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let r1 = folder.appendingPathComponent("SRR1_1.fastq")
        try "@r1/1\nACGT\n+\nIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        return (folder, r1)
    }

    func testADryRunPrintsTheDetectedSampleThroughTheReporterAndReturnsNil() async throws {
        let (folder, r1) = try makeReads()
        let recorder = Recorder()
        var run = FASTQImportRun(input: [r1.path], samplesheet: nil, project: folder.appendingPathComponent("P.lungfish").path)
        run.dryRun = true
        let result = try await run.run(reporter: recorder, cancellation: .followsCallingTask)
        XCTAssertNil(result, "a dry run imports nothing")
        let text = recorder.text.joined(separator: "\n")
        XCTAssertTrue(text.contains("Detected 1 sample(s)"), text)
        XCTAssertTrue(text.contains("Dry-run mode"), text)
        XCTAssertEqual(recorder.failed, [])
    }

    func testAnUnknownPairingFailsThroughTheReporterWithTheInputErrorCode() async throws {
        let (folder, r1) = try makeReads()
        let recorder = Recorder()
        var run = FASTQImportRun(input: [r1.path], samplesheet: nil, project: folder.path)
        run.pairing = "sideways"
        do {
            _ = try await run.run(reporter: recorder, cancellation: .followsCallingTask)
            XCTFail("an unknown pairing is refused")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
        }
        XCTAssertEqual(recorder.failed, ["Unknown pairing value 'sideways'. Valid: auto, single, paired, interleaved"])
    }

    func testNoInputFailsBeforeAnythingIsDetected() async throws {
        let recorder = Recorder()
        let run = FASTQImportRun(input: [], samplesheet: nil, project: "P.lungfish")
        do {
            _ = try await run.run(reporter: recorder, cancellation: .installsSIGTERMHandler)
            XCTFail("an import needs input")
        } catch is ExitCode {}
        XCTAssertEqual(recorder.failed, ["At least one input path or --samplesheet is required."])
        XCTAssertEqual(recorder.text, [])
    }
}
