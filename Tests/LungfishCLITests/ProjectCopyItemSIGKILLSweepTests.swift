// ProjectCopyItemSIGKILLSweepTests.swift - The stage a SIGKILLed copy leaves goes to the Trash at the next cleanup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.36 (row COPY-CANCEL-CHECKS, SWIFT ruling on where the sweep lives, reading B). The app's
// Cancel gives `project copy-item` six seconds and then sends SIGKILL, which runs no `defer`, so the copier's stage
// stays in the target project's `.tmp` folder. `ProjectTempDirectory.create` marks the stage with the creator's
// process identity, and the storage scanner calls an active stage whose creator is dead conclusively orphaned. So
// the app's `ProjectStorageAutomaticCleanupService` moves that stage to the Trash the next time it cleans the
// project, and it skips the stage of a copy that still runs. Both tests run the real leaf on the fixture of
// `ProjectCopyItemSIGTERMTests` and stop it while its native copy hashes. They run the service with its Trash
// pointed at a folder of the test, so no test writes the user's Trash.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ProjectCopyItemSIGKILLSweepTests: XCTestCase {
    private static let relativePath = "Reference Sequences/Big.lungfishref"
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "project-copy-item-sigkill")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testASIGKILLedCopyLeavesAStageTheCleanupServiceMovesToTrash() async throws {
        let target = try makeProjects()
        let run = try launchCopy(into: target)
        defer { run.stop() }
        let temp = target.appendingPathComponent(".tmp", isDirectory: true)
        let stage = try await stageWhileTheNativeCopyRuns(in: temp)

        let pid = run.processIdentifier
        XCTAssertEqual(kill(pid, SIGKILL), 0, "the SIGKILL was sent")
        await recordWhatTheScannerSeesOfAnUnreapedLeaf(run)
        let reaped = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            kill(pid, 0) != 0 && errno == ESRCH
        }
        XCTAssertTrue(reaped, "the killed leaf has exited and been reaped")

        // What the SIGKILL left. One stage and no published item.
        XCTAssertEqual(stages(in: temp), [stage.lastPathComponent], "the SIGKILL leaves the stage")
        XCTAssertFalse(isPublished(in: target), "a killed copy publishes no item")
        let payload = try payloadNames(in: stage)
        XCTAssertFalse(payload.isEmpty, "the stage holds the native copy's work")

        // The scanner calls the stage of a dead creator conclusively orphaned.
        let entry = try XCTUnwrap(
            try ProjectStorageScanner().scan(projectURL: target).entries.first {
                $0.relativePath == ".tmp/\(stage.lastPathComponent)"
            },
            "the scan lists the stage"
        )
        XCTAssertEqual(entry.category, .temporary)
        XCTAssertTrue(entry.classification.isRemovable, entry.classification.reason)
        XCTAssertEqual(entry.classification.code, .conclusivelyOrphanedOwnedWork, entry.classification.reason)

        // The periodic cleanup moves it to the Trash.
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let result = await Self.service(trashingInto: trash).run(projectURL: target)
        XCTAssertEqual(result.state, .completed, "\(result.warnings)")
        XCTAssertEqual(result.selectedEntryCount, 1)
        XCTAssertEqual(result.warnings, [])

        XCTAssertEqual(stages(in: temp), [], "no stage is left in the project")
        let trashed = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        XCTAssertEqual(trashed.count, 1, "the stage is in the test's Trash")
        XCTAssertEqual(try trashed.first.map(payloadNames(in:)), payload, "the Trash holds what the stage held")
        XCTAssertFalse(isPublished(in: target), "the cleanup publishes nothing")
    }

    func testALiveCopysStageIsNotSwept() async throws {
        let target = try makeProjects()
        let run = try launchCopy(into: target)
        defer { run.stop() }
        let temp = target.appendingPathComponent(".tmp", isDirectory: true)
        let stage = try await stageWhileTheNativeCopyRuns(in: temp)

        let pid = run.processIdentifier
        XCTAssertEqual(kill(pid, SIGSTOP), 0, "the copy is frozen, alive")
        var continued = false
        defer { if !continued { kill(pid, SIGCONT) } }

        let entry = try XCTUnwrap(
            try ProjectStorageScanner().scan(projectURL: target).entries.first {
                $0.relativePath == ".tmp/\(stage.lastPathComponent)"
            },
            "the scan lists the stage"
        )
        XCTAssertEqual(entry.category, .temporary)
        XCTAssertFalse(entry.classification.isRemovable, entry.classification.reason)
        XCTAssertEqual(entry.classification.code, .liveProcess, entry.classification.reason)

        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let result = await Self.service(trashingInto: trash).run(projectURL: target)
        XCTAssertEqual(result.state, .noEligibleEntries, "\(result.warnings)")
        XCTAssertEqual(result.selectedEntryCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path), "the live copy keeps its stage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path), "nothing went to the Trash")

        continued = true
        XCTAssertEqual(kill(pid, SIGCONT), 0)
        let stop = await CLISIGTERMHarness.cancel(run)
        XCTAssertEqual(stop.exitStatus, 125, "the copy then takes its cancel.\(stop.diagnostics)")
        XCTAssertEqual(stop.left, [], "no process of the copy is left")
        XCTAssertEqual(stages(in: temp), [], "the cancelled copy removes its own stage")
        XCTAssertFalse(isPublished(in: target), "a cancelled copy publishes no item")
    }

    // MARK: - The leaf

    /// A source project whose reference bundle holds a small FASTA and a sparse file of 512 MiB, and an empty target
    /// project, as `ProjectCopyItemSIGTERMTests` makes them. Returns the target.
    private func makeProjects() throws -> URL {
        let source = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        let target = root.appendingPathComponent("Target.lungfish", isDirectory: true)
        let item = source.appendingPathComponent(Self.relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try ">big\nACGT\n".write(to: item.appendingPathComponent("sequence.fasta"), atomically: true, encoding: .utf8)
        let sparse = item.appendingPathComponent("padding.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 512 << 20)
        try handle.close()
        return target
    }

    private func launchCopy(into target: URL) throws -> CLISIGTERMHarness.Run {
        let source = root.appendingPathComponent("Source.lungfish", isDirectory: true)
        return try CLISIGTERMHarness.launchCLI(
            [
                "project", "copy-item", Self.relativePath,
                "--source-project", source.path, "--project", target.path, "--format", "json",
            ],
            workingDirectory: root,
            testClass: Self.self
        )
    }

    /// Waits up to 30 seconds, polling every 10 milliseconds, for a `project-copy-` stage that holds both its
    /// owned-work marker and the native copy's `.native-copy-` folder. Waiting for the folder alone would race the
    /// marker write, which follows the folder's creation.
    private func stageWhileTheNativeCopyRuns(in temp: URL) async throws -> URL {
        var found: URL?
        let reached = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            found = self.stages(in: temp).map { temp.appendingPathComponent($0, isDirectory: true) }.first { stage in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: stage.path)) ?? []
                return names.contains(OwnedWorkDirectoryMarker.fileName)
                    && names.contains { $0.hasPrefix(".native-copy-") }
            }
            return found != nil
        }
        XCTAssertTrue(reached, "the leaf never reached its native copy")
        return try XCTUnwrap(found)
    }

    /// Q-13.36-2 of the SWIFT ruling. When the killed leaf is a zombie its parent has not reaped yet, prints what
    /// `OwnedProcessIdentity.inspect` answers for it. ToolProcess reaps the leaf on its own schedule, so a run may see
    /// no zombie at all, and the line says so.
    private func recordWhatTheScannerSeesOfAnUnreapedLeaf(_ run: CLISIGTERMHarness.Run) async {
        let pid = run.processIdentifier
        _ = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(1)) { !run.isRunning }
        let unreaped = kill(pid, 0) == 0
        let answer: String
        do {
            answer = try OwnedProcessIdentity.inspect(processIdentifier: pid).map { "identity \($0)" } ?? "nil (ESRCH)"
        } catch {
            answer = "error \(error)"
        }
        print("ProjectCopyItemSIGKILLSweepTests Q-13.36-2: unreaped zombie seen \(unreaped), inspect answered \(answer)")
    }

    // MARK: - The cleanup

    /// The app's periodic cleanup, unchanged but for its Trash, which is `trash` under the test's root.
    private static func service(trashingInto trash: URL) -> ProjectStorageAutomaticCleanupService {
        ProjectStorageAutomaticCleanupService(operations: .init(executeSelected: { invocation in
            _ = try ProjectStorageCleanupReceiptWriter().prepareConfirmedCleanup(
                .init(
                    cleanupID: invocation.cleanupID,
                    projectURL: invocation.projectURL,
                    projectIdentity: invocation.projectIdentity,
                    selectedEntries: invocation.selectedEntries,
                    workflowName: invocation.workflowName,
                    workflowVersion: invocation.workflowVersion,
                    toolName: invocation.toolName,
                    toolVersion: invocation.toolVersion,
                    argv: invocation.argv,
                    durableReplayArgv: invocation.durableReplayArgv,
                    options: invocation.options,
                    runtimeIdentity: invocation.runtimeIdentity,
                    startedAt: invocation.startedAt
                )
            )
            let executor = ProjectStorageCleanupExecutor(
                operations: .init(trashItem: { item in
                    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                    let destination = trash.appendingPathComponent(item.lastPathComponent, isDirectory: true)
                    try FileManager.default.moveItem(at: item, to: destination)
                    return destination
                }),
                usesProductionAssociatedLocks: true
            )
            return try await executor.execute(
                .init(
                    projectURL: invocation.projectURL,
                    cleanupID: invocation.cleanupID,
                    argv: invocation.argv,
                    durableReplayArgv: invocation.durableReplayArgv,
                    options: invocation.options,
                    runtimeIdentity: invocation.runtimeIdentity,
                    startedAt: invocation.startedAt
                )
            )
        }))
    }

    // MARK: - Reading the project

    private func stages(in temp: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("project-copy-") }
    }

    private func isPublished(in target: URL) -> Bool {
        FileManager.default.fileExists(atPath: target.appendingPathComponent(Self.relativePath).path)
    }

    /// The names a stage holds besides its owned-work marker, sorted.
    private func payloadNames(in stage: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: stage.path)
            .filter { $0 != OwnedWorkDirectoryMarker.fileName }
            .sorted()
    }
}
