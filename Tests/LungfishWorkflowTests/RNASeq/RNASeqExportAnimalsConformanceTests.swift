// RNASeqExportAnimalsConformanceTests.swift - The animals rule of deseq2.R run by the real R (Phase 5.2 lane RS-SC-HANDOFF, slice A)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `RNASeqExportAnimalsTests` reads the text of the two scripts. This class runs the written `deseq2.R` with the R of the locked
// RNA-seq environment (`LGE_RNASEQ_ENV`, else /Volumes/lge_scratch/lge/rnaseq/env) on a 3 and 3 export whose `samples.tsv` is
// edited down to 2 animals in one level, or to a column with no animal. The script has to stop at once with exit 1 and the
// words of the Swift refusal, before DESeq2 fits anything. A missing tool is a skip, and a failure with LUNGFISH_REQUIRE_TOOLS=1.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

private final class RunningProcess: @unchecked Sendable {
    let process = Process()
}

final class RNASeqExportAnimalsConformanceTests: RNASeqExportTestCase {
    private var environment: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LGE_RNASEQ_ENV"] ?? "/Volumes/lge_scratch/lge/rnaseq/env", isDirectory: true)
    }

    /// Exports a 3 and 3 pseudobulk result and returns the folder with its `samples.tsv` edited by `edit`.
    private func editedExport(_ edit: ([String]) -> [String]) throws -> URL {
        let result = try animalsResult("pb", animalColumns([("B", ["A1", "A2", "A3"]), ("T", ["A1", "A2", "A3"])]))
        let out = root.appendingPathComponent("out", isDirectory: true)
        try RNASeqExport.run(
            results: [result], sheet: nil,
            settings: RNASeqExportSettings(design: ["group"], contrasts: [.init(factor: "group", numerator: "T", denominator: "B")]),
            output: out, argv: ["lungfish-cli", "rnaseq", "export"])
        let samples = out.appendingPathComponent("samples.tsv")
        let lines = try String(contentsOf: samples, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        try (edit(lines).joined(separator: "\n") + "\n").write(to: samples, atomically: true, encoding: .utf8)
        return out
    }

    /// Runs `Rscript --vanilla deseq2.R` in the folder and returns the exit status and what it wrote.
    private func runDeseq2(in folder: URL) throws -> (status: Int32, output: String) {
        let rscript = environment.appendingPathComponent("bin/Rscript")
        guard FileManager.default.isExecutableFile(atPath: rscript.path) else {
            try ToolAvailability.skipOrFail("No Rscript at \(rscript.path). Set LGE_RNASEQ_ENV to the RNA-seq environment.")
        }
        let log = root.appendingPathComponent("rscript.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let running = RunningProcess()
        running.process.executableURL = rscript
        running.process.arguments = ["--vanilla", "deseq2.R"]
        running.process.currentDirectoryURL = folder
        running.process.standardOutput = handle
        running.process.standardError = handle
        var variables = ProcessInfo.processInfo.environment
        variables["PATH"] = environment.appendingPathComponent("bin").path + ":" + (variables["PATH"] ?? "/usr/bin:/bin")
        running.process.environment = variables
        try running.process.run()
        // The script stops before the fit. A hung R is ended after the lookup budget, and the exit status then fails the test.
        let watchdog = DispatchWorkItem { running.process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(WaitBudget.lookup.duration.components.seconds)), execute: watchdog)
        running.process.waitUntilExit()
        watchdog.cancel()
        return (running.process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }

    func testDeseq2StopsWithTheWordsWhenALevelHoldsTwoAnimals() throws {
        // A3_B takes the animal A1, so the level B holds columns of 2 animals.
        let out = try editedExport { $0.map { $0.hasPrefix("A3_B\t") ? $0.replacingOccurrences(of: "\tA3\t", with: "\tA1\t") : $0 } }
        let run = try runDeseq2(in: out)
        XCTAssertEqual(run.status, 1, run.output)
        XCTAssertTrue(run.output.contains("A pseudobulk comparison needs columns of at least 3 animals in each level of group, "
            + "because tests on single cells give false discoveries, so LGE counts animals and not cells. "
            + "Here the level B holds columns of 2 animals (A1, A2). "
            + "Add animals so that each level holds 3 or more, or compare levels that already do."), run.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("deseq2-results").path), "no fit ran")
    }

    func testDeseq2StopsWithTheWordsWhenAColumnHoldsNoAnimal() throws {
        let out = try editedExport { $0.map { $0.hasPrefix("A3_B\t") ? $0.replacingOccurrences(of: "\tA3\t", with: "\t\t") : $0 } }
        let run = try runDeseq2(in: out)
        XCTAssertEqual(run.status, 1, run.output)
        XCTAssertTrue(run.output.contains("The pseudobulk column A3_B holds no animal. LGE counts animals and not cells in a pseudobulk comparison, "
            + "because tests on single cells give false discoveries, so each column needs its animal. "
            + "Give the animal of each column in the animal column of samples.tsv."), run.output)
    }
}
