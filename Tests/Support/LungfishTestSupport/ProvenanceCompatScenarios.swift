// ProvenanceCompatScenarios.swift - Writer runs behind the captured corpus cases, reusable outside the capture gate
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each scenario runs one of today's writers inside a temporary `.lungfish` project, so the
// bytes it produces are the bytes of the matching captured case. The capture tests call a
// scenario once to freeze its output. A later lane calls the same scenario again after it
// changes the writer, projects the new bytes with `ProvenanceCompatFacts`, and compares them
// with the frozen case's facts, so no lane copies a run and lets it drift.

import Foundation
import LungfishCore
import LungfishWorkflow

public enum ProvenanceCompatScenarios {
    /// A temporary `.lungfish` project that one scenario run writes into.
    public struct Project: Sendable {
        /// The `provenance-compat-scenario-<UUID>` folder that holds everything. Remove it with `cleanup()`.
        public let temporaryRoot: URL
        /// `<temporaryRoot>/<uuid>/Fixture.lungfish`.
        public let root: URL

        public func cleanup() {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        /// A folder below the project, created when it is missing.
        public func folder(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    public static func makeProject() throws -> Project {
        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-compat-scenario")
        let root = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Project(temporaryRoot: temporaryRoot, root: root)
    }

    /// Writes `text` to `url`, creating the folder, and returns the URL.
    @discardableResult
    public static func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: GATK joint genotyping in a container

    /// The container image and digest the GATK scenario runs in. Both are synthetic: the digest
    /// is the SHA-256 of the image reference.
    public static let gatkContainerImage = "quay.io/biocontainers/gatk4:4.6.1.0--py310hdfd78af_0"
    public static let gatkContainerDigest = "sha256:1ba4b39d599432543b3e8812d4c2e533d3431da57050a6e9cfa60a173a91803b"

    /// The folder, relative to the project, that the GATK scenario writes its sidecar into.
    public static let gatkContainerAnalysisFolder = "Analyses/gatk-joint-genotyping"

    /// Runs the real `GATKPipelineExecutor` on a joint genotyping request (CombineGVCFs, then
    /// GenotypeGVCFs) that carries a container image and digest, with an injected runner that writes
    /// the output files. The executor writes the record with `WorkflowRun.writeSidecar`: a bare
    /// run whose two steps each carry `containerImage` and `containerDigest` and no runtime
    /// identity of their own. Returns the sidecar.
    public static func gatkContainerRun(in project: Project) async throws -> URL {
        let analysis = try project.folder(gatkContainerAnalysisFolder)
        let inputs = project.root.appendingPathComponent("Inputs", isDirectory: true)
        let reference = try write(">chr1\nACGTACGTAC\n", to: inputs.appendingPathComponent("reference.fasta"))
        let sampleA = try write("##fileformat=VCFv4.2\n##sample=a\n", to: inputs.appendingPathComponent("sample-a.g.vcf"))
        let sampleB = try write("##fileformat=VCFv4.2\n##sample=b\n", to: inputs.appendingPathComponent("sample-b.g.vcf"))
        let combined = analysis.appendingPathComponent("combined.g.vcf")
        let joint = analysis.appendingPathComponent("joint.vcf")

        let configuration = GATKJointGenotypingConfiguration(
            referenceFASTAURL: reference,
            inputGVCFURLs: [sampleA, sampleB],
            outputVCFURL: joint,
            intermediateURL: combined,
            strategy: .combineGVCFs
        )
        let request = GATKPipelineExecutionRequest.jointGenotype(
            configuration: configuration,
            toolVersion: "4.6.1.0",
            runtimeIdentity: GATKRuntimeIdentity(
                condaEnvironment: nil,
                containerImage: gatkContainerImage,
                containerDigest: gatkContainerDigest
            ),
            packID: "gatk-core",
            packVersion: "1.0.0"
        )
        let runner = GATKScenarioRunner(combined: combined, joint: joint)
        let started = Date(timeIntervalSince1970: 1_790_100_000)
        let executor = GATKPipelineExecutor(runner: runner, dateProvider: { started })
        let result = try await executor.run(request)
        return result.provenanceURL
    }

    /// Stands in for GATK. It writes the file each command would write and returns canned results,
    /// so the executor records a real run without a GATK install.
    private struct GATKScenarioRunner: GATKCommandRunning {
        let combined: URL
        let joint: URL

        func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
            switch command.arguments.first {
            case "CombineGVCFs":
                try Data("##fileformat=VCFv4.2\n##combined=true\n".utf8).write(to: combined)
                return GATKCommandExecutionResult(
                    exitCode: 0,
                    stdout: "",
                    stderr: "Using GATK jar /opt/gatk/gatk-package-4.6.1.0-local.jar",
                    wallTime: 21.5
                )
            default:
                try Data("##fileformat=VCFv4.2\n##joint=true\n".utf8).write(to: joint)
                return GATKCommandExecutionResult(exitCode: 0, stdout: "", stderr: "", wallTime: 40.75)
            }
        }
    }
}
