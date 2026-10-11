// AdapterChildEnvironmentPinTests.swift - What CondaManager.runTool and NativeToolRunner give a child
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S2 (scope row B1). The two adapters that the classifiers use
// build a child environment by hand, and lane S2 fills the provenance change
// beside it. These pins hold the child environment, every name and value, for
// a fixed parent environment, so filling the change cannot move what a tool
// receives. They passed at the base of the lane, before any source change.

import XCTest
@testable import LungfishWorkflow
import LungfishCore

final class AdapterChildEnvironmentPinTests: XCTestCase {
    /// The parent environment of the native tool pins. Two names are not set
    /// by any adapter, and the PATH is one no adapter could invent.
    private static let nativeParent: [String: String?] = [
        "LGE_S2_PARENT": "set by the parent",
        "LGE_S2_SHARED": "set by the parent too",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/lge-s2/parent/bin",
    ]

    // MARK: - NativeToolRunner

    func testRunProcessGivesTheChildTheParentEnvironmentWithTheCallersVariablesOverIt() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        let tool = try fixture.installStandaloneTool()
        let dump = fixture.dumpURL("process")
        let callers = ["LGE_S2_SHARED": "set by the caller", "LGE_S2_CALLER": "set by the caller"]
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.runProcess(
            executableURL: tool, arguments: [dump.path], environment: callers, timeout: 30, toolName: "dumper"
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        EnvironmentDump.assertEqual(
            try EnvironmentDump.read(dump),
            ProcessInfo.processInfo.environment.merging(callers) { _, caller in caller }
        )
    }

    func testRunProcessWithoutAnEnvironmentGivesTheChildTheParentEnvironmentAlone() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        let tool = try fixture.installStandaloneTool()
        let dump = fixture.dumpURL("process")
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.runProcess(
            executableURL: tool, arguments: [dump.path], timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), ProcessInfo.processInfo.environment)
    }

    func testRunPutsAManagedToolsBinFolderBeforeTheParentsPath() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.seqkit)
        let dump = fixture.dumpURL("seqkit")
        let callers = ["LGE_S2_SHARED": "set by the caller", "LGE_S2_CALLER": "set by the caller"]
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.run(.seqkit, arguments: [dump.path], environment: callers, timeout: 30)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        var expected = ProcessInfo.processInfo.environment.merging(callers) { _, caller in caller }
        expected["PATH"] = "\(fixture.binDirectory(of: .seqkit).path):/usr/bin:/bin:/usr/sbin:/sbin:/lge-s2/parent/bin"
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), expected)
    }

    func testRunPutsAManagedToolsBinFolderBeforeAPathTheCallerGave() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.samtools)
        let dump = fixture.dumpURL("samtools")
        let callers = ["PATH": "/lge-s2/caller/bin:/usr/bin"]
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.run(.samtools, arguments: [dump.path], environment: callers, timeout: 30)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        var expected = ProcessInfo.processInfo.environment
        expected["PATH"] = "\(fixture.binDirectory(of: .samtools).path):/lge-s2/caller/bin:/usr/bin"
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), expected)
    }

    func testRunWithoutAnEnvironmentOnlyPutsTheManagedBinFolderBeforeThePath() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.seqkit)
        let dump = fixture.dumpURL("seqkit")
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.run(.seqkit, arguments: [dump.path], timeout: 30)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        var expected = ProcessInfo.processInfo.environment
        expected["PATH"] = "\(fixture.binDirectory(of: .seqkit).path):/usr/bin:/bin:/usr/sbin:/sbin:/lge-s2/parent/bin"
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), expected)
    }

    /// A BBTools script runs with the bundled JVM first on PATH, JAVA_HOME and
    /// BBMAP_JAVA of its own environment, and the caller's other variables.
    /// The caller's PATH is the PATH the folders go in front of, and the
    /// caller's JAVA_HOME and BBMAP_JAVA never reach the child.
    func testRunOfABBToolsScriptGivesTheChildItsJavaAndPathAndTheCallersOtherVariables() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.reformat)
        let dump = fixture.dumpURL("reformat")
        let callers = [
            "LGE_S2_CALLER": "set by the caller",
            "JAVA_HOME": "/lge-s2/caller/jvm",
            "BBMAP_JAVA": "/lge-s2/caller/jvm/bin/java",
            "PATH": "/lge-s2/caller/bin",
        ]
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.run(.reformat, arguments: [dump.path], environment: callers, timeout: 30)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let bbtools = fixture.environmentURL("bbtools").path
        var expected = ProcessInfo.processInfo.environment
        expected["LGE_S2_CALLER"] = "set by the caller"
        expected["JAVA_HOME"] = "\(bbtools)/lib/jvm"
        expected["BBMAP_JAVA"] = "\(bbtools)/lib/jvm/bin/java"
        expected["PATH"] = "\(bbtools)/lib/jvm/bin:\(bbtools)/bin:/lge-s2/caller/bin"
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), expected)
    }

    func testRunWithFileOutputGivesTheChildTheEnvironmentRunGives() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.pigz)
        let dump = fixture.dumpURL("pigz")
        let output = fixture.root.appendingPathComponent("out.gz")
        let callers = ["LGE_S2_SHARED": "set by the caller", "LGE_S2_CALLER": "set by the caller"]
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.runWithFileOutput(
            .pigz, arguments: [dump.path], outputFile: output, environment: callers, timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        var expected = ProcessInfo.processInfo.environment.merging(callers) { _, caller in caller }
        expected["PATH"] = "\(fixture.binDirectory(of: .pigz).path):/usr/bin:/bin:/usr/sbin:/sbin:/lge-s2/parent/bin"
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), expected)
    }

    func testRunPipelineGivesEachStageItsOwnToolsEnvironment() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.seqkit)
        try fixture.install(.samtools)
        let first = fixture.dumpURL("first")
        let second = fixture.dumpURL("second")
        let callers = ["LGE_S2_SHARED": "set by the caller", "LGE_S2_CALLER": "set by the caller"]
        let parent = ParentEnvironmentOverride(Self.nativeParent)
        defer { parent.restore() }

        let result = try await fixture.runner.runPipeline(
            [NativePipelineStage(.seqkit, arguments: [first.path]), NativePipelineStage(.samtools, arguments: [second.path])],
            environment: callers,
            timeout: 30
        )

        XCTAssertEqual(result.exitCodes, [0, 0], result.stderrByStage.joined(separator: "\n"))
        let inherited = ProcessInfo.processInfo.environment.merging(callers) { _, caller in caller }
        var firstExpected = inherited
        firstExpected["PATH"] = "\(fixture.binDirectory(of: .seqkit).path):/usr/bin:/bin:/usr/sbin:/sbin:/lge-s2/parent/bin"
        var secondExpected = inherited
        secondExpected["PATH"] = "\(fixture.binDirectory(of: .samtools).path):/usr/bin:/bin:/usr/sbin:/sbin:/lge-s2/parent/bin"
        EnvironmentDump.assertEqual(try EnvironmentDump.read(first), firstExpected)
        EnvironmentDump.assertEqual(try EnvironmentDump.read(second), secondExpected)
    }

    // MARK: - CondaManager.runTool

    /// The child of runTool inherits nothing from the caller's shell except
    /// TMPDIR, whatever the parent environment holds.
    func testRunToolGivesMicromambaOnlyTheHermeticVariablesAndTheParentsTmpdir() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let dump = fixture.dumpURL("tool")
        let scratch = try fixture.scratchDirectory()
        let parent = ParentEnvironmentOverride(Self.nativeParent.merging(["TMPDIR": scratch.path]) { _, new in new })
        defer { parent.restore() }

        let result = try await fixture.manager.runTool(
            name: "dumper", arguments: [dump.path], environment: "dumper-env", timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), [
            "MAMBA_ROOT_PREFIX": fixture.manager.rootPrefix.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": scratch.path,
        ])
    }

    func testRunToolSetsNoTmpdirWhenTheParentHasNone() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let dump = fixture.dumpURL("tool")
        let parent = ParentEnvironmentOverride(Self.nativeParent.merging(["TMPDIR": nil]) { _, new in new })
        defer { parent.restore() }

        let result = try await fixture.manager.runTool(
            name: "dumper", arguments: [dump.path], environment: "dumper-env", timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), [
            "MAMBA_ROOT_PREFIX": fixture.manager.rootPrefix.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ])
    }

    func testRunToolLaysTheCallersVariablesOverTheHermeticOnes() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let dump = fixture.dumpURL("tool")
        let scratch = try fixture.scratchDirectory()
        let callers = [
            "ESVIRITU_DB": "/lge-s2/databases/esviritu",
            "HOME": "/lge-s2/caller/home",
            "PATH": "/lge-s2/caller/bin",
        ]
        let parent = ParentEnvironmentOverride(Self.nativeParent.merging(["TMPDIR": scratch.path]) { _, new in new })
        defer { parent.restore() }

        let result = try await fixture.manager.runTool(
            name: "dumper", arguments: [dump.path], environment: "dumper-env",
            environmentVariables: callers, timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        EnvironmentDump.assertEqual(try EnvironmentDump.read(dump), [
            "MAMBA_ROOT_PREFIX": fixture.manager.rootPrefix.path,
            "PATH": "/lge-s2/caller/bin",
            "HOME": "/lge-s2/caller/home",
            "TMPDIR": scratch.path,
            "ESVIRITU_DB": "/lge-s2/databases/esviritu",
        ])
    }
}
