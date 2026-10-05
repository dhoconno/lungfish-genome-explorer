// FASTQBatchImporterCancellationTests.swift - A cancelled import leaves no bundle, staging folder or workspace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Synchronization
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// Review finding S4-S3: `lungfish-cli import fastq` now turns SIGTERM into a
/// cancel. The import must then stop and leave nothing half-built in the
/// project: no bundle, no hidden `.building-` folder and no workspace.
final class FASTQBatchImporterCancellationTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-cancel")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testACancelledBatchImportsNothing() async throws {
        let files = try writeRun("SRR9100001")
        let config = config()
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FASTQBatchImporter.runBatchImport(pairs: FASTQBatchImporter.detectPairs(from: files), config: config)
        }.value

        XCTAssertEqual(result.completed, 0)
        XCTAssertTrue(result.cancelled)
        try assertNothingLeft()
    }

    /// The cancel lands after the statistics step, just before the bundle
    /// would be published.
    func testACancelLateInTheSampleLeavesNoBundleStagingFolderOrWorkspace() async throws {
        let files = try writeRun("SRR9100002")
        let config = config()
        let result = await Task.detached {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: files),
                config: config,
                log: { event in
                    if case .stepComplete(_, let step, _) = event, step == "Compute statistics" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }.value

        XCTAssertEqual(result.completed, 0, "the cancelled sample is not published")
        try assertNothingLeft()
    }

    /// Re-review finding S6-4: a cancelled sample was reported as a failed
    /// sample with a CancellationError text.
    func testACancelledSampleIsReportedAsACancelNotAFailure() async throws {
        let files = try writeRun("SRR9100003")
        let config = config()
        let events = EventLog()
        let result = await Task.detached {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: files),
                config: config,
                log: { event in
                    events.append(event)
                    if case .stepComplete(_, let step, _) = event, step == "Compute statistics" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }.value

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.failed, 0, "a cancel is not a failure")
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(events.contains { if case .sampleFailed = $0 { true } else { false } }, "no sampleFailed line")
    }

    /// Re-review finding S6-3: a cancel that lands after the last sample was
    /// published does not make the batch a cancelled one.
    func testACancelAfterTheLastSampleIsPublishedLeavesTheBatchFinished() async throws {
        let files = try writeRun("SRR9100004")
        let config = config()
        let result = await Task.detached {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: files),
                config: config,
                log: { event in
                    if case .sampleComplete = event { withUnsafeCurrentTask { $0?.cancel() } }
                }
            )
        }.value

        XCTAssertEqual(result.completed, 1, "the sample was published")
        XCTAssertFalse(result.cancelled, "every sample was published, so the batch was not cancelled")
    }

    /// Re-review finding S7-B1, task cancelled first. The cancel reaches the
    /// storage tool, and the pipeline wraps the tool's error as
    /// `clumpifyFailed`. The sample is still a cancel, so a single-sample
    /// import exits 125 and not with a workflow error.
    func testACancelWhileTheStorageToolRunsIsACancelNotAFailure() async throws {
        let files = try writeRun("SRR9100005")
        let config = config(optimizeStorage: true, clumpingTool: .bbtools)
        let events = EventLog()
        let result = await Task.detached {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: files),
                config: config,
                log: { event in
                    events.append(event)
                    if case .stepStart(_, let step, _, _) = event, step == "Optimize storage + Compress" {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }.value

        assertCancelNotFailure(result, events)
        try assertNothingLeft()
    }

    /// Re-review finding S7-B1, step failed first. The window's process-tree
    /// stop can end a tool before the CLI's own cancel lands, so the step
    /// fails with the tool's error. Here the staging bundle vanishes as the
    /// statistics step ends, and the cancel lands before the result is
    /// classified.
    func testAStepThatFailsJustBeforeTheCancelLandsIsACancelNotAFailure() async throws {
        let files = try writeRun("SRR9100006")
        let config = config()
        let events = EventLog()
        let project = project!
        let result = await Task.detached {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: files),
                config: config,
                log: { event in
                    events.append(event)
                    if case .stepComplete(_, let step, _) = event, step == "Compute statistics" {
                        Self.removeStagingBundles(in: project)
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }.value

        assertCancelNotFailure(result, events)
        try assertNothingLeft()
    }

    /// The same failed step with no cancel stays a failed sample.
    func testAStepThatFailsWithoutACancelIsStillAFailure() async throws {
        let files = try writeRun("SRR9100007")
        let config = config()
        let project = project!
        let result = await Task.detached {
            await FASTQBatchImporter.runBatchImport(
                pairs: FASTQBatchImporter.detectPairs(from: files),
                config: config,
                log: { event in
                    if case .stepComplete(_, let step, _) = event, step == "Compute statistics" {
                        Self.removeStagingBundles(in: project)
                    }
                }
            )
        }.value

        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.failed, 1, "the vanished staging bundle fails the sample")
    }

    // MARK: - Helpers

    private final class EventLog: Sendable {
        private let events = Mutex<[ImportLogEvent]>([])
        func append(_ event: ImportLogEvent) { events.withLock { $0.append(event) } }
        func contains(where match: (ImportLogEvent) -> Bool) -> Bool {
            events.withLock { $0.contains(where: match) }
        }
    }

    private func assertNothingLeft(file: StaticString = #filePath, line: UInt = #line) throws {
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let importEntries = (try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []
        XCTAssertEqual(importEntries, [], "no bundle and no hidden .building- folder", file: file, line: line)
        let temp = project.appendingPathComponent(".tmp", isDirectory: true)
        let workspaces = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
            .filter { $0.hasPrefix("fastq-import-") }
        XCTAssertEqual(workspaces, [], "no import workspace", file: file, line: line)
    }

    private func config(
        optimizeStorage: Bool = false,
        clumpingTool: ClumpingTool? = nil
    ) -> FASTQBatchImporter.ImportConfig {
        FASTQBatchImporter.ImportConfig(
            projectDirectory: project,
            platform: .given(.illumina),
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: optimizeStorage,
            clumpingTool: clumpingTool,
            threads: 1
        )
    }

    /// Removes the hidden staging bundle, as a step whose tool was ended
    /// would leave the sample unable to finish.
    private static func removeStagingBundles(in project: URL) {
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []
        for name in names where name.contains(".building-") {
            try? FileManager.default.removeItem(at: imports.appendingPathComponent(name))
        }
    }

    /// One sample, ended by a cancel. `lungfish-cli import fastq` exits 125
    /// when `cancelled` is set, and the batch sends no `sampleFailed` line.
    private func assertCancelNotFailure(
        _ result: FASTQBatchImporter.ImportResult,
        _ events: EventLog,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(result.cancelled, "the import was cancelled", file: file, line: line)
        XCTAssertEqual(result.completed, 0, file: file, line: line)
        XCTAssertEqual(result.failed, 0, "a cancel is not a failure", file: file, line: line)
        XCTAssertTrue(result.errors.isEmpty, file: file, line: line)
        XCTAssertFalse(
            events.contains { if case .sampleFailed = $0 { true } else { false } },
            "no sampleFailed line", file: file, line: line
        )
    }

    private func writeRun(_ run: String) throws -> [URL] {
        let folder = root.appendingPathComponent("download-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try [("_1", "ACGTACGT"), ("_2", "TTGGCCAA")].map { suffix, bases in
            let url = folder.appendingPathComponent("\(run)\(suffix).fastq")
            let text = (1...4).map { "@\(run).\($0) \($0) length=8\n\(bases)\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
    }
}
