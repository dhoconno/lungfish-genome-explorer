// ToolRegistryAgreementTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Holds the NativeTool cases, the analysis registry, the provenance policies and the version
// probe table to the managed tool lock. Each check is a function of a lock value that returns
// its violations, so the negative controls feed it a damaged copy and the bundled lock stays
// untouched. Pure, so it runs in the unit tier.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ToolRegistryAgreementTests: XCTestCase {
    /// Tools whose executable the lock entry does not declare. Exact, so a new mismatch is a
    /// decision and not a silent pass. The medaka entry lists only `medaka`.
    private static let knownUndeclaredNativeExecutables: Set<String> = ["medakaVariant:medaka_variant"]

    /// Analysis kinds with no lock link: imported results, built-in code and a container.
    private static let expectedUnlinkedAnalysisIDs: Set<String> = [
        "naomgs", "nvd", "cz-id", "ont-genotyping", "primer-order", "pbaa",
    ]

    // MARK: - Checks

    private func nativeToolViolations(_ lock: ManagedToolLock) -> Set<String> {
        var violations: Set<String> = []
        for tool in NativeTool.allCases {
            guard let entry = lock.entry(id: tool.managedToolID) else {
                violations.insert("\(tool.rawValue):no lock entry \(tool.managedToolID.rawValue)")
                continue
            }
            guard case .managed(let environment, let executableName) = tool.location else {
                violations.insert("\(tool.rawValue):not managed")
                continue
            }
            if environment != entry.environment {
                violations.insert("\(tool.rawValue):environment \(environment) vs \(entry.environment)")
            }
            if !entry.executables.contains(executableName) {
                violations.insert("\(tool.rawValue):\(executableName)")
            }
        }
        return violations
    }

    private func analysisViolations(_ lock: ManagedToolLock) -> (broken: Set<String>, unlinked: Set<String>) {
        var broken: Set<String> = []
        var unlinked: Set<String> = []
        let pipelineIDs = Set(lock.pipelines.map(\.id))
        for descriptor in AnalysisToolRegistry.all {
            let id = descriptor.id.rawValue
            switch descriptor.provisioning {
            case .managedTool(let toolID):
                if lock.entry(id: toolID) == nil { broken.insert("\(id):\(toolID.rawValue)") }
            case .lockedPipeline(let pipelineID):
                if !pipelineIDs.contains(pipelineID) { broken.insert("\(id):\(pipelineID)") }
            case .container, .importedResult, .builtIn:
                unlinked.insert(id)
            }
        }
        return (broken, unlinked)
    }

    private func probeViolations(_ lock: ManagedToolLock) -> Set<String> {
        let lockIDs = Set(lock.entries.map(\.id.rawValue))
        let probedIDs = Set(ManagedToolVersionProbe.probedIDs.map(\.rawValue))
        return lockIDs.symmetricDifference(probedIDs)
    }

    /// The lock with the `id` entry dropped from both lists.
    private func lock(_ lock: ManagedToolLock, without id: String) -> ManagedToolLock {
        ManagedToolLock(
            packID: lock.packID, displayName: lock.displayName, version: lock.version,
            tools: lock.tools.filter { $0.id != id }, managedData: lock.managedData,
            packTools: lock.packTools.filter { $0.toolID != id },
            pipelines: lock.pipelines.filter { $0.id != id })
    }

    // MARK: - Agreement

    func testEveryNativeToolResolvesToALockEntryThatDeclaresIt() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        XCTAssertEqual(nativeToolViolations(lock), Self.knownUndeclaredNativeExecutables)
    }

    func testNativeToolPolicyKeysEqualTheNativeToolCases() {
        XCTAssertEqual(
            Set(ScientificProvenancePolicy.nativeToolPolicies.keys),
            Set(NativeTool.allCases.map(\.rawValue)))
    }

    func testAnalysisRegistryLockLinksResolve() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let result = analysisViolations(lock)
        XCTAssertEqual(result.broken, [])
        XCTAssertEqual(result.unlinked, Self.expectedUnlinkedAnalysisIDs)
    }

    func testProbeTableAndLockHaveTheSameIDs() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        XCTAssertEqual(probeViolations(lock), [])
    }

    // MARK: - Negative controls

    func testRemovingALockEntryIsReportedByEveryCheck() throws {
        let bundled = try ManagedToolLock.loadFromBundle()
        let damaged = lock(bundled, without: "bbtools")
        XCTAssertNil(damaged.entry(id: ManagedToolID(rawValue: "bbtools")))

        let native = nativeToolViolations(damaged)
        XCTAssertTrue(native.contains("bbduk:no lock entry bbtools"))
        XCTAssertTrue(native.contains("mapPacBio:no lock entry bbtools"))
        XCTAssertTrue(analysisViolations(damaged).broken.contains("bbmap:bbtools"))
        XCTAssertEqual(probeViolations(damaged), ["bbtools"])
    }

    func testRemovingALockPipelineIsReported() throws {
        let bundled = try ManagedToolLock.loadFromBundle()
        let damaged = lock(bundled, without: "nf-core-viralrecon")
        XCTAssertEqual(analysisViolations(damaged).broken, ["viralrecon:nf-core-viralrecon"])
    }

    func testChangedEnvironmentAndExecutablesAreReported() throws {
        let bundled = try ManagedToolLock.loadFromBundle()
        let spec = try XCTUnwrap(bundled.tools.first { $0.id == "samtools" })
        let renamed = ManagedToolLock.ToolSpec(
            id: spec.id, environment: "renamed-env", packageSpec: spec.packageSpec,
            executables: ["other"], version: spec.version)
        let damaged = ManagedToolLock(
            packID: bundled.packID, displayName: bundled.displayName, version: bundled.version,
            tools: bundled.tools.map { $0.id == "samtools" ? renamed : $0 },
            managedData: bundled.managedData, packTools: bundled.packTools,
            pipelines: bundled.pipelines)

        let added = nativeToolViolations(damaged).subtracting(Self.knownUndeclaredNativeExecutables)
        XCTAssertEqual(added, ["samtools:environment samtools vs renamed-env", "samtools:samtools"])
    }

    func testPolicyKeyComparisonSeesAMissingAndAStaleKey() {
        var keys = Set(ScientificProvenancePolicy.nativeToolPolicies.keys)
        keys.remove("samtools")
        keys.insert("removedTool")
        let cases = Set(NativeTool.allCases.map(\.rawValue))
        XCTAssertEqual(cases.subtracting(keys), ["samtools"])
        XCTAssertEqual(keys.subtracting(cases), ["removedTool"])
    }
}
