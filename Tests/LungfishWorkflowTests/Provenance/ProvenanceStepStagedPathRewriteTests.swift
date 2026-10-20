// ProvenanceStepStagedPathRewriteTests.swift - The importer's staged path rewrite keeps every field of a step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P8, plan decision S6. The FASTQ importer records its steps against a hidden staging
// bundle and rewrites each staged path to the published bundle's before it writes the record
// (`FASTQBatchImporter.rewriteStagedBundlePaths`). That rewrite rebuilds every step, and a rebuild that
// names the fields it knows drops each field added later, which is how the record at the bundle root
// could lose the step a sub-step ran under. The test sends a step with every stored property set through
// the rewrite and checks by reflection that each property the rewrite does not change comes out as it
// went in, so a field added to a step is checked here without another edit.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceStepStagedPathRewriteTests: XCTestCase {

    private let staging = URL(
        fileURLWithPath: "/Users/tester/Demo.lungfish/Imports/.S.building-6127824B-F8D3-415B-BECB-69EB777D0EA7",
        isDirectory: true
    )
    private let published = URL(fileURLWithPath: "/Users/tester/Demo.lungfish/Imports/S.lungfishfastq", isDirectory: true)

    /// A step with every stored property set, whose paths name the staging bundle.
    private func fullStep() -> ProvenanceStep {
        let reads = staging.appendingPathComponent("S.fastq.gz").path
        let metadata = reads + ".lungfish-meta.json"
        return ProvenanceStep(
            id: UUID(),
            toolName: "seqkit",
            toolVersion: "2.13.0",
            githubReleaseVersion: "v2.13.0",
            argv: ["seqkit", "stats", "-a", "-T", reads],
            durableReplayArgv: ["seqkit", "stats", "-a", "-T", reads],
            reproducibleCommand: "seqkit stats -a -T \(reads)",
            resolvedOptions: ["input": .file(URL(fileURLWithPath: reads)), "threads": .integer(2)],
            runtimeIdentity: ProvenanceRuntimeIdentity(condaEnvironment: "seqkit", condaPrefix: "/envs/seqkit"),
            inputs: [ProvenanceFileDescriptor(path: reads, role: .input)],
            outputs: [ProvenanceFileDescriptor(path: metadata, role: .output)],
            exitStatus: 0,
            wallTimeSeconds: 1.5,
            peakMemoryBytes: 4_096,
            stderr: "a warning",
            dependsOn: [UUID()],
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            completedAt: Date(timeIntervalSince1970: 1_790_000_002),
            parentStepID: UUID(),
            managedToolID: ManagedToolID(rawValue: "seqkit"),
            toolVersionEvidence: .observed(version: "2.13.0", reportedLine: nil),
            observation: ProvenanceStepObservation(
                termination: .exited(code: 0), stop: nil, outputComplete: true, environment: nil,
                stage: .init(index: 0, count: 1)
            ),
            stdoutReadInProcess: true,
            // Only a `build-db esviritu` sidecar writes it, so no importer record holds one and the rewrite
            // carries it as it is (2.13 lane 13.15 M2).
            narrowedFrom: ProvenanceStepNarrowing(recordPath: "/Users/tester/results/.lungfish-provenance.json", inputCount: 2)
        )
    }

    func testTheFixtureStepSetsEveryStoredProperty() {
        assertEveryPropertyIsSet(in: fullStep())
    }

    /// A rebuilt envelope passes the source's status, since a status it derives from the exit status
    /// cannot tell a cancelled run from a completed one.
    func testTheStagedPathRewriteKeepsTheRecordsStatus() {
        let record = ProvenanceEnvelope(
            workflowName: "lungfish import fastq", toolName: "lungfish-cli", exitStatus: 0, status: .cancelled
        )
        XCTAssertEqual(record.status, .cancelled)
        let rewritten = FASTQBatchImporter.rewriteStagedBundlePaths(in: record, stagingBundleURL: staging, publishedBundleURL: published)
        XCTAssertEqual(rewritten.status, .cancelled)
    }

    func testTheStagedPathRewriteKeepsEveryPropertyItDoesNotRewrite() throws {
        let original = fullStep()
        let record = ProvenanceEnvelope(workflowName: "lungfish import fastq", toolName: "lungfish-cli", steps: [original])
        let rewritten = try XCTUnwrap(
            FASTQBatchImporter.rewriteStagedBundlePaths(in: record, stagingBundleURL: staging, publishedBundleURL: published)
                .steps.first
        )
        assertEveryPropertyCarried(
            rewritten, from: original,
            except: ["durableReplayArgv", "reproducibleCommand", "resolvedOptions", "inputs", "outputs"],
            "FASTQBatchImporter.rewriteStagedBundlePaths"
        )

        // And it did rewrite the paths it exists to rewrite.
        let paths = (rewritten.durableReplayArgv ?? []) + rewritten.inputs.map(\.path) + rewritten.outputs.map(\.path)
        XCTAssertFalse(paths.contains { $0.contains(".building-") }, "\(paths)")
        XCTAssertTrue(rewritten.outputs.first?.path.hasPrefix(published.path) == true)
    }
}
