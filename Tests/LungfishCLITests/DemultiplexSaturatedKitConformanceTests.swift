// DemultiplexSaturatedKitConformanceTests.swift - lungfish-cli refuses a kit the chance check cannot judge, and keeps it on choice
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-SATKIT (SATKIT-3 item 3), backlog DEMUX-FLOOR-SATURATED-KIT. The run through the CLI with
// managed cutadapt. Its stand-in, which needs no tool, is
// `DemultiplexSaturatedKitTests.testTheOptInKeepsTheBasesFilesAndNamesTheSaturatedNull` in the Workflow tests.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishCLI

final class DemultiplexSaturatedKitConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-satkit-conformance")
    }

    override func tearDown() {
        if let root { TestTempDirectory.cleanup(root) }
        super.tearDown()
    }

    /// QA's 384 kit (`DemultiplexSaturatedKitTests.qa384Barcodes`): 192 barcodes of 4 bases and 192 of 5, prefix free.
    private static func qa384Definition() -> String {
        let letters = Array("ACGT")
        let fours = (0..<256).map { value in String((0..<4).map { letters[(value >> (2 * (3 - $0))) & 3] }) }
        let fives = Array(fours.suffix(64).flatMap { prefix in letters.map { prefix + String($0) } }.prefix(192))
        let rows = (Array(fours.prefix(192)) + fives).enumerated().map {
            "BC\(String(format: "%03d", $0.offset + 1)),\($0.element)"
        }
        return (["id,sequence"] + rows).joined(separator: "\n") + "\n"
    }

    /// QA's 384 definition on the first 20,000 real E. coli read starts of SRR2584863, which carry no barcode. Without the
    /// opt-in the CLI refuses and writes no folder. With `--keep-unchecked-samples` it publishes the barcodes the floor of
    /// random bases passes, records the null `saturated-kit` and the opt-in, carries the flag in its recorded command, and
    /// its record is the narrower affected kind.
    func testTheCLIRefusesQAs384KitAndKeepsItsSamplesOnlyWithTheOptIn() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.cutadapt) else {
            try ToolAvailability.skipOrFail("managed cutadapt is not installed")
        }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = tests.appendingPathComponent("Fixtures/demux-null/SRR2584863-R1-first100000-starts12.txt")
        let starts = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").prefix(20_000)
        XCTAssertEqual(starts.count, 20_000)
        let input = project.appendingPathComponent("reads.fastq")
        try starts.enumerated().map { "@r\($0.offset)\n\($0.element)\n+\n\(String(repeating: "I", count: $0.element.count))\n" }
            .joined().write(to: input, atomically: true, encoding: .utf8)
        let definition = project.appendingPathComponent("QA 384.csv")
        try Self.qa384Definition().write(to: definition, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("Analyses/demux", isDirectory: true)
        let arguments = [input.path, "--kit", definition.path, "-o", output.path, "--engine", "cutadapt"]

        do {
            var command = try FastqDemultiplexSubcommand.parse(arguments)
            try await command.run()
            XCTFail("QA's 384 kit ran without the opt-in, so its chance matches are published as samples")
        } catch DemultiplexError.chanceCheckCannotJudgeKit(let kitName) {
            XCTAssertEqual(kitName, "QA 384")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refusal writes no folder")

        var command = try FastqDemultiplexSubcommand.parse(arguments + ["--keep-unchecked-samples"])
        try await command.run()
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output), "no manifest in \(output.path)")
        let published = manifest.barcodes.filter { $0.readCount > 0 }
        print("SATKIT CLI conformance: \(published.count) barcodes with reads, \(manifest.unassigned.readCount) unassigned")
        XCTAssertFalse(published.isEmpty, "the opt-in keeps the samples the floor of random bases passes")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertTrue(record.argv.contains("--keep-unchecked-samples"), "\(record.argv)")
        guard case .dictionary(let floor)? = record.options.explicit["chanceFloor"] else {
            return XCTFail("no chanceFloor block in \(record.options.explicit.keys.sorted())")
        }
        XCTAssertEqual(floor["null"], .string("saturated-kit"))
        XCTAssertEqual(floor["optIn"], .boolean(true))
        XCTAssertEqual(AffectedResults.kind(of: record), .fastqDemultiplexSaturatedKit)
    }
}
