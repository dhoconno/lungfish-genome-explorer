// ImportFastqE2ETests+TrimGaloreMixed.swift - A merging recipe stores through Trim Galore as through clumpify (CHTC lane C2-TRIMGALORE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Until 2026-10-22 `import fastq --clumping-tool trim-galore` refused a recipe that merges pairs, because Trim Galore
/// ran one paired or one single-end call and could not take the file of merged reads and pairs. The storage step now
/// splits that file by mate name, as the bbtools route does, so the same import succeeds with either tool. `wgs` is
/// the built-in recipe that merges and needs no database. `LUNGFISH_REQUIRE_TOOLS=1` turns a missing tool into a
/// failure, not a skip.
extension ImportFastqE2ETests {

    private struct MixedImport {
        let status: Int32
        let output: String
        let storedFASTQ: URL?
        let bundles: Int
    }

    /// Imports the synthetic pairs through `wgs` with `tool` as the storage tool.
    private func mixedStorageImport(tool: String, root: URL, apart: Int, overlapping: Int) throws -> MixedImport {
        guard let binary = CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        ) else {
            try ToolAvailability.skipOrFail(
                "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
            )
        }
        let input = root.appendingPathComponent("input-\(tool)", isDirectory: true)
        let project = root.appendingPathComponent("\(tool).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Imports"), withIntermediateDirectories: true
        )
        let r1 = input.appendingPathComponent("sample_R1.fastq")
        let r2 = input.appendingPathComponent("sample_R2.fastq")
        try MixedStorageFASTQ.writeReadPairs(r1: r1, r2: r2, apart: apart, overlapping: overlapping)
        for file in [r1, r2] {
            let gzip = Process()
            gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            gzip.arguments = ["-f", file.path]
            try gzip.run()
            gzip.waitUntilExit()
        }

        let outputURL = root.appendingPathComponent("cli-output-\(tool).txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "import", "fastq", input.path, "--project", project.path, "--platform", "illumina",
            "--recipe", "wgs", "--clumping-tool", tool, "--compression", "fast", "--threads", "2",
        ]
        process.standardOutput = handle
        process.standardError = handle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 600) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 10)
        }
        let bundles = try FileManager.default.contentsOfDirectory(
            at: project.appendingPathComponent("Imports"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "lungfishfastq" }
        let stored = try bundles.first.flatMap { bundle in
            try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".fastq.gz") }
        }
        return MixedImport(
            status: process.isRunning ? -1 : process.terminationStatus,
            output: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "",
            storedFASTQ: stored,
            bundles: bundles.count
        )
    }

    func testAMergingRecipeStoresThroughTrimGaloreAsThroughBBTools() async throws {
        _ = try await ToolAvailability.require("fastp", environment: "fastp")
        _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
        _ = try await ToolAvailability.require("trim_galore", environment: "trim_galore")
        let root = try TestTempDirectory.make(prefix: "trim-galore-mixed")
        addTeardownBlock { TestTempDirectory.cleanup(root) }

        let reference = try mixedStorageImport(tool: "bbtools", root: root, apart: 8, overlapping: 6)
        XCTAssertEqual(reference.status, 0, "the bbtools route is the reference: \(reference.output)")
        let referenceLayout = try MixedStorageFASTQ.layout(of: try XCTUnwrap(reference.storedFASTQ, reference.output))
        XCTAssertGreaterThan(referenceLayout.pairs, 0, "the recipe must leave pairs: \(reference.output)")
        XCTAssertGreaterThan(referenceLayout.unpaired, 0, "the recipe must merge some pairs: \(reference.output)")

        let trimGalore = try mixedStorageImport(tool: "trim-galore", root: root, apart: 8, overlapping: 6)

        XCTAssertEqual(trimGalore.status, 0, "Trim Galore stores what the recipe wrote: \(trimGalore.output)")
        XCTAssertFalse(trimGalore.output.contains("cannot store"), trimGalore.output)
        XCTAssertEqual(trimGalore.bundles, 1)
        let layout = try MixedStorageFASTQ.layout(of: try XCTUnwrap(trimGalore.storedFASTQ, trimGalore.output))
        XCTAssertEqual(layout.pairs, referenceLayout.pairs, "every pair stays with its mate")
        XCTAssertEqual(layout.unpaired, referenceLayout.unpaired, "every merged read is kept")
        XCTAssertTrue(layout.pairsBeforeUnpaired, "pairs are stored interleaved ahead of the merged reads")
        XCTAssertEqual(layout.names, referenceLayout.names, "the same reads are stored")
        XCTAssertEqual(
            try FASTQPairInterleaver.countRecords(in: try XCTUnwrap(trimGalore.storedFASTQ)),
            try FASTQPairInterleaver.countRecords(in: try XCTUnwrap(reference.storedFASTQ))
        )
    }
}
