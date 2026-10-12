// NextflowProgressReaderTests.swift - The engine's progress reader on the stdout and trace of real runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane U10 M1, decisions W1 and W2. Lane S9 moved TaxTriage's reader here unchanged, and on
// a real Nextflow 26.04.6 that reader read nothing, because no line holds `process >` and no line says
// that a task ended, so the bar sat at 0.10 through the whole engine stage (lane Q15, run R1). The
// cases read Q15's real runs from Tests/Fixtures/taxtriage-realrun-26.04.6, the standard output from
// TaxTriage's own first line to the end and the whole trace.txt, of R1 (SRR12486983 and SRR12486989
// pooled, 46 tasks) and of R2b (SRR12486989 alone, 29 tasks).

import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow
import Synchronization
import XCTest

final class NextflowProgressReaderTests: XCTestCase {
    /// The 29 tasks of R2b in the order its standard output names them, as the reader words them (W1).
    private static let oneSampleTaskWords = [
        "Running SAMPLESHEET_CHECK (samplesheet.csv)",
        "Running DOWNLOAD_TAXDUMP",
        "Running GET_ASSEMBLIES",
        "Running PIGZ_COMPRESS (SRR12486989)",
        "Running COUNT_READS (SRR12486989)",
        "Running FASTP (SRR12486989)",
        "Running FASTQC (SRR12486989)",
        "Running KRAKEN2_KRAKEN2 (SRR12486989)",
        "Running KREPORT_TO_KRONATXT (SRR12486989)",
        "Running REMOVETAXIDSCLASSIFICATION (SRR12486989)",
        "Running KRONA_KTIMPORTTEXT (combined_krona_kreports)",
        "Running MERGEDSUBSPECIES (MergeTopSpeciesAllSamples)",
        "Running TOP_HITS (SRR12486989)",
        "Running MERGEDKRAKENREPORT (MergeKrakenReportsAllSamples)",
        "Running DOWNLOAD_ASSEMBLY (SRR12486989)",
        "Running FILTERKRAKEN",
        "Running COMBINE_MAPFILES (SRR12486989)",
        "Running MAP_TAXID_ASSEMBLY (SRR12486989)",
        "Running MINIMAP2_ALIGN (SRR12486989.SRR12486989.dwnld.references)",
        "Running SAMTOOLS_INDEX (SRR12486989)",
        "Running SAMTOOLS_HIST_COVERAGE (SRR12486989)",
        "Running SAMTOOLS_COVERAGE (SRR12486989)",
        "Running CUSTOM_DUMPSOFTWAREVERSIONS (1)",
        "Running ALIGNMENT_PER_SAMPLE (SRR12486989)",
        "Running COMBINE_SAMPLES_JSON (all_samples_combined)",
        "Running ORGANISM_MERGE_REPORT (all)",
        "Running SINGLE_REPORT (SRR12486989)",
        "Running MULTIQC",
        "Running CREATE_COMPARISON_REPORT (comparison_full_report)",
    ]

    // MARK: - Task lines (W1)

    func testEachTaskLineOfARealRunReadsRunningWithTheLastPartOfItsProcessAndItsTag() throws {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 29, sampleCount: 1, report: reports.record)

        for line in try RealRun.lines("R2b.stdout.txt") {
            reader.engineLine(line)
        }

        XCTAssertEqual(reports.messages, Self.oneSampleTaskWords, "one report per task line and none for the other lines")
        XCTAssertEqual(Set(reports.fractions), [0.10], "a task line says a task started, so it moves no bar")
    }

    /// Each of the pooled run's task lines reads once, and they name the very tasks its trace.txt holds.
    func testThePooledRunsTaskLinesNameTheTasksOfItsTrace() throws {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 29, sampleCount: 2, report: reports.record)

        for line in try RealRun.lines("R1.stdout.txt") {
            reader.engineLine(line)
        }

        XCTAssertEqual(reports.messages.count, 46)
        XCTAssertEqual(reports.messages.first, "Running DOWNLOAD_TAXDUMP")
        XCTAssertEqual(reports.messages.last, "Running CREATE_COMPARISON_REPORT (comparison_full_report)")
        // The trace's name column is the process path and the tag, so its last part with the tag
        // reads as the task line of the same task.
        let traceWords = try RealRun.traceNames("R1.trace.txt").map { name -> String in
            let path = name.prefix { $0 != " " }
            let tag = name.dropFirst(path.count)
            return "Running " + (path.split(separator: ":").last.map(String.init) ?? "") + tag
        }
        XCTAssertEqual(reports.messages.sorted(), traceWords.sorted())
    }

    func testOnlyASubmittedTaskReadsAsATaskLine() {
        let lines: [(line: String, words: String?)] = [
            // Nextflow 25.04's plain form of the same task line.
            ("[9d/b2ebdf] Submitted process > NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRAKEN2_KRAKEN2 (S1)", "Running KRAKEN2_KRAKEN2 (S1)"),
            ("  [PROCESS 2f/d9ea2f] NFCORE_TAXTRIAGE:TAXTRIAGE:MULTIQC  ", "Running MULTIQC"),
            ("[PROCESS ab/cd1234] WORKFLOW:TASK (a (nested) tag)", "Running TASK (a (nested) tag)"),
            // Lines a plain log never prints for a task, or prints for something else.
            ("[aa/000001] process > NFCORE_TAXTRIAGE:TAXTRIAGE:KRAKEN2_KRAKEN2 (S1) [100%] 1 of 1", nil),
            ("[aa/000002] NOTE: Process `NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN (S1)` terminated with an error exit status (137) -- Error is ignored", nil),
            ("ERROR ~ Error executing process > 'NFCORE_TAXTRIAGE:TAXTRIAGE:KRAKEN2_KRAKEN2 (S1)'", nil),
            ("N E X T F L O W  ~  version 25.04.6", nil),
            ("[PIPELINE] nf-core/taxtriage 1.0dev | profile=docker", nil),
            ("[SUCCESS] completed=46 failed=0 cached=0", nil),
            ("[PROCESS ab/cd1234]", nil),
        ]
        for (line, words) in lines {
            let reports = Reports()
            let reader = NextflowProgressReader(expectedTasksPerSample: nil, sampleCount: 1, report: reports.record)
            reader.engineLine(line)
            XCTAssertEqual(reports.messages, words.map { [$0] } ?? [], line)
        }
    }

    // MARK: - The bar (W2)

    /// One sample of 29 tasks, read row by row. The bar follows the completed rows and stops at 0.95
    /// of the engine's share, 0.86, so it stays below the finish's 0.90 until the engine has ended.
    func testTheBarFollowsTheCompletedRowsOfTheTraceAgainstTheTasksOfOneSample() throws {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 29, sampleCount: 1, report: reports.record)
        let lines = try RealRun.lines("R2b.stdout.txt")
        for line in lines {
            reader.engineLine(line)
        }

        for rows in 1...29 {
            reader.traceProgress(try RealRun.reading("R2b.trace.txt", rows: rows))
        }

        let readings = Array(reports.entries.dropFirst(29))
        let expected = (1...28).map { 0.10 + 0.80 * min(Double($0) / 29, 0.95) }
        XCTAssertEqual(readings.count, expected.count, "a reading that leaves the bar where it is reports nothing")
        for (reading, value) in zip(readings, expected) {
            XCTAssertEqual(reading.fraction, value, accuracy: 1e-9)
            XCTAssertEqual(reading.message, "Running CREATE_COMPARISON_REPORT (comparison_full_report)", "a reading shows the last task line")
        }
        XCTAssertEqual(reports.fractions.last ?? 0, 0.86, accuracy: 1e-9)
    }

    /// A pooled run counts against the tasks of one sample times its samples, so R1's 46 tasks of two
    /// samples end the engine's bar at 46 of 58, below its stop.
    func testAPooledRunCountsAgainstTheTasksOfEachSample() throws {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 29, sampleCount: 2, report: reports.record)
        reader.engineLine("[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP")

        reader.traceProgress(try RealRun.reading("R1.trace.txt", rows: 46))

        assertFractions(reports.fractions, [0.10, 0.10 + 0.80 * 46 / 58])
    }

    func testWithNoStatedCountTheRunCountsAgainstFifteenTasks() {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: nil, sampleCount: 3, report: reports.record)
        reader.engineLine("[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP")

        reader.traceProgress(NextflowTraceProgress(completedTasks: 1, lastCompletedName: nil))

        assertFractions(reports.fractions, [0.10, 0.10 + 0.80 / 15])
    }

    func testTheBarNeverMovesBack() {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 29, sampleCount: 1, report: reports.record)
        reader.engineLine("[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP")
        reader.traceProgress(NextflowTraceProgress(completedTasks: 10, lastCompletedName: nil))

        reader.traceProgress(NextflowTraceProgress(completedTasks: 4, lastCompletedName: nil))
        reader.traceProgress(NextflowTraceProgress(completedTasks: 10, lastCompletedName: nil))
        reader.engineLine("[PROCESS 06/2dcb09] NFCORE_TAXTRIAGE:TAXTRIAGE:INPUT_CHECK:SAMPLESHEET_CHECK (samplesheet.csv)")

        let atTen = 0.10 + 0.80 * 10 / 29
        XCTAssertEqual(reports.messages, ["Running DOWNLOAD_TAXDUMP", "Running DOWNLOAD_TAXDUMP", "Running SAMPLESHEET_CHECK (samplesheet.csv)"])
        // A later task line keeps the bar the trace reached.
        assertFractions(reports.fractions, [0.10, atTen, atTen])
    }

    /// A trace file an earlier run left in the output folder can be read before the engine writes its
    /// own, so a reading moves the bar only once the engine has started a task.
    func testAReadingBeforeTheFirstTaskLineMovesNothing() throws {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 29, sampleCount: 1, report: reports.record)

        reader.traceProgress(try RealRun.reading("R2b.trace.txt", rows: 29))
        reader.engineLine("[PROCESS c8/28d8c1] NFCORE_TAXTRIAGE:TAXTRIAGE:INPUT_CHECK:SAMPLESHEET_CHECK (samplesheet.csv)")
        reader.traceProgress(try RealRun.reading("R2b.trace.txt", rows: 1))

        assertFractions(reports.fractions, [0.10, 0.10 + 0.80 / 29])
    }

    /// The engine hands over task lines from its output task and readings from its poll at the same
    /// time, and the bar the receiver sees never moves back.
    func testLinesAndReadingsFromTwoTasksReportABarThatNeverMovesBack() async {
        let reports = Reports()
        let reader = NextflowProgressReader(expectedTasksPerSample: 200, sampleCount: 1, report: reports.record)
        reader.engineLine("[PROCESS 9d/b2ebdf] NFCORE_TAXTRIAGE:TAXTRIAGE:DOWNLOAD_TAXDUMP")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<2_000 {
                    reader.engineLine("[PROCESS aa/\(index)] WORKFLOW:TASK (S\(index))")
                }
            }
            group.addTask {
                for completed in 1...190 {
                    reader.traceProgress(NextflowTraceProgress(completedTasks: completed, lastCompletedName: nil))
                }
            }
        }

        let fractions = reports.fractions
        let drops = zip(fractions, fractions.dropFirst()).filter { $1 < $0 }
        XCTAssertEqual(drops.count, 0, "the bar moved back \(drops.count) times")
        XCTAssertEqual(fractions.last ?? 0, 0.10 + 0.80 * 190 / 200, accuracy: 1e-9)
    }

    /// Compares bar values one by one, with no crash when the counts differ.
    private func assertFractions(
        _ actual: [Double],
        _ expected: [Double],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (value, wanted) in zip(actual, expected) {
            XCTAssertEqual(value, wanted, accuracy: 1e-9, "\(actual)", file: file, line: line)
        }
    }
}

/// Q15's real runs in Tests/Fixtures/taxtriage-realrun-26.04.6.
private enum RealRun {
    static let folder = ProvenanceCompatCorpus.repositoryRoot
        .appendingPathComponent("Tests/Fixtures/taxtriage-realrun-26.04.6", isDirectory: true)

    static func lines(_ name: String) throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
    }

    /// The name column of each row of a trace file, in row order.
    static func traceNames(_ name: String) throws -> [String] {
        let rows = try lines(name).filter { !$0.isEmpty }
        let header = rows[0].components(separatedBy: "\t")
        let column = try XCTUnwrap(header.firstIndex(of: "name"))
        return rows.dropFirst().map { $0.components(separatedBy: "\t")[column] }
    }

    /// The reading of a trace file cut after its header and its first `rows` rows.
    static func reading(_ name: String, rows: Int) throws -> NextflowTraceProgress {
        let text = try lines(name).prefix(rows + 1).joined(separator: "\n") + "\n"
        return try XCTUnwrap(NextflowTraceProgress(traceText: text))
    }
}

/// Collects what a reader reports.
private final class Reports: Sendable {
    private let stored = Mutex<[(fraction: Double, message: String)]>([])

    var record: @Sendable (Double, String) -> Void {
        { fraction, message in self.stored.withLock { $0.append((fraction, message)) } }
    }

    var entries: [(fraction: Double, message: String)] { stored.withLock { $0 } }
    var fractions: [Double] { entries.map(\.fraction) }
    var messages: [String] { entries.map(\.message) }
}
