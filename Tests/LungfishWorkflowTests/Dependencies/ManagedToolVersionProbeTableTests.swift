// ManagedToolVersionProbeTableTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Pure checks on the version probe table and the lock entry lookups. They need no
// installed tools, so they run in the unit tier. The class that runs the probes
// against a real root is ToolVersionConformanceTests.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ManagedToolVersionProbeTableTests: XCTestCase {
    /// Probe executables the lock does not declare for their entry. Empty, and it stays
    /// exact so a new mismatch is a decision and not a silent skip at probe time.
    private static let knownUndeclaredProbeExecutables: Set<String> = []

    private func lockIDs(_ lock: ManagedToolLock) -> [String] {
        lock.tools.map(\.id) + lock.packTools.map(\.toolID)
    }

    func testLockHasFortyFourUniqueIDs() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let ids = lockIDs(lock)
        XCTAssertEqual(ids.count, 44)
        XCTAssertEqual(Set(ids).count, ids.count, "tools and packTools share no id")
        XCTAssertEqual(lock.entries.count, ids.count)
    }

    func testProbeTableKeysEqualTheLockIDs() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let probed = ManagedToolVersionProbe.probedIDs.map(\.rawValue)
        let declared = ManagedToolVersionProbe.declaredEntries.map(\.id)
        XCTAssertEqual(Set(declared).count, declared.count, "the probe table declares no id twice")
        XCTAssertEqual(Set(probed), Set(lockIDs(lock)))
    }

    func testEveryProbeExecutableIsDeclaredByItsLockEntry() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        var undeclared: Set<String> = []
        for entry in lock.entries {
            let probe = try XCTUnwrap(ManagedToolVersionProbe.probe(for: entry.id), "\(entry.id) has no probe")
            if !entry.executables.contains(probe.executable) {
                undeclared.insert("\(entry.id.rawValue):\(probe.executable)")
            }
        }
        XCTAssertEqual(undeclared, Self.knownUndeclaredProbeExecutables)
    }

    func testEntryLookupsFindEveryToolAndPackTool() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        for tool in lock.tools {
            let byID = try XCTUnwrap(lock.entry(id: ManagedToolID(rawValue: tool.id)), tool.id)
            XCTAssertEqual(byID.source, .tool)
            XCTAssertEqual(byID.environment, tool.environment)
            XCTAssertEqual(byID.version, tool.version)
            XCTAssertEqual(byID.executables, tool.executables)
            XCTAssertEqual(lock.entry(environment: tool.environment), byID)
        }
        for tool in lock.packTools {
            let byID = try XCTUnwrap(lock.entry(id: ManagedToolID(rawValue: tool.toolID)), tool.toolID)
            XCTAssertEqual(byID.source, .packTool(packID: tool.packID))
            XCTAssertEqual(byID.environment, tool.environment)
            XCTAssertEqual(byID.version, tool.version)
            XCTAssertEqual(byID.executables, tool.executables)
            XCTAssertEqual(byID.pythonRuntime, tool.pythonRuntime)
            XCTAssertEqual(byID.sourceBuild, tool.sourceBuild)
            XCTAssertEqual(lock.entry(environment: tool.environment), byID)
        }
        let environments = lock.entries.map(\.environment)
        XCTAssertEqual(Set(environments).count, environments.count, "each environment holds one lock entry")
    }

    /// The tools the conformance run exempts when their environment is absent. The set is
    /// derived from the pack registry's experimental flag and pinned, so a new exemption
    /// is a decision.
    func testExperimentalPackToolsArePinnedExactly() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let experimental = Set(lock.entries.filter(\.isInExperimentalPack).map(\.id.rawValue))
        XCTAssertEqual(experimental, ["freyja", "gatk4", "whatshap"])
        XCTAssertFalse(try XCTUnwrap(lock.entry(id: ManagedToolID(rawValue: "samtools"))).isInExperimentalPack)
        XCTAssertFalse(try XCTUnwrap(lock.entry(id: ManagedToolID(rawValue: "primer3"))).isInExperimentalPack)
    }

    func testUnknownIDsAndEnvironmentsGiveNil() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let unknown = ManagedToolID(rawValue: "no-such-tool")
        XCTAssertNil(ManagedToolVersionProbe.probe(for: unknown))
        XCTAssertNil(lock.entry(id: unknown))
        XCTAssertNil(lock.entry(environment: "no-such-environment"))
    }

    func testPythonRuntimeAndSourceBuildFactsAreRepresentable() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let primalscheme3 = try XCTUnwrap(lock.entry(id: ManagedToolID(rawValue: "primalscheme3")))
        XCTAssertNotNil(primalscheme3.pythonRuntime)
        XCTAssertEqual(primalscheme3.pythonRuntime?.version, primalscheme3.version)
        let bracken = try XCTUnwrap(lock.entry(id: ManagedToolID(rawValue: "bracken")))
        XCTAssertNotNil(bracken.sourceBuild)
        XCTAssertEqual(bracken.preserveExistingInstall, true)
    }

    // MARK: - Dialects

    private func ids(with dialect: ManagedToolVersionProbe.Dialect) -> Set<String> {
        Set(ManagedToolVersionProbe.probedIDs.filter {
            ManagedToolVersionProbe.probe(for: $0)?.dialect == dialect
        }.map(\.rawValue))
    }

    /// The conda-meta exception must stay narrow, and each excepted tool must
    /// actually be pinned by the lock as a pack tool. A stale entry would silently
    /// stop checking a tool that has since been fixed or removed. Adding a tool here
    /// weakens its version assertion, so document the upstream defect first.
    func testConfirmedVersionExceptionsStayNarrowAndPinned() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let condaMetaOnly = ids(with: .condaMetaOnly)
        XCTAssertEqual(condaMetaOnly, ["bwa-mem2", "bracken"])
        let packToolIDs = Set(lock.packTools.map(\.toolID))
        XCTAssertTrue(condaMetaOnly.isSubset(of: packToolIDs))
        XCTAssertEqual(ids(with: .notSelfReported), ["ucsc-bedgraphtobigwig"])
        XCTAssertEqual(ids(with: .selfReportedWithHelpFallback), ["savont"])
    }

    func testProbesThatDifferFromTheOldTableOrWereAddedStayPinned() {
        func probe(_ id: String) -> ManagedToolVersionProbe? {
            ManagedToolVersionProbe.probe(for: ManagedToolID(rawValue: id))
        }
        // RiboDetector is probed through the executable LGE runs, not the GPU entry point.
        XCTAssertEqual(probe("ribodetector"), ManagedToolVersionProbe(
            executable: "ribodetector_cpu", arguments: ["-v"], dialect: .selfReported))
        // The four ids the old conformance table did not cover.
        XCTAssertEqual(probe("primer3"), ManagedToolVersionProbe(
            executable: "primer3_core", arguments: ["--about"], dialect: .selfReported))
        XCTAssertEqual(probe("primalscheme3"), ManagedToolVersionProbe(
            executable: "primalscheme3", arguments: ["--version"], dialect: .selfReported))
        XCTAssertEqual(probe("olivar"), ManagedToolVersionProbe(
            executable: "olivar", arguments: ["--version"], dialect: .selfReported))
        XCTAssertEqual(probe("varvamp"), ManagedToolVersionProbe(
            executable: "varvamp", arguments: ["--version"], dialect: .selfReported))
        // One lightweight BBTools wrapper, never one that starts a JVM sized to free memory.
        XCTAssertEqual(probe("bbtools"), ManagedToolVersionProbe(
            executable: "reformat.sh", arguments: ["--version"], dialect: .selfReported))
    }

    // MARK: - Version matcher

    /// `textReportsVersion` must anchor on a whole version token, not just any
    /// substring. A short pin like "2.3" must not match inside "2.30", and
    /// an unrelated version elsewhere in the output must not match either.
    func testTextReportsVersionAnchorsOnWholeToken() {
        XCTAssertFalse(ConformanceFixtures.textReportsVersion("2.30", version: "2.3"))
        XCTAssertTrue(ConformanceFixtures.textReportsVersion("minimap2 2.30-r1287", version: "2.30"))
        XCTAssertFalse(ConformanceFixtures.textReportsVersion("bracken 3.0.1", version: "1.0.0"))
        XCTAssertTrue(ConformanceFixtures.textReportsVersion("samtools 1.23.1", version: "1.23.1"))
        XCTAssertTrue(ConformanceFixtures.textReportsVersion("cutadapt 5.2", version: "5.2"))
    }
}
