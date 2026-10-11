// ToolProcessEnvironmentChangeAdapterTests.swift - The environment change that the 2.7 adapters fill
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S2 (scope row B1, decisions P2 and P10). CondaManager.runTool
// and NativeToolRunner fill ToolProcessSpec.environmentChange and identityHint
// where they build a child environment. A recorded change names every
// variable the adapter set, keeps a value only for an allowlisted name, keeps
// PATH only as the entries the adapter put first, and keeps HOME and TMPDIR by
// name only. The child environment itself stays what
// AdapterChildEnvironmentPinTests pins. This file holds the CondaManager tests
// and the helpers, and the NativeToolRunner tests are in the +NativeTool file.

import XCTest
@testable import LungfishWorkflow
import LungfishCore

final class ToolProcessEnvironmentChangeAdapterTests: XCTestCase {
    /// A context without temporary roots, so a managed root reads
    /// `<tool-root>` and `<storage-root>` wherever the test folder lives.
    static let context = PortablePath.Context(
        projectURL: nil,
        toolRootURL: URL(fileURLWithPath: "/Users/someone/lungfish-tools", isDirectory: true),
        storageRootURL: URL(fileURLWithPath: "/Users/someone/lungfish-storage", isDirectory: true),
        temporaryRootURLs: []
    )

    /// The parent environment of the observed runs.
    static let parent: [String: String?] = [
        "LGE_S2_PARENT": "set by the parent",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/lge-s2/parent/bin",
    ]

    // MARK: - CondaManager.runTool

    func testRunToolRecordsEveryVariableItSetAsAHermeticChange() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let scratch = try fixture.scratchDirectory()
        let callers = ["ESVIRITU_DB": "/lge-s2/databases/esviritu", "JAVA_HOME": "/lge-s2/jvm"]
        let parent = ParentEnvironmentOverride(Self.parent.merging(["TMPDIR": scratch.path]) { _, new in new })
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.manager.runTool(
                name: "dumper", arguments: [fixture.dumpURL("tool").path], environment: "dumper-env",
                environmentVariables: callers, timeout: 30
            )
        }

        let stage = try declaredStage(of: log, label: "dumper")
        let change = try XCTUnwrap(stage.environmentChange)
        XCTAssertEqual(change.base, .hermetic)
        XCTAssertEqual(change.set.map(\.name), ["ESVIRITU_DB", "HOME", "JAVA_HOME", "MAMBA_ROOT_PREFIX", "PATH", "TMPDIR"])
        XCTAssertEqual(change.unset, [])
        XCTAssertEqual(change.pathPrefix, ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        // A value only for an allowlisted name, and sanitized.
        let values = Dictionary(uniqueKeysWithValues: change.set.map { ($0.name, $0.value) })
        XCTAssertNil(try XCTUnwrap(values["ESVIRITU_DB"]), "ESVIRITU_DB is not on the allowlist")
        XCTAssertEqual(try XCTUnwrap(values["JAVA_HOME"]), "<external>/jvm")
        let root = try XCTUnwrap(try XCTUnwrap(values["MAMBA_ROOT_PREFIX"]))
        XCTAssertEqual(root, PortablePath.sanitize(path: fixture.manager.rootPrefix.path, context: fixture.manager.environmentChangeContext))
        XCTAssertFalse(root.contains(fixture.sandbox.path), "The conda root is recorded sanitized")
        XCTAssertEqual(stage.identityHint, "dumper-env")
        // The parent's own variables are never part of a hermetic change.
        XCTAssertFalse(everyString(in: change).contains { $0.contains("set by the parent") || $0.contains("LGE_S2_PARENT") })
    }

    /// Decision P10. HOME and TMPDIR name the account's home and scratch
    /// folders, so a record keeps their names and never their values, whether
    /// the adapter set them or the caller did.
    func testRunToolRecordsHomeAndTmpdirByNameOnly() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let scratch = try fixture.scratchDirectory()
        let callers = ["XDG_CACHE_HOME": "/lge-s2/cache-home", "MAFFT_TMPDIR": "/lge-s2/mafft-scratch"]
        let parent = ParentEnvironmentOverride(Self.parent.merging(["TMPDIR": scratch.path]) { _, new in new })
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.manager.runTool(
                name: "dumper", arguments: [fixture.dumpURL("tool").path], environment: "dumper-env",
                environmentVariables: callers, timeout: 30
            )
        }

        let change = try XCTUnwrap(try declaredStage(of: log, label: "dumper").environmentChange)
        for name in ["HOME", "TMPDIR", "XDG_CACHE_HOME", "MAFFT_TMPDIR", "PATH"] {
            let variable = try XCTUnwrap(change.set.first { $0.name == name }, "\(name) is named")
            XCTAssertNil(variable.value, "\(name) keeps its name only")
        }
        let strings = everyString(in: change)
        let rawValues = [
            FileManager.default.homeDirectoryForCurrentUser.path, scratch.path, "/lge-s2/cache-home", "/lge-s2/mafft-scratch",
        ]
        for raw in rawValues {
            XCTAssertFalse(strings.contains { $0.contains(raw) }, "The value \(raw) must not reach a record")
        }
    }

    func testRunToolNamesNoTmpdirWhenTheParentHasNone() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let parent = ParentEnvironmentOverride(Self.parent.merging(["TMPDIR": nil]) { _, new in new })
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.manager.runTool(
                name: "dumper", arguments: [fixture.dumpURL("tool").path], environment: "dumper-env", timeout: 30
            )
        }

        let change = try XCTUnwrap(try declaredStage(of: log, label: "dumper").environmentChange)
        XCTAssertEqual(change.set.map(\.name), ["HOME", "MAMBA_ROOT_PREFIX", "PATH"])
    }

    /// A caller that sets its own PATH replaces the fixed one, and the change
    /// holds that PATH's entries, sanitized, never a value.
    func testRunToolRecordsAPathTheCallerGaveAsSanitizedEntries() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let rootBin = fixture.manager.rootPrefix.appendingPathComponent("envs/dumper-env/bin").path
        let callers = ["PATH": "\(rootBin):/lge-s2/caller/bin:/usr/bin"]
        let parent = ParentEnvironmentOverride(Self.parent)
        defer { parent.restore() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.manager.runTool(
                name: "dumper", arguments: [fixture.dumpURL("tool").path], environment: "dumper-env",
                environmentVariables: callers, timeout: 30
            )
        }

        let change = try XCTUnwrap(try declaredStage(of: log, label: "dumper").environmentChange)
        let sanitizedBin = PortablePath.sanitize(path: rootBin, context: fixture.manager.environmentChangeContext)
        XCTAssertEqual(change.pathPrefix, [sanitizedBin, "<external>/bin", "/usr/bin"])
        XCTAssertNil(try XCTUnwrap(change.set.first { $0.name == "PATH" }).value)
    }

    /// An observer bound around runTool also receives the micromamba version
    /// probes that ensureMicromamba runs inside it. Today they carry no hint
    /// and no change. That does not find the declared step, because a probe
    /// that goes through runTool, such as `bracken --help`, carries both. P2
    /// binds the observer around the declared launch alone.
    func testTheVersionProbesInsideRunToolCarryNeitherAHintNorAChange() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let log = AdapterObservationLog()

        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.manager.runTool(
                name: "dumper", arguments: [fixture.dumpURL("tool").path], environment: "dumper-env", timeout: 30
            )
        }

        let stages = log.all.flatMap(\.stages)
        let hinted = stages.filter { $0.identityHint != nil }
        XCTAssertEqual(hinted.map(\.label), ["dumper"])
        XCTAssertEqual(stages.filter { $0.environmentChange != nil }.map(\.label), ["dumper"])
    }

    /// Filling the change leaves the child environment alone, with an observer
    /// bound and without one.
    func testBindingAnObserverDoesNotChangeTheChildEnvironment() async throws {
        let fixture = try await AdapterCondaRoot()
        defer { fixture.remove() }
        let scratch = try fixture.scratchDirectory()
        let callers = ["ESVIRITU_DB": "/lge-s2/databases/esviritu"]
        let parent = ParentEnvironmentOverride(Self.parent.merging(["TMPDIR": scratch.path]) { _, new in new })
        defer { parent.restore() }
        let plain = fixture.dumpURL("plain")
        let observed = fixture.dumpURL("observed")
        let log = AdapterObservationLog()

        _ = try await fixture.manager.runTool(
            name: "dumper", arguments: [plain.path], environment: "dumper-env", environmentVariables: callers, timeout: 30
        )
        _ = try await ToolProcessObservation.$observer.withValue(log.observer) {
            try await fixture.manager.runTool(
                name: "dumper", arguments: [observed.path], environment: "dumper-env", environmentVariables: callers, timeout: 30
            )
        }

        _ = try declaredStage(of: log, label: "dumper")
        EnvironmentDump.assertEqual(try EnvironmentDump.read(observed), try EnvironmentDump.read(plain))
    }

    /// Building the change sanitizes paths, so an unobserved launch skips it.
    func testNoChangeIsBuiltForALaunchWithoutAnObserver() {
        let manager = CondaManager(rootPrefix: URL(fileURLWithPath: "/Users/someone/lungfish-tools", isDirectory: true))
        let environment = manager.hermeticToolEnvironment(adding: nil, homeDirectory: "/Users/someone", temporaryDirectory: nil)

        XCTAssertNil(manager.observedEnvironmentChange(of: environment))
        let inside = ToolProcessObservation.$observer.withValue(AdapterObservationLog().observer) {
            manager.observedEnvironmentChange(of: environment)
        }
        XCTAssertNotNil(inside)
    }

    func testHermeticEnvironmentIsTheRootPrefixTheFixedPathHomeAndTmpdirWithTheCallersOverIt() {
        let manager = CondaManager(rootPrefix: URL(fileURLWithPath: "/Users/someone/lungfish-tools", isDirectory: true))

        XCTAssertEqual(
            manager.hermeticToolEnvironment(adding: nil, homeDirectory: "/Users/someone", temporaryDirectory: "/var/scratch"),
            [
                "MAMBA_ROOT_PREFIX": "/Users/someone/lungfish-tools",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": "/Users/someone",
                "TMPDIR": "/var/scratch",
            ]
        )
        XCTAssertEqual(
            manager.hermeticToolEnvironment(
                adding: ["HOME": "/caller", "ESVIRITU_DB": "/db"], homeDirectory: "/Users/someone", temporaryDirectory: nil
            ),
            [
                "MAMBA_ROOT_PREFIX": "/Users/someone/lungfish-tools",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": "/caller",
                "ESVIRITU_DB": "/db",
            ]
        )
    }

    func testHermeticChangeReadsTheManagedRootsAsPlaceholders() {
        let manager = CondaManager(rootPrefix: URL(fileURLWithPath: "/Users/someone/lungfish-tools", isDirectory: true))
        let environment = manager.hermeticToolEnvironment(
            adding: ["MAMBA_NO_BANNER": "1", "JAVA_HOME": "/Users/someone/lungfish-tools/envs/bbtools/lib/jvm"],
            homeDirectory: "/Users/someone",
            temporaryDirectory: "/Users/someone/scratch"
        )

        let change = manager.environmentChange(of: environment, sanitizing: Self.context)

        XCTAssertEqual(change.base, .hermetic)
        XCTAssertEqual(change.set, [
            .init(name: "HOME", value: nil),
            .init(name: "JAVA_HOME", value: "<tool-root>/envs/bbtools/lib/jvm"),
            .init(name: "MAMBA_NO_BANNER", value: "1"),
            .init(name: "MAMBA_ROOT_PREFIX", value: "<tool-root>"),
            .init(name: "PATH", value: nil),
            .init(name: "TMPDIR", value: nil),
        ])
        XCTAssertEqual(change.pathPrefix, ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }

    // MARK: - Helpers

    /// The stage of the declared launch, found by its label. A run of
    /// CondaManager.runTool also probes micromamba's version inside the scope
    /// of the observer, and each probe delivers an observation of its own.
    func declaredStage(
        of log: AdapterObservationLog,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ToolProcessRunObservation.Stage {
        let stages = log.all.flatMap(\.stages).filter { $0.label == label }
        XCTAssertEqual(stages.count, 1, "One launch delivers one stage labeled \(label)", file: file, line: line)
        return try XCTUnwrap(stages.first, file: file, line: line)
    }

    /// Every string a record would hold for the change.
    func everyString(in change: ToolProcessEnvironmentChange) -> [String] {
        change.set.flatMap { [$0.name, $0.value ?? ""] } + change.unset + change.pathPrefix
    }
}
