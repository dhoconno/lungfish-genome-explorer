// NextflowWorkflowsRegistryAgreementTests.swift - Holds each Nextflow workflow descriptor to the registry and the lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9, lane A16 (ARCH 2.1). A Nextflow workflow descriptor names its analysis kind by tool id and its lock
// pipeline by id. IO holds the registry as plain data and cannot read the lock or the descriptors, so this suite
// holds every descriptor's lock pipeline id to the registry's `.lockedPipeline` id of its kind, every locked
// pipeline of the registry to a descriptor, and every descriptor to a pipeline of the lock, the way
// AnalysisRunsToolsAgreementTests holds the tool lists. Each check is a function of the values it compares, so the
// negative controls feed it a damaged copy and the bundled values stay untouched. Pure, so it runs in the unit tier.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class NextflowWorkflowsRegistryAgreementTests: XCTestCase {
    /// Every Nextflow workflow descriptor. A new workflow joins this list with its descriptor.
    private let descriptors: [NextflowWorkflowDescriptor] = [.taxTriage, .viralRecon]

    private func label(_ descriptor: NextflowWorkflowDescriptor) -> String {
        "\(descriptor.toolID.rawValue):\(descriptor.lockPipelineID)"
    }

    /// `kind:pipeline` for every descriptor whose kind the registry lacks, provisions with another locked
    /// pipeline, or lists without `nextflow` among the tools it runs.
    private func disagreeingWithTheRegistry(
        _ descriptors: [NextflowWorkflowDescriptor],
        registry: [AnalysisToolDescriptor] = AnalysisToolRegistry.all
    ) -> Set<String> {
        let nextflow = ManagedToolID(rawValue: "nextflow")
        return Set(descriptors.filter { descriptor in
            guard let row = registry.first(where: { $0.id == descriptor.toolID }) else { return true }
            return row.provisioning != .lockedPipeline(descriptor.lockPipelineID) || !row.runsTools.contains(nextflow)
        }.map(label))
    }

    /// `kind:pipeline` for every registry kind provisioned with a locked pipeline that no descriptor names.
    private func lockedPipelinesWithoutADescriptor(
        _ descriptors: [NextflowWorkflowDescriptor],
        registry: [AnalysisToolDescriptor] = AnalysisToolRegistry.all
    ) -> Set<String> {
        Set(registry.compactMap { row -> String? in
            guard case .lockedPipeline(let id) = row.provisioning else { return nil }
            let described = descriptors.contains { $0.toolID == row.id && $0.lockPipelineID == id }
            return described ? nil : "\(row.id.rawValue):\(id)"
        })
    }

    /// `kind:pipeline` for every descriptor whose lock pipeline `lock` has no entry for.
    private func notInTheLock(_ descriptors: [NextflowWorkflowDescriptor], lock: ManagedToolLock) -> Set<String> {
        Set(descriptors.filter { lock.pipeline(id: $0.lockPipelineID) == nil }.map(label))
    }

    private func descriptor(
        _ descriptor: NextflowWorkflowDescriptor,
        lockPipelineID: String
    ) -> NextflowWorkflowDescriptor {
        NextflowWorkflowDescriptor(
            toolID: descriptor.toolID, lockPipelineID: lockPipelineID, profile: descriptor.profile,
            containerRuntime: descriptor.containerRuntime, releaseEnvironment: descriptor.releaseEnvironment,
            parameterSchemaPath: descriptor.parameterSchemaPath,
            workDirectoryOption: descriptor.workDirectoryOption, traceFileName: descriptor.traceFileName,
            argumentLayout: descriptor.argumentLayout,
            scratchPrefix: descriptor.scratchPrefix, keepWorkEnvironmentKey: descriptor.keepWorkEnvironmentKey,
            expectedTaskCountPerSample: descriptor.expectedTaskCountPerSample,
            finalizeProgressShare: descriptor.finalizeProgressShare)
    }

    private func registry(
        replacing id: AnalysisToolID,
        runsTools: [ManagedToolID]? = nil,
        provisioning: AnalysisToolProvisioning? = nil
    ) -> [AnalysisToolDescriptor] {
        AnalysisToolRegistry.all.map { row in
            guard row.id == id else { return row }
            return AnalysisToolDescriptor(
                id: row.id, displayName: row.displayName, sidebarSymbolName: row.sidebarSymbolName,
                runsTools: runsTools ?? row.runsTools, provisioning: provisioning ?? row.provisioning)
        }
    }

    // MARK: - Agreement

    func testEveryDescriptorNamesTheLockedPipelineOfItsRegistryKind() {
        XCTAssertEqual(disagreeingWithTheRegistry(descriptors), [])
    }

    func testEveryLockedPipelineOfTheRegistryHasADescriptor() {
        XCTAssertEqual(lockedPipelinesWithoutADescriptor(descriptors), [])
    }

    func testEveryDescriptorNamesAPipelineOfTheLock() throws {
        XCTAssertEqual(notInTheLock(descriptors, lock: try ManagedToolLock.loadFromBundle()), [])
        XCTAssertEqual(notInTheLock(descriptors, lock: .bundled), [])
    }

    func testNoTwoDescriptorsShareAKindOrAPipeline() {
        XCTAssertEqual(Set(descriptors.map(\.toolID)).count, descriptors.count)
        XCTAssertEqual(Set(descriptors.map(\.lockPipelineID)).count, descriptors.count)
    }

    // MARK: - Negative controls

    func testADescriptorNamingAnotherPipelineIsReported() {
        let damaged = [descriptor(.taxTriage, lockPipelineID: "taxtriage-main"), .viralRecon]
        XCTAssertEqual(disagreeingWithTheRegistry(damaged), ["taxtriage:taxtriage-main"])
        XCTAssertEqual(lockedPipelinesWithoutADescriptor(damaged), ["taxtriage:taxtriage"])
    }

    func testALockedPipelineWithoutADescriptorIsReported() {
        XCTAssertEqual(lockedPipelinesWithoutADescriptor([.taxTriage]), ["viralrecon:nf-core-viralrecon"])
    }

    func testARegistryRowThatDisagreesIsReported() {
        let container = registry(replacing: .viralrecon, provisioning: .container)
        XCTAssertEqual(disagreeingWithTheRegistry(descriptors, registry: container), ["viralrecon:nf-core-viralrecon"])

        let noNextflow = registry(replacing: .taxtriage, runsTools: [])
        XCTAssertEqual(disagreeingWithTheRegistry(descriptors, registry: noNextflow), ["taxtriage:taxtriage"])

        let noRow = AnalysisToolRegistry.all.filter { $0.id != .viralrecon }
        XCTAssertEqual(disagreeingWithTheRegistry(descriptors, registry: noRow), ["viralrecon:nf-core-viralrecon"])
    }

    func testRemovingALockPipelineIsReported() throws {
        let bundled = try ManagedToolLock.loadFromBundle()
        let damaged = ManagedToolLock(
            packID: bundled.packID, displayName: bundled.displayName, version: bundled.version,
            tools: bundled.tools, managedData: bundled.managedData, packTools: bundled.packTools,
            pipelines: bundled.pipelines.filter { $0.id != "nf-core-viralrecon" })
        XCTAssertEqual(notInTheLock(descriptors, lock: damaged), ["viralrecon:nf-core-viralrecon"])
    }
}
