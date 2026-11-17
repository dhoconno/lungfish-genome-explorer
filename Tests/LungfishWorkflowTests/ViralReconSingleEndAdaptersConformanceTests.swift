// ViralReconSingleEndAdaptersConformanceTests.swift - Single-end Viral Recon trims the same reads in any stored order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-THREE-ROWS, items 8-11 and section 3 (VIRALRECON-SE-ADAPTER-GUESS, S1). viralrecon hands its FASTP step no
// adapter (`workflows/viralrecon.nf:246-251`), so for a single-end sample fastp guesses one from the reads it sees
// first, and the order LGE stages the reads in picks the guess. The fixture is the first 20,000 reads of SRR14639650
// (Tests/Fixtures/viralrecon-se-adapters/README.md). The stand-in cases are in ViralReconFastpConfigTests.

import CryptoKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ViralReconSingleEndAdaptersConformanceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let folder = try TestTempDirectory.make(prefix: "viralrecon-se-adapters")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        root = folder
    }

    private var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/viralrecon-se-adapters/SRR14639650-20000.fastq.gz")
    }

    /// The fixture's reads in the order the Viral Recon staging writes single reads with `seed`
    /// (`ViralReconReadPairing+Bundles.swift:284`), which uses seed 1.
    private func stage(seed: UInt64) throws -> URL {
        let staged = root.appendingPathComponent("staged-seed\(seed).fastq")
        XCTAssertTrue(FileManager.default.createFile(atPath: staged.path, contents: nil))
        let handle = try FileHandle(forWritingTo: staged)
        defer { try? handle.close() }
        let reads = try SeededPairOrder.writeReads(
            [fixture], to: handle, scratch: root.appendingPathComponent("buckets-seed\(seed)", isDirectory: true), seed: seed
        )
        XCTAssertEqual(reads, 20_000, "seed \(seed) stages every read")
        return staged
    }

    /// The records of a FASTQ file, each as its four lines joined by newlines.
    private func records(_ url: URL) throws -> [[UInt8]] {
        let reader = try FASTQRawLineReader(url: url)
        defer { reader.close() }
        var lines: [[UInt8]] = []
        while let line = try reader.nextLine() { lines.append(Array(line)) }
        return stride(from: 0, to: lines.count - lines.count % 4, by: 4).map {
            Array(lines[$0..<$0 + 4].joined(separator: [0x0A]))
        }
    }

    /// fastp as viralrecon's FASTP module runs it for a single-end sample (`modules/nf-core/fastp/main.nf:58-71`), with
    /// `arguments` as its `ext.args`. Returns the first 16 hex digits of the SHA-256 of the sorted records it keeps, as
    /// the ruling's `measure.py` writes a digest, the count of those records and the read 1 adapter fastp's report names.
    private func trim(_ input: URL, seed: UInt64, arguments: [String]) async throws -> (digest: String, reads: Int, adapter: String) {
        let output = root.appendingPathComponent("trimmed-seed\(seed).fastq")
        let report = root.appendingPathComponent("trimmed-seed\(seed).json")
        let argv = [
            "--in1", input.path, "--out1", output.path, "--thread", "4",
            "--json", report.path, "--html", root.appendingPathComponent("trimmed-seed\(seed).html").path,
        ] + arguments
        let result: NativeToolResult
        do {
            result = try await NativeToolRunner.shared.run(.fastp, arguments: argv)
        } catch let error as NativeToolError {
            if case .toolNotFound = error {
                try ToolAvailability.skipOrFail("Managed fastp is not available")
            }
            throw error
        }
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let kept = try records(output).sorted { $0.lexicographicallyPrecedes($1) }
        let digest = SHA256.hash(data: Data(kept.joined())).map { String(format: "%02x", $0) }.joined().prefix(16)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
        let adapter = (json?["adapter_cutting"] as? [String: Any])?["read1_adapter_sequence"] as? String ?? "none"
        return (String(digest), kept.count, adapter)
    }

    func testSingleEndFastpGivesOneResultInEveryStagedOrder() async throws {
        let adapters = try FastpPairedRunner.SingleReadAdapters.bundled()
        let arguments = ViralReconFastpConfig.singleEndArguments(adapters: adapters)
        var runs: [(seed: UInt64, digest: String, reads: Int, adapter: String)] = []
        for seed: UInt64 in [1, 2, 3] {
            let staged = try stage(seed: seed)
            let run = try await trim(staged, seed: seed, arguments: arguments)
            runs.append((seed, run.digest, run.reads, run.adapter))
        }
        let summary = runs.map { "seed \($0.seed): \($0.reads) reads, digest \($0.digest), adapter \($0.adapter)" }
            .joined(separator: "; ")
        XCTAssertEqual(Set(runs.map(\.digest)).count, 1, "one sorted digest across LGE seeds 1, 2 and 3 (\(summary))")
        XCTAssertEqual(Set(runs.map(\.reads)).count, 1, "the same reads out in every order (\(summary))")
        for run in runs {
            XCTAssertEqual(run.adapter, adapters.adapterSequence, "fastp names TruSeq Read 1 and guesses none (\(summary))")
        }
    }
}
