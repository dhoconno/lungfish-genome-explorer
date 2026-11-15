// RNASeqExportAnimalsContrastsConformanceTests.swift - check_animals of the scripts run by the real R on the levels each contrast compares
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 5.2 fix FIX-SC-1 of lane RS-SC-HANDOFF. `RNASeqExportAnimalsTests` holds the Swift rule and is the default. This class runs the
// settings block, the read and the animals check of the two scripts, as the export writes them, with the R of the locked RNA-seq
// environment (`LGE_RNASEQ_ENV`, else /Volumes/lge_scratch/lge/rnaseq/env) on the tables of the Swift cases. R has to pass where
// Swift passes and stop with exit 1 and the words of the Swift refusal where Swift refuses. A missing tool is a skip, and a failure
// with LUNGFISH_REQUIRE_TOOLS=1.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class RNASeqExportAnimalsContrastsConformanceTests: RNASeqExportTestCase {
    private var rscript: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LGE_RNASEQ_ENV"] ?? "/Volumes/lge_scratch/lge/rnaseq/env", isDirectory: true)
            .appendingPathComponent("bin/Rscript")
    }

    /// The columns `<animal>_<group>`, with a day for each when `days` names it.
    private func table(_ columns: [(id: String, animal: String, group: String)], days: [String: String] = [:]) -> RNASeqExportSampleTable {
        RNASeqExportSampleTable(
            columns: ["sample_id", "animal", "group", "day"], rows: columns.map { [$0.id, $0.animal, $0.group, days[$0.id] ?? "D1"] })
    }

    private func contrast(_ factor: String, _ numerator: String, _ denominator: String) -> RNASeqExportSettings.Contrast {
        .init(factor: factor, numerator: numerator, denominator: denominator)
    }

    /// The words of the Swift refusal, or nil when the rule passes.
    private func swiftWords(_ samples: RNASeqExportSampleTable, _ settings: RNASeqExportSettings) -> String? {
        do {
            try RNASeqExportDesignCheck.checkAnimals(settings, samples: samples)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Writes the folder's three tables and a script of the settings block, the read and the animals check of `deseq2.R`, then runs it.
    private func runR(_ samples: RNASeqExportSampleTable, _ settings: RNASeqExportSettings, name: String) throws -> (status: Int32, output: String) {
        guard FileManager.default.isExecutableFile(atPath: rscript.path) else {
            try ToolAvailability.skipOrFail("No Rscript at \(rscript.path). Set LGE_RNASEQ_ENV to the RNA-seq environment.")
        }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ids = samples.rows.map { $0[0] }
        let files = [
            "samples.tsv": ([samples.columns] + samples.rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n",
            "counts.tsv": "gene_id\t" + ids.joined(separator: "\t") + "\nG1\t" + ids.map { _ in "1" }.joined(separator: "\t") + "\n",
            "genes.tsv": "gene_id\tnot_host\nG1\tfalse\n",
            "check.R": RNASeqExportTemplates.settingsBlock(settings, minimumAnimals: RNASeqExportDesignCheck.minimumAnimals) + "\n"
                + RNASeqExportTemplates.readBlock + "\n" + RNASeqExportTemplates.animalsCheck(RNASeqExportDesignCheck.minimumAnimals)
                + "cat(\"animals pass\\n\")\n",
        ]
        for (file, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(file)) }
        let log = folder.appendingPathComponent("rscript.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = rscript
        process.arguments = ["--vanilla", "check.R"]
        process.currentDirectoryURL = folder
        process.standardOutput = handle
        process.standardError = handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + WaitBudget.lookup.seconds) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + WaitBudget.standard.seconds)
        }
        return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
    }

    /// R and Swift agree: both pass, or both refuse in the same words.
    private func assertAgree(
        _ samples: RNASeqExportSampleTable, _ settings: RNASeqExportSettings, name: String, refused: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let words = swiftWords(samples, settings)
        XCTAssertEqual(words != nil, refused, "Swift: \(words ?? "passes")", file: file, line: line)
        let run = try runR(samples, settings, name: name)
        if let words {
            XCTAssertEqual(run.status, 1, run.output, file: file, line: line)
            XCTAssertTrue(run.output.contains(words), "R stops with the Swift words \(words):\n\(run.output)", file: file, line: line)
        } else {
            XCTAssertEqual(run.status, 0, run.output, file: file, line: line)
            XCTAssertTrue(run.output.contains("animals pass"), run.output, file: file, line: line)
        }
    }

    private func three(_ group: String) -> [(id: String, animal: String, group: String)] {
        ["A1", "A2", "A3"].map { ("\($0)_\(group)", $0, group) }
    }

    func testAThinLevelThatNoContrastNamesPassesInRAsInSwift() throws {
        let samples = table(three("B") + three("T") + [("A1_C", "A1", "C")])
        try assertAgree(samples, RNASeqExportSettings(design: ["group"], contrasts: [contrast("group", "T", "B")]), name: "thin-c", refused: false)
    }

    func testAContrastOnAFactorThatIsNotTheLastDesignTermIsRefusedInRAsInSwift() throws {
        let columns = [("A1_B", "A1", "B"), ("A1b_B", "A1", "B"), ("A2_B", "A2", "B"), ("A3_T", "A3", "T"), ("A4_T", "A4", "T"), ("A5_T", "A5", "T")]
        let days = ["A1_B": "D1", "A3_T": "D1", "A4_T": "D1", "A1b_B": "D2", "A2_B": "D2", "A5_T": "D2"]
        let settings = RNASeqExportSettings(design: ["group", "day"], contrasts: [contrast("group", "T", "B")])
        try assertAgree(table(columns.map { (id: $0.0, animal: $0.1, group: $0.2) }, days: days), settings, name: "group-not-last", refused: true)
    }

    func testANamedLevelNoColumnHoldsIsRefusedInRAsInSwift() throws {
        let settings = RNASeqExportSettings(design: ["group"], contrasts: [contrast("group", "T", "Z")])
        try assertAgree(table(three("B") + three("T")), settings, name: "level-z", refused: true)
    }

    func testThinLevelsAreNamedOnceInContrastOrderInRAsInSwift() throws {
        let samples = table(three("T") + [("A1_B", "A1", "B"), ("A2_C", "A2", "C"), ("A3_C", "A3", "C"), ("A1_D", "A1", "D"), ("A3_D", "A3", "D")])
        let settings = RNASeqExportSettings(
            design: ["group"], contrasts: [contrast("group", "D", "C"), contrast("group", "T", "B"), contrast("group", "C", "T")])
        try assertAgree(samples, settings, name: "order", refused: true)
    }
}
