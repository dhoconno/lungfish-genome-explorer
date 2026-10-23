// RunPlanRecordPathTests.swift - The run record of run --plan holds no path of the machine that ran it (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension RunPlanFixture {
    /// The one-step copy plan: the tool copies the input by its work-root path, lists its environment's names and says
    /// so on stderr. Returns the fixture, the plan's path and the manifest's path.
    static func copyReads() throws -> (fixture: RunPlanFixture, plan: String, manifest: String) {
        var fixture = try RunPlanFixture()
        let copy = try fixture.addTool("copy-reads", "cat \"$1\" > \"$2\"\nenv | cut -d= -f1 | sort > out/env.txt\necho \"copied $1\" >&2")
        let manifest = try fixture.writeManifest()
        let plan = try fixture.writePlan(
            [RunPlanFixture.step("copy", copy, ["inputs/R1.fastq", "out/R1.fastq"], outputs: ["out/R1.fastq", "out/env.txt"])],
            manifestPin: manifest.pin
        )
        return (fixture, plan, manifest.path)
    }

    /// Starts `run --plan <planPath>` with `arguments` after it and returns the executor's PID without waiting, after
    /// removing an older record beside the plan.
    func start(_ planPath: String, _ arguments: [String]) throws -> pid_t {
        try? FileManager.default.removeItem(atPath: Self.recordPath(beside: planPath))
        let stdin = try ExecutorSpawn.openNullForReading()
        let stdout = try ExecutorSpawn.openForWriting(root + "/executor.out")
        let stderr = try ExecutorSpawn.openForWriting(root + "/executor.err")
        defer {
            close(stdin)
            close(stdout)
            close(stderr)
        }
        return try ExecutorSpawn.spawn(
            executable: binary, arguments: ["run", "--plan", planPath] + arguments,
            environment: ["PATH": "/usr/bin:/bin"], stdin: stdin, stdout: stdout, stderr: stderr
        )
    }

    /// Waits by the clock for the executor `start` began and reads the record it left beside `planPath`.
    func finish(_ pid: pid_t, planPath: String, timeout: Double = 60) throws -> Run {
        guard let exit = ExecutorTestSupport.waitForExit(pid, timeout: timeout) else {
            throw ExecutorTestSupport.Failure(description: "the executor did not end within \(Int(timeout)) s")
        }
        let path = Self.recordPath(beside: planPath)
        let record = FileManager.default.fileExists(atPath: path)
            ? try ExecutorRunRecord.decode(Data(contentsOf: URL(fileURLWithPath: path))) : nil
        return Run(exit: exit, record: record, stderr: ExecutorTestSupport.text(root + "/executor.err"))
    }

    static func recordPath(beside planPath: String) -> String {
        URL(fileURLWithPath: planPath).deletingLastPathComponent().path + "/" + ExecutorRunRecord.fileName
    }
}

/// A succeeded run and a pin-mismatch refusal of the copy plan, with the work root and the manifest each under a
/// folder whose name is a random marker.
private struct MarkedRuns {
    var fixture: RunPlanFixture
    var succeeded: ExecutorRunRecord
    var refused: ExecutorRunRecord
    var pin: PlanImageManifestPin
    var workMarker: String
    var manifestMarker: String
    var workRoot: String
    var manifestFolder: String
}

extension RunPlanTests {
    /// The copy plan moved under `<root>/<workMarker>/plan` and its manifest copied under `<root>/<manifestMarker>`, run
    /// with an absolute `--plan` and `--image-manifest` once to success and once against a wrong manifest pin.
    private func markedRuns() throws -> MarkedRuns {
        let (fixture, plan, manifest) = try RunPlanFixture.copyReads()
        let workMarker = "work-root-\(UUID().uuidString)"
        let manifestMarker = "manifest-folder-\(UUID().uuidString)"
        let workRoot = fixture.root + "/" + workMarker + "/plan"
        let manifestFolder = fixture.root + "/" + manifestMarker
        try FileManager.default.createDirectory(atPath: fixture.root + "/" + workMarker, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: manifestFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: fixture.planFolder, toPath: workRoot)
        try FileManager.default.copyItem(atPath: manifest, toPath: manifestFolder + "/image-manifest.json")
        let planPath = workRoot + "/" + URL(fileURLWithPath: plan).lastPathComponent
        let arguments = ["--image-manifest", manifestFolder + "/image-manifest.json"]
        let succeeded = try fixture.finish(try fixture.start(planPath, arguments), planPath: planPath)
        XCTAssertEqual(succeeded.status, ExecutorExitCode.succeeded, succeeded.stderr)

        var wrong = try ExecutionPlan.decode(Data(contentsOf: URL(fileURLWithPath: planPath)))
        let pin = wrong.imageManifest
        wrong.imageManifest = PlanImageManifestPin(sha256: RunPlanFixture.zeros, size: 5)
        try wrong.encoded().write(to: URL(fileURLWithPath: planPath))
        try FileManager.default.removeItem(atPath: workRoot + "/logs")
        let refused = try fixture.finish(try fixture.start(planPath, arguments), planPath: planPath)
        XCTAssertEqual(refused.status, ExecutorExitCode.refused, refused.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workRoot + "/logs"), "a pin mismatch makes no logs folder")
        return MarkedRuns(
            fixture: fixture, succeeded: try XCTUnwrap(succeeded.record), refused: try XCTUnwrap(refused.record), pin: pin,
            workMarker: workMarker, manifestMarker: manifestMarker, workRoot: workRoot, manifestFolder: manifestFolder
        )
    }

    /// The record's bytes with every step's stderr tail removed, since a tool may print any path.
    private func recordText(_ record: ExecutorRunRecord) throws -> String {
        var stripped = record
        stripped.steps = stripped.steps.map { step in
            var step = step
            step.stderrTail = ""
            return step
        }
        return String(decoding: try stripped.encoded(), as: UTF8.self)
    }

    /// SWIFT fix 1 of the K4 part A review (ruling N8): no field of the record holds the work root's path, after a
    /// succeeded run and after a refusal, and the plan is named by its file name.
    func testRunRecordHoldsNoWorkRootPath() throws {
        let runs = try markedRuns()
        XCTAssertEqual(runs.succeeded.outcome, .succeeded)
        XCTAssertEqual(runs.refused.refusedField, "imageManifest")
        for record in [runs.succeeded, runs.refused] {
            XCTAssertFalse(try recordText(record).contains(runs.workMarker), "\(record.outcome)")
            XCTAssertEqual(Array(record.executorArguments.prefix(3)), ["run", "--plan", "plan.json"], "\(record.outcome)")
            XCTAssertEqual(record.plan?.relativePath, "plan.json")
        }
    }

    /// SWIFT fix 1 of the K4 part A review (ruling Q-K4-1): the record states the manifest's digest, size and source and
    /// never the path the option named, after a succeeded run, a pin mismatch and a manifest over the cap.
    func testRunRecordStatesManifestSourceAndNoOptionPath() throws {
        let runs = try markedRuns()
        for record in [runs.succeeded, runs.refused] {
            XCTAssertFalse(try recordText(record).contains(runs.manifestMarker), "\(record.outcome)")
            XCTAssertEqual(Array(record.executorArguments.suffix(2)), ["--image-manifest", "(not recorded)"], "\(record.outcome)")
            XCTAssertEqual(record.imageManifest?.source, .argument)
            XCTAssertEqual(record.imageManifest?.sha256, runs.pin.sha256)
            XCTAssertEqual(record.imageManifest?.size, runs.pin.size)
        }
        let big = runs.manifestFolder + "/big-manifest.json"
        try Data(count: 2 << 20).write(to: URL(fileURLWithPath: big))
        let planPath = runs.workRoot + "/plan.json"
        let oversized = try runs.fixture.finish(try runs.fixture.start(planPath, ["--image-manifest", big]), planPath: planPath)
        XCTAssertEqual(oversized.status, ExecutorExitCode.refused, oversized.stderr)
        let record = try XCTUnwrap(oversized.record)
        XCTAssertEqual(record.refusedField, "imageManifest")
        XCTAssertEqual(record.steps, [])
        XCTAssertFalse(try recordText(record).contains(runs.manifestMarker))
    }
}
