// ToolProcessEnvironmentChangeAdapterTests+NativeTool.swift - The environment change of NativeToolRunner launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S2 (scope row B1, decisions P2 and P10). NativeToolRunner
// builds its child environment over the inherited one, so the change it
// records has an inherited base. Its PATH prefix is what the launch put before
// the inherited PATH, such as a managed tool's environment bin folder.

import XCTest
@testable import LungfishWorkflow
import LungfishCore

extension ToolProcessEnvironmentChangeAdapterTests {
    // MARK: - run

    func testRunRecordsTheManagedBinFolderAsTheOnlyPathPrefix() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.seqkit)
        let callers = ["LGE_S2_CALLER": "set by the caller", "JAVA_HOME": "/lge-s2/caller/jvm"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.run(.seqkit, arguments: [fixture.dumpURL("seqkit").path], environment: callers, timeout: 30)
        }

        let stage = try declaredStage(of: log, label: "seqkit")
        let change = try XCTUnwrap(stage.environmentChange)
        let context = await fixture.runner.environmentChangeContext
        XCTAssertEqual(change.base, .inherited)
        XCTAssertEqual(change.set.map(\.name), ["JAVA_HOME", "LGE_S2_CALLER", "PATH"])
        XCTAssertEqual(change.unset, [])
        XCTAssertEqual(change.pathPrefix, [PortablePath.sanitize(path: fixture.binDirectory(of: .seqkit).path, context: context)])
        let values = Dictionary(uniqueKeysWithValues: change.set.map { ($0.name, $0.value) })
        XCTAssertEqual(try XCTUnwrap(values["JAVA_HOME"]), "<external>/jvm", "JAVA_HOME is allowlisted and sanitized")
        XCTAssertNil(try XCTUnwrap(values["LGE_S2_CALLER"]), "A name off the allowlist keeps its name only")
        XCTAssertNil(try XCTUnwrap(values["PATH"]), "PATH never keeps a value")
        XCTAssertEqual(stage.identityHint, "seqkit")
        // The inherited environment is never part of the change.
        XCTAssertFalse(everyString(in: change).contains { $0.contains("/lge-s2/parent/bin") || $0.contains("LGE_S2_PARENT") })
    }

    func testRunOfABBToolsScriptRecordsItsJavaVariablesAndTwoPathEntries() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.reformat)
        let callers = [
            "LGE_S2_CALLER": "set by the caller",
            "JAVA_HOME": "/lge-s2/caller/jvm",
            "BBMAP_JAVA": "/lge-s2/caller/jvm/bin/java",
        ]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.run(.reformat, arguments: [fixture.dumpURL("reformat").path], environment: callers, timeout: 30)
        }

        let stage = try declaredStage(of: log, label: "reformat")
        let change = try XCTUnwrap(stage.environmentChange)
        let context = await fixture.runner.environmentChangeContext
        let bbtools = fixture.environmentURL("bbtools").path
        func sanitized(_ path: String) -> String { PortablePath.sanitize(path: path, context: context) }
        XCTAssertEqual(change.set, [
            .init(name: "BBMAP_JAVA", value: sanitized("\(bbtools)/lib/jvm/bin/java")),
            .init(name: "JAVA_HOME", value: sanitized("\(bbtools)/lib/jvm")),
            .init(name: "LGE_S2_CALLER", value: nil),
            .init(name: "PATH", value: nil),
        ])
        XCTAssertEqual(change.pathPrefix, [sanitized("\(bbtools)/lib/jvm/bin"), sanitized("\(bbtools)/bin")])
        XCTAssertEqual(stage.identityHint, "reformat")
    }

    // MARK: - runProcess

    func testRunProcessRecordsTheCallersVariablesAndNoPathPrefix() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        let tool = try fixture.installStandaloneTool()
        let callers = ["LGE_S2_CALLER": "set by the caller", "MAFFT_BINARIES": "/lge-s2/mafft"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.runProcess(
                executableURL: tool, arguments: [fixture.dumpURL("process").path], environment: callers,
                timeout: 30, toolName: "Primer3"
            )
        }

        let stage = try declaredStage(of: log, label: "Primer3")
        let change = try XCTUnwrap(stage.environmentChange)
        XCTAssertEqual(change.base, .inherited)
        XCTAssertEqual(change.set, [
            .init(name: "LGE_S2_CALLER", value: nil),
            .init(name: "MAFFT_BINARIES", value: "<external>/mafft"),
        ])
        XCTAssertEqual(change.pathPrefix, [])
        XCTAssertNil(stage.identityHint, "A free label such as Primer3 is not an identity")
    }

    func testRunProcessNamesTheNativeToolItWasGivenAndNothingWithoutAnEnvironment() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        let tool = try fixture.installStandaloneTool()
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.runProcess(
                executableURL: tool, arguments: [fixture.dumpURL("process").path], timeout: 30, toolName: "samtools"
            )
        }

        let stage = try declaredStage(of: log, label: "samtools")
        let change = try XCTUnwrap(stage.environmentChange)
        XCTAssertEqual(change.set, [])
        XCTAssertEqual(change.unset, [])
        XCTAssertEqual(change.pathPrefix, [])
        XCTAssertEqual(stage.identityHint, "samtools")
    }

    func testACallersPathThatExtendsTheInheritedPathRecordsOnlyTheEntriesBeforeIt() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        let tool = try fixture.installStandaloneTool()
        let inherited = try XCTUnwrap(Self.parent["PATH"] ?? nil)
        let callers = ["PATH": "/lge-s2/first/tools:/lge-s2/second/scripts:\(inherited)"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.runProcess(
                executableURL: tool, arguments: [fixture.dumpURL("process").path], environment: callers, timeout: 30
            )
        }

        let change = try XCTUnwrap(try declaredStage(of: log, label: "dumper").environmentChange)
        XCTAssertEqual(change.pathPrefix, ["<external>/tools", "<external>/scripts"])
        XCTAssertNil(try XCTUnwrap(change.set.first { $0.name == "PATH" }).value)
    }

    func testACallersPathThatReplacesTheInheritedPathRecordsEveryEntry() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        let tool = try fixture.installStandaloneTool()
        let callers = ["PATH": "/lge-s2/only/tools:/usr/bin"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.runProcess(
                executableURL: tool, arguments: [fixture.dumpURL("process").path], environment: callers, timeout: 30
            )
        }

        let change = try XCTUnwrap(try declaredStage(of: log, label: "dumper").environmentChange)
        XCTAssertEqual(change.pathPrefix, ["<external>/tools", "/usr/bin"])
    }

    // MARK: - runWithFileOutput and runPipeline

    func testRunWithFileOutputRecordsTheChangeAndHintThatRunRecords() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.pigz)
        let callers = ["LGE_S2_CALLER": "set by the caller", "MAFFT_BINARIES": "/lge-s2/mafft"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let runLog = AdapterObservationLog()
        let fileLog = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(runLog.observer) {
            try await fixture.runner.run(.pigz, arguments: [fixture.dumpURL("run").path], environment: callers, timeout: 30)
        }
        _ = try await ToolProcessObservation.$observer.withValue(fileLog.observer) {
            try await fixture.runner.runWithFileOutput(
                .pigz, arguments: [fixture.dumpURL("file").path], outputFile: fixture.root.appendingPathComponent("out.gz"),
                environment: callers, timeout: 30
            )
        }

        let fromRun = try declaredStage(of: runLog, label: "pigz")
        let fromFile = try declaredStage(of: fileLog, label: "pigz")
        XCTAssertNotNil(fromFile.environmentChange)
        XCTAssertEqual(fromFile.environmentChange, fromRun.environmentChange)
        XCTAssertEqual(fromFile.identityHint, "pigz")
        XCTAssertEqual(fromRun.identityHint, "pigz")
    }

    func testRunPipelineRecordsEachStagesOwnChangeAndHint() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.seqkit)
        try fixture.install(.samtools)
        let callers = ["LGE_S2_CALLER": "set by the caller"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.runPipeline(
                [
                    NativePipelineStage(.seqkit, arguments: [fixture.dumpURL("first").path]),
                    NativePipelineStage(.samtools, arguments: [fixture.dumpURL("second").path]),
                ],
                environment: callers,
                timeout: 30
            )
        }

        let observations = log.all
        XCTAssertEqual(observations.count, 1, "A pipeline delivers one observation")
        let stages = try XCTUnwrap(observations.first).stages
        XCTAssertEqual(stages.map(\.label), ["seqkit", "samtools"])
        XCTAssertEqual(stages.map(\.identityHint), ["seqkit", "samtools"])
        let context = await fixture.runner.environmentChangeContext
        for (stage, tool) in zip(stages, [NativeTool.seqkit, .samtools]) {
            let change = try XCTUnwrap(stage.environmentChange)
            XCTAssertEqual(change.base, .inherited)
            XCTAssertEqual(change.set.map(\.name), ["LGE_S2_CALLER", "PATH"])
            XCTAssertEqual(change.pathPrefix, [PortablePath.sanitize(path: fixture.binDirectory(of: tool).path, context: context)])
        }
    }

    // MARK: - Guarantees

    /// Decision P10 and the rule that a record never holds the inherited
    /// environment. A secret in a value, a proxy address or the account's home
    /// and scratch folders stay out, and the names stay in.
    func testNoSecretAndNoInheritedValueReachesTheChange() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.seqkit)
        let callers = [
            "LGE_S2_API_KEY": "sk-lge-s2-secret",
            "HTTPS_PROXY": "http://user:pw@proxy:8080",
            "HOME": "/lge-s2/home",
            "TMPDIR": "/lge-s2/tmp",
            "XDG_CACHE_HOME": "/lge-s2/cache",
        ]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.run(.seqkit, arguments: [fixture.dumpURL("seqkit").path], environment: callers, timeout: 30)
        }

        let change = try XCTUnwrap(try declaredStage(of: log, label: "seqkit").environmentChange)
        XCTAssertEqual(change.set.map(\.name), ["HOME", "HTTPS_PROXY", "LGE_S2_API_KEY", "PATH", "TMPDIR", "XDG_CACHE_HOME"])
        XCTAssertTrue(change.set.allSatisfy { $0.value == nil }, "None of these names is on the allowlist")
        let strings = everyString(in: change)
        let forbidden = [
            "sk-lge-s2-secret", "user:pw", "/lge-s2/home", "/lge-s2/tmp", "/lge-s2/cache",
            "set by the parent", "LGE_S2_PARENT", "/lge-s2/parent/bin",
        ]
        for text in forbidden {
            XCTAssertFalse(strings.contains { $0.contains(text) }, "\(text) must not reach a record")
        }
    }

    /// Filling the change leaves the child environment alone, with an observer
    /// bound and without one.
    func testBindingAnObserverDoesNotChangeTheNativeChildEnvironment() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }
        try fixture.install(.seqkit)
        let callers = ["LGE_S2_CALLER": "set by the caller", "JAVA_HOME": "/lge-s2/caller/jvm"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let plain = fixture.dumpURL("plain")
        let observed = fixture.dumpURL("observed")
        let log = AdapterObservationLog()

        _ = try await fixture.runner.run(.seqkit, arguments: [plain.path], environment: callers, timeout: 30)
        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.runner.run(.seqkit, arguments: [observed.path], environment: callers, timeout: 30)
        }

        _ = try declaredStage(of: log, label: "seqkit")
        EnvironmentDump.assertEqual(try EnvironmentDump.read(observed), try EnvironmentDump.read(plain))
    }

    /// Building the change sanitizes paths, so an unobserved launch skips it.
    func testNoChangeIsBuiltForANativeLaunchWithoutAnObserver() async throws {
        let fixture = try AdapterToolRoot()
        defer { fixture.remove() }

        let outside = await fixture.runner.observedEnvironmentChange(overriding: ["LGE_S2_CALLER": "1"])
        let inside = await ToolProcessObservation.$observer.withValue(AdapterObservationLog().observer) {
            await fixture.runner.observedEnvironmentChange(overriding: ["LGE_S2_CALLER": "1"])
        }

        XCTAssertNil(outside)
        XCTAssertNotNil(inside)
    }

    // MARK: - The pure parts

    func testChangeKeepsValuesOnlyForAllowlistedNamesAndReadsTheManagedRootAsAPlaceholder() {
        let change = NativeToolRunner.environmentChange(
            overriding: [
                "JAVA_HOME": "/Users/someone/lungfish-tools/envs/bbtools/lib/jvm",
                "BBMAP_JAVA": "/Users/someone/lungfish-tools/envs/bbtools/lib/jvm/bin/java",
                "PATH": "/Users/someone/lungfish-tools/envs/bbtools/lib/jvm/bin:/Users/someone/lungfish-tools/envs/bbtools/bin:/usr/bin:/bin",
                "HOME": "/Users/someone",
                "TMPDIR": "/Users/someone/scratch",
                "LGE_S2_API_KEY": "sk-lge-s2-secret",
                "HTTPS_PROXY": "http://user:pw@proxy:8080",
            ],
            inheritedPath: "/usr/bin:/bin",
            sanitizing: Self.context
        )

        XCTAssertEqual(change.base, .inherited)
        XCTAssertEqual(change.set, [
            .init(name: "BBMAP_JAVA", value: "<tool-root>/envs/bbtools/lib/jvm/bin/java"),
            .init(name: "HOME", value: nil),
            .init(name: "HTTPS_PROXY", value: nil),
            .init(name: "JAVA_HOME", value: "<tool-root>/envs/bbtools/lib/jvm"),
            .init(name: "LGE_S2_API_KEY", value: nil),
            .init(name: "PATH", value: nil),
            .init(name: "TMPDIR", value: nil),
        ])
        XCTAssertEqual(change.unset, [])
        XCTAssertEqual(change.pathPrefix, ["<tool-root>/envs/bbtools/lib/jvm/bin", "<tool-root>/envs/bbtools/bin"])
    }

    func testNoOverridesIsAnEmptyChange() {
        let change = NativeToolRunner.environmentChange(overriding: nil, inheritedPath: "/usr/bin", sanitizing: Self.context)

        XCTAssertEqual(change, NativeToolRunner.environmentChange(overriding: [:], inheritedPath: "/usr/bin", sanitizing: Self.context))
        XCTAssertEqual(change.set, [])
        XCTAssertEqual(change.pathPrefix, [])
    }

    func testPathPrefixIsTheEntriesBeforeTheInheritedPath() {
        let prefix = NativeToolRunner.pathPrefix(of:inheritedPath:)

        XCTAssertEqual(prefix(nil, "/a"), [], "No PATH set")
        XCTAssertEqual(prefix("/a", "/a"), [], "The inherited PATH itself")
        XCTAssertEqual(prefix("/b:/a", "/a"), ["/b"])
        XCTAssertEqual(prefix("/c:/b:/a:/z", "/a:/z"), ["/c", "/b"])
        XCTAssertEqual(prefix("/b::/a", "/a"), ["/b"], "Empty entries are left out")
        XCTAssertEqual(prefix("/b:/x", "/a"), ["/b", "/x"], "A replaced PATH is recorded whole")
        XCTAssertEqual(prefix("/b:/aa", "/a"), ["/b", "/aa"], "The inherited PATH ends at an entry boundary")
        XCTAssertEqual(prefix("/b:/a", nil), ["/b", "/a"], "Nothing inherited")
        XCTAssertEqual(prefix("", nil), [])
    }

    func testOnlyANativeToolNameIsAnIdentityHint() {
        XCTAssertEqual(NativeToolRunner.nativeToolName("seqkit"), "seqkit")
        XCTAssertEqual(NativeToolRunner.nativeToolName("trimGalore"), "trimGalore")
        XCTAssertNil(NativeToolRunner.nativeToolName("trim_galore"), "The executable name is not the tool name")
        XCTAssertNil(NativeToolRunner.nativeToolName("Primer3 version probe"))
        XCTAssertNil(NativeToolRunner.nativeToolName(nil))
    }
}
