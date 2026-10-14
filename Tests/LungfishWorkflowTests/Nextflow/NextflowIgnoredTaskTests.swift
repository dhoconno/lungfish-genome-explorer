// NextflowIgnoredTaskTests.swift - The tasks a finished Nextflow run ignored, read from its own trace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A30 M3, ARCH's ruling on M3 (commit 2). An ignored task is a FAILED row of the run's trace
// with no COMPLETED or CACHED row of that name after it. A retry leaves a FAILED row and then a COMPLETED one,
// so it is not ignored. The traces follow Nextflow's default fields, which nf-core/viralrecon 3.0.0 keeps
// (`nextflow.config:305-307`), and the reader finds its columns by name.

import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class NextflowIgnoredTaskTests: XCTestCase {
    private static let header = [
        "task_id", "hash", "native_id", "name", "status", "exit", "submit", "duration", "realtime",
        "%cpu", "peak_rss", "peak_vmem", "rchar", "wchar",
    ].joined(separator: "\t")
    private static let prefix = "NFCORE_VIRALRECON:VIRALRECON:"

    /// A trace of `rows`, one per finished attempt in the order Nextflow writes them.
    private static func trace(_ rows: [(name: String, status: String, exit: String)]) -> String {
        let lines = rows.enumerated().map { index, row in
            let id = index + 1
            return [
                "\(id)", "aa/\(String(format: "%06d", id))", "\(1000 + id)", row.name, row.status, row.exit,
                "2026-10-14 01:00:00.000", "1s", "1s", "100.0%", "1 MB", "1 MB", "1 KB", "1 KB",
            ].joined(separator: "\t")
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    func testARetriedTaskIsNotIgnored() {
        let text = Self.trace([
            (Self.prefix + "FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (S1)", "FAILED", "137"),
            (Self.prefix + "FASTQ_TRIM_FASTP_FASTQC:FASTP (S2)", "COMPLETED", "0"),
            (Self.prefix + "FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (S1)", "COMPLETED", "0"),
            (Self.prefix + "FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (S2)", "FAILED", "140"),
            (Self.prefix + "FASTQ_ALIGN_BOWTIE2:BOWTIE2_ALIGN (S2)", "CACHED", "0"),
            (Self.prefix + "MULTIQC", "COMPLETED", "0"),
            (Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (S3)", "FAILED", "1"),
        ])

        XCTAssertEqual(
            NextflowTraceTask.ignored(inTrace: text),
            [NextflowTraceTask(processPath: Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN", tag: "S3")],
            "a FAILED row with a later success of its name is a retry, and a FAILED row with none is ignored"
        )
    }

    func testAFailedRowWithNoLaterSuccessIsIgnored() {
        let text = Self.trace([
            (Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (S1)", "FAILED", "1"),
            (Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (S2)", "COMPLETED", "0"),
            (Self.prefix + "VARIANTS_IVAR:IVAR_VARIANTS (S3)", "COMPLETED", "0"),
            (Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN (S1)", "FAILED", "1"),
            (Self.prefix + "VARIANTS_IVAR:IVAR_VARIANTS (S3)", "FAILED", "1"),
            (Self.prefix + "CUSTOM_DUMPSOFTWAREVERSIONS", "FAILED", "2"),
        ])

        let ignored = NextflowTraceTask.ignored(inTrace: text)

        XCTAssertEqual(ignored, [
            NextflowTraceTask(processPath: Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN", tag: "S1"),
            NextflowTraceTask(processPath: Self.prefix + "VARIANTS_IVAR:IVAR_VARIANTS", tag: "S3"),
            NextflowTraceTask(processPath: Self.prefix + "CUSTOM_DUMPSOFTWAREVERSIONS", tag: ""),
        ], "each task once, in the order of its first FAILED row, a success before the failure included")
        XCTAssertEqual(ignored.map(\.label), ["PANGOLIN_RUN (S1)", "IVAR_VARIANTS (S3)", "CUSTOM_DUMPSOFTWAREVERSIONS"])
        XCTAssertEqual(
            NextflowTraceTask.succeeded(inTrace: text),
            [NextflowTraceTask(processPath: Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN", tag: "S2"),
             NextflowTraceTask(processPath: Self.prefix + "VARIANTS_IVAR:IVAR_VARIANTS", tag: "S3")]
        )
    }

    func testTheColumnsAreFoundByNameAndATraceWithoutThemNamesNoTask() {
        let reordered = "status\tname\n" + "FAILED\t\(Self.prefix)MULTIQC\n"
        XCTAssertEqual(NextflowTraceTask.ignored(inTrace: reordered), [NextflowTraceTask(processPath: Self.prefix + "MULTIQC", tag: "")])
        XCTAssertEqual(NextflowTraceTask.ignored(inTrace: "task_id\thash\n1\taa/000001\n"), [])
        XCTAssertEqual(NextflowTraceTask.ignored(inTrace: ""), [])
    }

    /// UX's words in the ruling, the rule 1 and 3 form of section 5.
    func testOneWarningLineNamesEveryIgnoredTask() {
        let tasks = [
            NextflowTraceTask(processPath: Self.prefix + "CONSENSUS_BCFTOOLS:CONSENSUS_QC:PANGOLIN_RUN", tag: "S1"),
            NextflowTraceTask(processPath: Self.prefix + "CUSTOM_DUMPSOFTWAREVERSIONS", tag: ""),
        ]
        XCTAssertEqual(
            NextflowTraceTask.ignoredTasksLine(workflowName: "Viral Recon", tasks: tasks),
            "Some Viral Recon tasks failed: PANGOLIN_RUN (S1), CUSTOM_DUMPSOFTWAREVERSIONS. Their outputs are missing."
        )
        XCTAssertNil(NextflowTraceTask.ignoredTasksLine(workflowName: "Viral Recon", tasks: []))
    }

    /// nf-core writes `pipeline_info/execution_trace_<time>.txt` for each run, so a folder a run reuses holds the traces
    /// of earlier runs too. Only a trace written since the launch is this run's.
    func testTheNewestTraceWrittenSinceTheLaunchIsRead() throws {
        let folder = try TestTempDirectory.make(prefix: "nextflow-trace-task")
        defer { TestTempDirectory.cleanup(folder) }
        let launch = Date()
        let earlier = folder.appendingPathComponent("execution_trace_2026-10-13_10-00-00.txt")
        let current = folder.appendingPathComponent("execution_trace_2026-10-14_01-00-00.txt")
        let report = folder.appendingPathComponent("execution_report_2026-10-14_01-00-00.html")
        for url in [earlier, current, report] {
            try "trace".write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(-3600)], ofItemAtPath: earlier.path)
        try FileManager.default.setAttributes([.modificationDate: launch.addingTimeInterval(60)], ofItemAtPath: report.path)

        XCTAssertEqual(NextflowTraceTask.newestTrace(in: folder, writtenSince: launch)?.lastPathComponent, current.lastPathComponent)
        XCTAssertNil(NextflowTraceTask.newestTrace(in: folder, writtenSince: launch.addingTimeInterval(3600)), "an earlier run's trace is not this run's")
        XCTAssertNil(NextflowTraceTask.newestTrace(in: folder.appendingPathComponent("missing"), writtenSince: launch))
    }
}
