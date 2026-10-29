// ReadExtractionTimeLimitTests.swift - A person's time limit reaches every launch of a by-ID extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import os
import LungfishCore
@testable import LungfishWorkflow

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. A by-ID extraction launches samtools to filter, count,
/// collate and split a BAM before it converts the records, and each launch reads the limit of the run. A stand-in
/// samtools answers every launch at once, so no test runs a tool for the length of a limit.
final class ReadExtractionTimeLimitTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadExtractionTimeLimit \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheLimitOfARunReachesEveryLaunchOfTheByIDExtraction() async throws {
        let runner = try makeRunner()
        let bam = root.appendingPathComponent("input.bam")
        try Data().write(to: bam)
        let config = ReadIDBAMExtractionConfig(
            bamURL: bam, readIDs: ["read1"], format: .fastq,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true), outputBaseName: "by-id"
        )

        let limits = await limitsOfLaunches {
            await AnalysisTimeLimit.withLimit(AnalysisTimeLimit(minutes: 5)) {
                _ = try? await ReadExtractionService(toolRunner: runner).extractByReadIDsFromBAM(config: config)
            }
        }

        XCTAssertGreaterThanOrEqual(limits.count, 5,
                                    "the extraction filters, counts, collates and splits the BAM, and its launches were \(limits)")
        XCTAssertTrue(limits.allSatisfy { $0 == .seconds(300) },
                      "every launch of a run under a 5 minute limit carries it, and the limits were \(limits)")
    }

    // MARK: - Helpers

    /// The wall-clock limit of each launch that `call` makes, in launch order, nil for none.
    private func limitsOfLaunches(_ call: () async -> Void) async -> [Duration?] {
        let limits = OSAllocatedUnfairLock<[Duration?]>(initialState: [])
        await CondaToolTimeLimit.$specProbe.withValue({ spec in
            limits.withLock { $0.append(spec.timeout) }
        }) { await call() }
        return limits.withLock { $0 }
    }

    /// A runner whose managed samtools answers every launch at once. `view -c` counts two records, and any other
    /// call creates the file that its `-o` names.
    private func makeRunner() throws -> NativeToolRunner {
        let fm = FileManager.default
        let binDirectory = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let tool = binDirectory.appendingPathComponent("samtools")
        let script = """
        #!/bin/sh
        out=""
        previous=""
        for argument in "$@"; do
          if [ "$argument" = "-c" ]; then echo 2; exit 0; fi
          if [ "$previous" = "-o" ]; then out="$argument"; fi
          previous="$argument"
        done
        if [ -n "$out" ]; then : > "$out"; fi
        exit 0
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .preview)
    }
}
