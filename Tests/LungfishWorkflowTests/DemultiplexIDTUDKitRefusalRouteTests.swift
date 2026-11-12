// DemultiplexIDTUDKitRefusalRouteTests.swift - The kit id the CLI takes is refused before any read is assigned
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Trust session lane PROBES-A, row IDT-UD-SEQUENCES. `lungfish-cli fastq demultiplex --kit idt-ud-indexes` looks the
// kit up with `BarcodeKitRegistry.kit(byID:)`, then calls `preflight` and `run` (`FastqCommand.swift`,
// `FastqDemultiplexSubcommand.run`). LungfishWorkflowTests cannot import LungfishCLI, so this test drives the same two
// calls on the same configuration and shows that cutadapt never starts and nothing is written. The by-hand run of the
// built `lungfish-cli` is in the lane report.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class DemultiplexIDTUDKitRefusalRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "demux-idt-ud-refusal")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func makeManagedTool(root: URL, environment: String, executable: String, script: String) throws {
        let directory = root.appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(executable)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func assertRefusal(_ error: Error, kit: BarcodeKitDefinition, stage: String) throws {
        guard let refusal = error as? DemultiplexError, case .kitSequencesUnderCheck(let kitName) = refusal else {
            return XCTFail("\(stage) threw \(error) and not kitSequencesUnderCheck")
        }
        XCTAssertEqual(kitName, kit.displayName, "\(stage) names the kit")
        let words = refusal.errorDescription ?? ""
        XCTAssertTrue(words.contains("IDT for Illumina UD Indexes (96 pairs)"), "\(stage) names the kit in its words, got: \(words)")
        XCTAssertTrue(words.contains("Custom Definition"), "\(stage) gives the way out, got: \(words)")
    }

    func testTheCLIKitIdIsRefusedWithWordsBeforeCutadaptStartsAndBeforeAnythingIsWritten() async throws {
        let kitID = "idt-ud-indexes"
        // The CLI lists every built-in id in --kit and resolves the argument with BarcodeKitRegistry.kit(byID:).
        XCTAssertTrue(BarcodeKitRegistry.builtinKits().map(\.id).contains(kitID), "--kit offers the id")
        let kit = try XCTUnwrap(BarcodeKitRegistry.kit(byID: kitID), "--kit resolves the id to the kit")

        let runnerRoot = root.appendingPathComponent("managed-tools", isDirectory: true)
        let marker = root.appendingPathComponent("cutadapt-was-called")
        try makeManagedTool(root: runnerRoot, environment: "cutadapt", executable: "cutadapt", script: """
            #!/bin/sh
            : > '\(marker.path)'
            exit 9
            """)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = project.appendingPathComponent("reads.fastq")
        // Three reads that start with the first pair of the table (A01, i7 GAACATAC) and end with its i5 read back.
        let insert = "ACGTTGCAGGATCCATTGACCGTAGGCTAAGCTTGCATGCAAGTCCGGTTAACCGGT"
        let read = "GAACATAC" + insert + "CTACAGTT"
        try (1...3).map { "@r\($0)\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n" }.joined()
            .write(to: input, atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("demux-out", isDirectory: true)
        // The configuration FastqDemultiplexSubcommand builds from its defaults.
        let config = DemultiplexConfig(
            inputURL: input,
            barcodeKit: kit,
            outputDirectory: output,
            barcodeLocation: .bothEnds,
            errorRate: 0.15,
            minimumOverlap: 3,
            trimBarcodes: true,
            threads: 4
        )
        let pipeline = DemultiplexingPipeline(
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: runnerRoot, appIdentity: .preview)
        )

        do {
            try await pipeline.preflight(config: config)
            XCTFail("the preflight must refuse the kit")
        } catch {
            try assertRefusal(error, kit: kit, stage: "preflight")
        }
        do {
            _ = try await pipeline.run(config: config, progress: { _, _ in })
            XCTFail("the run must refuse the kit")
        } catch {
            try assertRefusal(error, kit: kit, stage: "run")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "cutadapt never started, so no read was assigned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the refusal came before the run made its output folder")
    }
}
