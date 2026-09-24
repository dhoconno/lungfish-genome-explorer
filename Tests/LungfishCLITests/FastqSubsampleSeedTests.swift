// FastqSubsampleSeedTests.swift - WFL-10 regression coverage for `fastq subsample --seed`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reported 2026-09-23 (best-practices audit, WFL-10): `fastq subsample` had
// no seed option in the dialog, the request, or the CLI, so the exact reads
// kept by a subsample run could never be reproduced from provenance. This
// drives the real `seqkit` binary (skipping when unavailable, per project
// convention) to prove that supplying `--seed` makes two runs produce
// byte-identical output.

import XCTest
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishCLI

final class FastqSubsampleSeedTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqSubsampleSeedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A fixed `--seed` must make two independent `fastq subsample` runs on
    /// the same input select the identical set of reads.
    func testSameSeedProducesIdenticalOutput() async throws {
        let inputURL = try makeFASTQFixture(readCount: 200)
        let output1 = tempDir.appendingPathComponent("out1.fastq")
        let output2 = tempDir.appendingPathComponent("out2.fastq")

        do {
            try await runSubsample(input: inputURL, proportion: 0.3, seed: 12345, output: output1)
            try await runSubsample(input: inputURL, proportion: 0.3, seed: 12345, output: output2)
        } catch let err as NativeToolError {
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                try ToolAvailability.skipOrFail("seqkit not installed in ~/.lungfish; \(err)")
            default:
                throw err
            }
        }

        let data1 = try Data(contentsOf: output1)
        let data2 = try Data(contentsOf: output2)
        XCTAssertEqual(data1, data2, "Two subsample runs with the same --seed must produce byte-identical output")
    }

    /// Different seeds should (with overwhelming probability, given 200
    /// input reads at a 30% keep rate) select a different set of reads --
    /// this guards against a seed that is accepted but silently ignored.
    func testDifferentSeedsProduceDifferentOutput() async throws {
        let inputURL = try makeFASTQFixture(readCount: 200)
        let output1 = tempDir.appendingPathComponent("out1.fastq")
        let output2 = tempDir.appendingPathComponent("out2.fastq")

        do {
            try await runSubsample(input: inputURL, proportion: 0.3, seed: 1, output: output1)
            try await runSubsample(input: inputURL, proportion: 0.3, seed: 2, output: output2)
        } catch let err as NativeToolError {
            switch err {
            case .toolNotFound, .toolsDirectoryNotFound:
                try ToolAvailability.skipOrFail("seqkit not installed in ~/.lungfish; \(err)")
            default:
                throw err
            }
        }

        let data1 = try Data(contentsOf: output1)
        let data2 = try Data(contentsOf: output2)
        XCTAssertNotEqual(data1, data2, "Different --seed values must select different reads")
    }

    // MARK: - Helpers

    private func runSubsample(input: URL, proportion: Double, seed: Int64, output: URL) async throws {
        let subcommand = try FastqSubsampleSubcommand.parse([
            input.path,
            "--proportion", String(proportion),
            "--seed", String(seed),
            "-o", output.path,
            "--force",
        ])
        try await subcommand.run()
    }

    private func makeFASTQFixture(readCount: Int) throws -> URL {
        let url = tempDir.appendingPathComponent("input.fastq")
        var content = ""
        for i in 0..<readCount {
            content += "@read\(i)\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
