// NextflowContainerCleanupLiveConformanceTests.swift - A real TaxTriage cancel leaves no container of the run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S10, decision N5 and owner direction O5 (the QA ruling's S10 row). The stand-in classes,
// NextflowDockerContainerCleanupTests and TaxTriageContainerCleanupTests, carry the cleanup in every tier. This
// class checks what they cannot, that on a real cancel the real daemon reports the run's task containers with
// mounts the cleanup finds, and that they are gone. It runs only when the live switch is on
// (LUNGFISH_LIVE_NEXTFLOW_ROOT, or LUNGFISH_REQUIRE_TOOLS=1 with LUNGFISH_STORAGE_ROOT), Docker answers
// `docker info`, the root holds Nextflow and the Kraken2 Viral database, this process uses that root, and
// LUNGFISH_DEMO_ARCHIVE_DIR holds the Pathogen Detection demo. It never starts Docker Desktop.
//
// The run is TaxTriage in this process, the route of the Tools menu, with the docker profile on SRR12486989
// copied out of the archive. Once the first task container of the run runs, the test cancels the task. No
// container of the run may run when the run returns or 10 s after the cancel, and none may be left in
// `docker ps -a`, each found by the run's work folder in its mounts. The teardown removes any container of the
// run still there, and no other.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import Synchronization
import XCTest

final class NextflowContainerCleanupLiveConformanceTests: XCTestCase {
    func testACancelAtTheFirstTaskLeavesNoContainerOfTheRun() async throws {
        let run = try LiveNextflowRun.begin()
        var engineWork: [URL] = []
        defer { XCTAssertEqual(run.teardown(engineWorkFolders: engineWork).problems, []) }
        try run.requireProcessRoot()
        let database = try await ToolAvailability.requireDatabase(
            {
                let folder = run.root.appendingPathComponent("databases/kraken2/kraken2-viral", isDirectory: true)
                return FileManager.default.fileExists(atPath: folder.appendingPathComponent("hash.k2d").path) ? folder : nil
            },
            name: "Kraken2 Viral in \(run.root.path)"
        )
        let project = try await run.installPathogenDetection()
        let reads = project.appendingPathComponent("Imports/SRR12486989.lungfishfastq/SRR12486989.fastq.gz")
        guard FileManager.default.fileExists(atPath: reads.path) else {
            throw LiveNextflowError.misconfigured("The Pathogen Detection demo holds no \(reads.path).")
        }
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "SRR12486989", fastq1: reads)],
            outputDirectory: run.outputDirectory,
            kraken2DatabasePath: database,
            profile: "docker"
        )
        let pipeline = TaxTriagePipeline(appIdentity: .stable)
        let ended = RunEnded()

        let task = Task {
            defer { ended.mark() }
            return try await pipeline.run(config: config)
        }
        let work: URL
        let runningAtTheCancel: [LiveNextflowDocker.Container]
        do {
            work = try await Self.engineWorkFolder(in: run.outputDirectory, until: ended)
            engineWork = [work]
            runningAtTheCancel = try await run.waitForOwnedContainers(engineWorkFolders: [work], timeout: 300)
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        print("[live-nextflow] cancel at epoch \(String(format: "%.3f", Date().timeIntervalSince1970)), work folder \(work.path)")
        task.cancel()
        let outcome = await task.result
        let returnedAfter = clock.now - cancelledAt
        let runningAtTheReturn = try run.ownedContainers(includingStopped: false, engineWorkFolders: [work])
        var runningLater = runningAtTheReturn
        let quiet = await waitUntil(timeout: .seconds(10) - returnedAfter, pollInterval: .milliseconds(500)) {
            runningLater = (try? run.ownedContainers(includingStopped: false, engineWorkFolders: [work])) ?? runningLater
            return runningLater.isEmpty
        }
        let quietAfter = clock.now - cancelledAt
        let left = try run.ownedContainers(includingStopped: true, engineWorkFolders: [work])
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)
        print("[live-nextflow] running at the cancel: \(runningAtTheCancel.map { String($0.id.prefix(12)) })")
        print("[live-nextflow] the run returned \(returnedAfter) after the cancel, with \(runningAtTheReturn.count) container(s) of the run running")
        print("[live-nextflow] no container of the run running \(quietAfter) after the cancel: \(quiet), left in docker ps -a: \(left.count)")

        guard case .failure(let error) = outcome, error is CancellationError else {
            return XCTFail("a cancelled run ends with a cancel, \(outcome)")
        }
        XCTAssertEqual(record?.status, .cancelled, "the record says cancelled")
        XCTAssertLessThan(returnedAfter, .seconds(10), "the 4 s grace, the 1.5 s cleanup and the record end inside 10 s")
        XCTAssertEqual(runningAtTheReturn.map(\.id), [], "N5, no container of the run runs once the run has returned")
        XCTAssertTrue(quiet, "no container of the run runs 10 s after the cancel, \(runningLater.map(\.id))")
        XCTAssertEqual(left.map(\.id), [], "no container of the run is left in docker ps -a")
    }

    // MARK: - Helpers

    /// The engine's work folder, from the `nextflow_work_directory` line TaxTriage writes into the output folder
    /// before its launch, waiting up to 10 minutes or until the run ends.
    private static func engineWorkFolder(in output: URL, until ended: RunEnded) async throws -> URL {
        let metadata = output.appendingPathComponent("taxtriage-launch-command.txt")
        let prefix = "nextflow_work_directory: "
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(LiveNextflowRun.runTimeout))
        while clock.now < deadline, !ended.isMarked {
            let text = (try? String(contentsOf: metadata, encoding: .utf8)) ?? ""
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }), line.count > prefix.count {
                return URL(fileURLWithPath: String(line.dropFirst(prefix.count)), isDirectory: true)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LiveNextflowError.misconfigured("TaxTriage wrote no work folder into \(metadata.path) before the run ended.")
    }
}

/// Whether the run's task has ended, set from the task itself.
private final class RunEnded: Sendable {
    private let marked = Mutex(false)

    func mark() {
        marked.withLock { $0 = true }
    }

    var isMarked: Bool { marked.withLock { $0 } }
}
