// AnalysisRunsToolsAgreementTests.swift - Holds each analysis kind's tool list to the managed tool lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7, lane B5. The registry lists, per analysis kind, the managed tools its pipeline runs, by lock id.
// IO cannot read the lock, so this suite holds every listed id to a lock entry and to a row of the version probe
// table, the way ToolRegistryAgreementTests holds the provisioning links. Each check is a function of a lock
// value and a set of probed ids, so the negative controls feed it a damaged copy and the bundled lock stays
// untouched. Pure, so it runs in the unit tier.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class AnalysisRunsToolsAgreementTests: XCTestCase {
    private func listedTools() -> [(kind: String, tool: ManagedToolID)] {
        AnalysisToolRegistry.all.flatMap { descriptor in
            descriptor.runsTools.map { (descriptor.id.rawValue, $0) }
        }
    }

    /// `kind:tool` for every listed tool the lock has no entry for.
    private func notInTheLock(_ lock: ManagedToolLock) -> Set<String> {
        Set(listedTools().filter { lock.entry(id: $0.tool) == nil }.map { "\($0.kind):\($0.tool.rawValue)" })
    }

    /// `kind:tool` for every listed tool the version probe table has no row for.
    private func notInTheProbeTable(_ probed: Set<String>) -> Set<String> {
        Set(listedTools().filter { !probed.contains($0.tool.rawValue) }.map { "\($0.kind):\($0.tool.rawValue)" })
    }

    private var probedIDs: Set<String> {
        Set(ManagedToolVersionProbe.probedIDs.map(\.rawValue))
    }

    private func lock(_ lock: ManagedToolLock, without id: String) -> ManagedToolLock {
        ManagedToolLock(
            packID: lock.packID, displayName: lock.displayName, version: lock.version,
            tools: lock.tools.filter { $0.id != id }, managedData: lock.managedData,
            packTools: lock.packTools.filter { $0.toolID != id },
            pipelines: lock.pipelines.filter { $0.id != id })
    }

    // MARK: - Agreement

    func testEveryListedToolIsAnEntryOfTheLock() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        XCTAssertFalse(listedTools().isEmpty)
        XCTAssertEqual(notInTheLock(lock), [])
    }

    func testEveryListedToolIsARowOfTheProbeTable() {
        XCTAssertEqual(notInTheProbeTable(probedIDs), [])
    }

    /// The genotyping step helper names three lock entries, and the kinds the pipeline records list them.
    func testTheGenotypingKindsListTheToolsTheDemuxStepsName() throws {
        let stepTools = ["minimap2", "samtools", "pysam"].map { ManagedToolID(rawValue: $0) }
        for raw in ["ont-genotyping", "illumina-amplicon-genotyping", "ont-sample-bundle-genotyping"] {
            let listed = try XCTUnwrap(AnalysisToolRegistry.descriptor(forRawID: raw), raw).runsTools
            for tool in stepTools {
                XCTAssertTrue(listed.contains(tool), "\(raw) lists \(tool.rawValue)")
            }
        }
    }

    // MARK: - Negative controls

    func testRemovingALockEntryIsReported() throws {
        let bundled = try ManagedToolLock.loadFromBundle()
        let damaged = lock(bundled, without: "samtools")
        XCTAssertNil(damaged.entry(id: ManagedToolID(rawValue: "samtools")))

        let missing = notInTheLock(damaged)
        XCTAssertTrue(missing.contains("ont-genotyping:samtools"))
        XCTAssertTrue(missing.contains("minimap2:samtools"))
        XCTAssertTrue(missing.allSatisfy { $0.hasSuffix(":samtools") }, "\(missing)")
    }

    func testRemovingAProbeRowIsReported() {
        let damaged = probedIDs.subtracting(["pysam"])
        XCTAssertEqual(
            notInTheProbeTable(damaged),
            [
                "ont-genotyping:pysam", "illumina-amplicon-genotyping:pysam",
                "ont-sample-bundle-genotyping:pysam",
            ])
    }
}
