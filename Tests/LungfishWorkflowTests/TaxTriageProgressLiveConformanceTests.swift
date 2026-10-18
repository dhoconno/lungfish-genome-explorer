// TaxTriageProgressLiveConformanceTests.swift - The TaxTriage bar on a real Nextflow run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane U10 M1, decisions W1 and W2, and the U10 row of the QA ruling on owner direction O5.
// A stand-in prints its task lines and writes its trace rows in one burst, so no stand-in run shows
// what W2's bar rests on, that Nextflow adds rows to trace.txt while the engine runs. This class runs
// SRR12486989 of the Pathogen Detection demo through `TaxTriagePipeline` in this process, the
// pipeline the app's batch runner launches for each sample, on the managed Nextflow with the docker
// profile and the Kraken2 Viral database. It checks that the bar leaves 0.10 while the engine still
// runs, never moves back, and reaches the engine's stop, 0.86, by the engine's end.
//
// It runs its body only when the live switch is on (LUNGFISH_LIVE_NEXTFLOW_ROOT, or
// LUNGFISH_REQUIRE_TOOLS=1 with LUNGFISH_STORAGE_ROOT), this process resolves its managed tools from
// that root, Docker answers `docker info` and LUNGFISH_DEMO_ARCHIVE_DIR holds the demo's archive.
// It never starts Docker Desktop. The run downloads NCBI's taxonomy and reference files, takes about
// three minutes and is bounded at ten. Its name ends in LiveConformanceTests, so only the conformance
// tier selects it. NextflowProgressReaderTests on lane Q15's real lines and trace files and
// TaxTriageCLIRouteRowTests on captured transcripts stay the default and the fallback.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import Synchronization
import XCTest

final class TaxTriageProgressLiveConformanceTests: XCTestCase {
    func testTheBarMovesOnCompletedTasksWhileTheRealEngineRuns() async throws {
        let run = try LiveNextflowRun.begin()
        var engineWorkFolders: [URL] = []
        defer { XCTAssertEqual(run.teardown(engineWorkFolders: engineWorkFolders).problems, []) }
        try run.requireProcessRoot()
        let database = try await ToolAvailability.requireDatabase(
            { run.root.appendingPathComponent("databases/kraken2/kraken2-viral", isDirectory: true) },
            name: "Kraken2 Viral in \(run.root.path)"
        )
        let project = try await run.installPathogenDetection()
        let reads = project.appendingPathComponent("Imports/SRR12486989.lungfishfastq/SRR12486989.fastq.gz")
        // Q15's R2b settings, which the command line gave this sample.
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "SRR12486989", fastq1: reads, readLayout: .strictlyInterleaved)],
            outputDirectory: run.outputDirectory,
            kraken2DatabasePath: database,
            removeTaxids: "9606"
        )

        let reports = TimedReports()
        // The Stable identity keeps Nextflow's home at ~/.nextflow, where Q15's runs left the pipeline.
        let pipeline = TaxTriagePipeline(appIdentity: .stable)
        let runTask = Task { try await pipeline.run(config: config, progress: reports.record) }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(LiveNextflowRun.runTimeout))
            runTask.cancel()
        }
        let outcome = await runTask.result
        watchdog.cancel()
        engineWorkFolders = Self.engineWorkFolder(in: run.outputDirectory).map { [$0] } ?? []

        let entries = reports.entries
        let start = entries.first?.time ?? Date()
        print("[live-nextflow] TaxTriage progress, seconds from the first report, bar, words")
        for entry in entries {
            print(String(format: "[live-nextflow] %6.1f s  %.4f  ", entry.time.timeIntervalSince(start), entry.fraction) + entry.message)
        }
        let result = try outcome.get()
        XCTAssertEqual(result.exitCode, 0, "the real run ended cleanly")

        let engineStart = try XCTUnwrap(
            entries.firstIndex { $0.message.hasPrefix("Running ") },
            "no task line reached the bar, \(entries.map(\.message))"
        )
        let engineEnd = try XCTUnwrap(
            entries.firstIndex { $0.message == "Collecting output files..." },
            "the run never reached its finish"
        )
        XCTAssertLessThan(engineStart, engineEnd)
        let engine = Array(entries[engineStart..<engineEnd])

        // W1. Every report of the engine stage is a task line in its words.
        XCTAssertEqual(engine.map(\.message).filter { !$0.hasPrefix("Running ") }, [])
        XCTAssertTrue(engine.contains { $0.message == "Running KRAKEN2_KRAKEN2 (SRR12486989)" })

        // The bar never moves back, over the whole run (T9 of Phase 2.8).
        let drops = zip(entries, entries.dropFirst()).filter { $1.fraction < $0.fraction }
        XCTAssertEqual(drops.map { "\($0.fraction) to \($1.fraction)" }, [])

        // W2. The bar leaves 0.10 while the engine still runs. A reading of trace.txt repeats the task
        // line the row shows, so a report whose words differ from the one before is a task line, which
        // the engine prints only while it runs. One after the bar left 0.10 shows that rows reached
        // trace.txt during the run.
        let firstMove = try XCTUnwrap(
            engine.firstIndex { $0.fraction > 0.10 + 1e-9 },
            "the bar never left 0.10 in the engine stage"
        )
        let laterTaskLine = engine.indices.dropFirst(firstMove + 1).first { engine[$0].message != engine[$0 - 1].message }
        XCTAssertNotNil(laterTaskLine, "no task line came after the bar left 0.10, so no row reached trace.txt while the engine ran")
        print(String(
            format: "[live-nextflow] the bar left 0.10 at %.1f s, %.1f s before the engine's end",
            engine[firstMove].time.timeIntervalSince(start),
            entries[engineEnd].time.timeIntervalSince(engine[firstMove].time)
        ))

        // W2. By the engine's end the bar reaches its stop, 0.95 of the share from 0.10 to 0.90, once
        // the reading after the engine ended counts 28 or all 29 tasks of one sample.
        let rows = NextflowTraceProgress(traceFileAt: run.outputDirectory.appendingPathComponent("trace.txt"))?.completedTasks
        XCTAssertEqual(
            engine.last?.fraction ?? 0,
            0.86,
            accuracy: 1e-9,
            "trace.txt holds \(rows.map(String.init) ?? "no") completed rows"
        )
    }

    /// The engine's work folder, which the launch makes for itself, read from the `[WORKDIR]` line of the
    /// run's log, so the teardown removes the run's task containers too.
    private static func engineWorkFolder(in output: URL) -> URL? {
        guard let log = try? String(contentsOf: output.appendingPathComponent("nextflow.log"), encoding: .utf8),
              let line = log.split(separator: "\n").first(where: { $0.hasPrefix("[WORKDIR] ") }) else {
            return nil
        }
        return URL(fileURLWithPath: String(line.dropFirst("[WORKDIR] ".count)), isDirectory: true)
    }
}

/// Collects each report with the time it came.
private final class TimedReports: Sendable {
    struct Entry: Sendable {
        let time: Date
        let fraction: Double
        let message: String
    }

    private let stored = Mutex<[Entry]>([])

    var record: @Sendable (Double, String) -> Void {
        { fraction, message in
            self.stored.withLock { $0.append(Entry(time: Date(), fraction: fraction, message: message)) }
        }
    }

    var entries: [Entry] { stored.withLock { $0 } }
}
