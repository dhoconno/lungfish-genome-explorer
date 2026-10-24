// HTCondorJobWrapperTests.swift - lge-job.sh run through ToolProcess on the Mac (CHTC program C4, lane H)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The wrapper is POSIX sh. These tests write it to a scratch folder and run it as `/bin/sh <file>`, the way HTCondor
// runs it in the container, with a stand-in executor that prints the arguments it was started with.

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class HTCondorJobWrapperTests: XCTestCase {
    private func run(_ arguments: [String], in scratch: URL, path: String) async throws -> ToolProcessResult {
        let wrapper = scratch.deletingLastPathComponent().appendingPathComponent(HTCondorJobWrapper.fileName)
        try HTCondorJobWrapper.text.write(to: wrapper, atomically: true, encoding: .utf8)
        return try await ToolProcess.run(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [wrapper.path] + arguments,
            environment: ["PATH": path],
            workingDirectory: scratch,
            timeout: .seconds(60)
        ))
    }

    func testJobWrapperExitsTwoOnBareImage() async throws {
        let root = try TestTempDirectory.make(prefix: "htcondor-wrapper-bare")
        defer { TestTempDirectory.cleanup(root) }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let bare = root.appendingPathComponent("bare-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try "not unpacked\n".write(to: scratch.appendingPathComponent("plan.tar"), atomically: true, encoding: .utf8)

        let result = try await run(["lungfish-executor-ab=bin/lungfish-executor", "--"], in: scratch, path: bare.path)

        XCTAssertEqual(result.status, 2, "a refusal, never 3, which is an interrupted run and would be retried")
        XCTAssertEqual(
            result.stderrText,
            "lge-job.sh: The container image has no dirname basename readlink on the PATH, which the executor's tools "
                + "need. The executor did not start.\n"
        )
        XCTAssertEqual(result.stdoutText, "")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: scratch.appendingPathComponent("plan.tar").path),
            "the wrapper stops before it touches the scratch folder"
        )
    }

    func testJobWrapperDropsUnsetSiteFacts() async throws {
        let root = try TestTempDirectory.make(prefix: "htcondor-wrapper-facts")
        defer { TestTempDirectory.cleanup(root) }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let plan = scratch.appendingPathComponent("plan", isDirectory: true)
        try FileManager.default.createDirectory(at: plan, withIntermediateDirectories: true)
        try "{}\n".write(to: plan.appendingPathComponent("plan.json"), atomically: true, encoding: .utf8)
        let tar = try await ToolProcess.run(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-cf", "plan.tar", "plan"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: scratch,
            timeout: .seconds(60)
        ))
        XCTAssertEqual(tar.status, 0, tar.stderrText)
        try FileManager.default.removeItem(at: plan)
        // A transferred file arrives with no execute bit, so the wrapper sets it.
        try "#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\"\n".write(
            to: scratch.appendingPathComponent("lungfish-executor-ab"), atomically: true, encoding: .utf8
        )
        try "index\n".write(to: scratch.appendingPathComponent("cd.idx"), atomically: true, encoding: .utf8)

        let result = try await run([
            "lungfish-executor-ab=bin/lungfish-executor", "cd.idx=databases/panhuman-1.k31w15.idx", "--",
            "--site-fact", "Machine=e4001.chtc.wisc.edu",
            "--site-fact", "Arch=lge_unset",
            "--site-fact", "Microarch=x86_64-v3",
            "--site-fact", "Disk=lge_unset",
            "--site-fact", "ClusterId=601234",
            "--site-fact", "ProcId=0",
        ], in: scratch, path: "/usr/bin:/bin")

        XCTAssertEqual(result.status, 0, result.stderrText)
        let argv = result.stdoutText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(argv.count, 13, result.stdoutText)
        guard argv.count == 13 else { return }
        // The kernel decides how a script's interpreter sees its path: macOS passes the full path, Linux the exec'd one.
        XCTAssertTrue(
            argv[0] == "./bin/lungfish-executor" || argv[0].hasSuffix("/scratch/plan/bin/lungfish-executor"),
            "run from its plan path, not \(argv[0])"
        )
        XCTAssertEqual(argv[1...2], ["run", "--plan"])
        XCTAssertTrue(argv[3].hasPrefix("/") && argv[3].hasSuffix("/plan/plan.json"), argv[3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: argv[3]))
        XCTAssertEqual(Array(argv[4...]), [
            "--site-fact", "Machine=e4001.chtc.wisc.edu",
            "--site-fact", "Microarch=x86_64-v3",
            "--site-fact", "ClusterId=601234",
            "--site-fact", "ProcId=0",
            "",
        ])
        XCTAssertFalse(result.stdoutText.contains("lge_unset"), "an unset fact never reaches the executor")

        let index = scratch.appendingPathComponent("plan/databases/panhuman-1.k31w15.idx")
        XCTAssertEqual(try String(contentsOf: index, encoding: .utf8), "index\n", "the database sits at its plan path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("cd.idx").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("plan.tar").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scratch.appendingPathComponent("plan/bin/lungfish-executor").path))
    }

    func testJobWrapperPlacesFileWhoseNameStartsWithDash() async throws {
        let root = try TestTempDirectory.make(prefix: "htcondor-wrapper-dash")
        defer { TestTempDirectory.cleanup(root) }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let plan = scratch.appendingPathComponent("plan", isDirectory: true)
        try FileManager.default.createDirectory(at: plan, withIntermediateDirectories: true)
        try "{}\n".write(to: plan.appendingPathComponent("plan.json"), atomically: true, encoding: .utf8)
        let tar = try await ToolProcess.run(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-cf", "plan.tar", "plan"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: scratch,
            timeout: .seconds(60)
        ))
        XCTAssertEqual(tar.status, 0, tar.stderrText)
        try FileManager.default.removeItem(at: plan)
        try "#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\"\n".write(
            to: scratch.appendingPathComponent("lungfish-executor-ab"), atomically: true, encoding: .utf8
        )
        // A name the character rule allows, which mv would read as its -n option without the `--` before it.
        try "dash index\n".write(to: scratch.appendingPathComponent("-n.idx"), atomically: true, encoding: .utf8)

        let result = try await run(
            ["lungfish-executor-ab=bin/lungfish-executor", "-n.idx=databases/x.idx", "--"], in: scratch, path: "/usr/bin:/bin"
        )

        XCTAssertEqual(result.status, 0, result.stderrText)
        let index = scratch.appendingPathComponent("plan/databases/x.idx")
        XCTAssertEqual(try? String(contentsOf: index, encoding: .utf8), "dash index\n", "the file sits at its plan path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("-n.idx").path))
    }

    func testJobWrapperRefusesPlacementOutsideThePlanFolder() async throws {
        let root = try TestTempDirectory.make(prefix: "htcondor-wrapper-escape")
        defer { TestTempDirectory.cleanup(root) }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let plan = scratch.appendingPathComponent("plan", isDirectory: true)
        try FileManager.default.createDirectory(at: plan, withIntermediateDirectories: true)
        try "{}\n".write(to: plan.appendingPathComponent("plan.json"), atomically: true, encoding: .utf8)
        let tar = try await ToolProcess.run(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-cf", "plan.tar", "plan"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: scratch,
            timeout: .seconds(60)
        ))
        XCTAssertEqual(tar.status, 0, tar.stderrText)
        try "x\n".write(to: scratch.appendingPathComponent("exe"), atomically: true, encoding: .utf8)

        let result = try await run(["exe=../exe", "--"], in: scratch, path: "/usr/bin:/bin")

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stderrText, "lge-job.sh: The placement of exe leaves the plan folder. The executor did not start.\n")
    }
}
