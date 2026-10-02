// ViralReconAnnotationStagingCLITests.swift - workflow run nf-core/viralrecon hands Nextflow a --gff name the schema accepts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// nf-core/viralrecon 3.0.0 validates `--gff` against `^\S+\.gff(\.gz)?$`.
/// A GFF3 named `.gff3` is copied into the run bundle under a `.gff` name and
/// Nextflow is pointed at the copy, whether the app or a user passed it.
final class ViralReconAnnotationStagingCLITests: XCTestCase {
    private static let gffPattern = #"^\S+\.gff(\.gz)?$"#

    private var root: URL!

    override func setUpWithError() throws {
        // The CLI standardizes every path it records (/var -> /private/var).
        root = try TestTempDirectory.make(prefix: "viralrecon-gff-cli").resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Records each launch with the `--gff` bytes read at launch time, and
    /// creates the results directory the run's expected output names.
    private final class CapturingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
        struct Launch {
            let arguments: [String]
            let gffBytes: Data?

            var gff: String? {
                guard let index = arguments.firstIndex(of: "--gff"), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
        }

        private(set) var launches: [Launch] = []

        func runNextflow(arguments: [String], workingDirectory: URL, environment: [String: String]) async throws -> NFCoreWorkflowProcessResult {
            var gffBytes: Data?
            if let index = arguments.firstIndex(of: "--gff"), index + 1 < arguments.count {
                gffBytes = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            }
            launches.append(Launch(arguments: arguments, gffBytes: gffBytes))
            if let index = arguments.firstIndex(of: "--outdir"), index + 1 < arguments.count {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: arguments[index + 1]),
                    withIntermediateDirectories: true
                )
            }
            return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
        }
    }

    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeGFF3(to url: URL) throws -> URL {
        try write(
            "##gff-version 3\nMN908947.3\tGenbank\tgene\t21563\t25384\t.\t+\t.\tID=gene-S;Name=S\n",
            to: url
        )
    }

    private func samplesheet() throws -> URL {
        try write(
            "sample,fastq_1,fastq_2\nS1,/tmp/S1_R1.fastq.gz,/tmp/S1_R2.fastq.gz\n",
            to: root.appendingPathComponent("samplesheet.csv")
        )
    }

    private func arguments(gff: URL, runBundle: URL, extra: [String] = []) throws -> [String] {
        let results = root.appendingPathComponent("results", isDirectory: true)
        return [
            "nf-core/viralrecon",
            "--executor", "docker",
            "--input", try samplesheet().path,
            "--results-dir", results.path,
            "--expected-output", results.path,
            "--bundle-path", runBundle.path,
            "--version", "3.0.0",
            "--param", "platform=illumina",
            "--param", "gff=\(gff.path)",
            "--quiet",
        ] + extra
    }

    private func run(_ arguments: [String]) async throws -> CapturingNextflowRunner {
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        let runner = CapturingNextflowRunner()
        RunSubcommand.nfCoreWorkflowProcessRunner = runner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }
        try await RunSubcommand.parse(arguments).run()
        return runner
    }

    private func stagingRecord(in runBundle: URL) throws -> [String: ParameterValue]? {
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: runBundle))
        guard case .dictionary(let fields)? = provenance.options.explicit[ViralReconAnnotationStaging.provenanceKey] else {
            return nil
        }
        return fields
    }

    // MARK: - A .gff3 passed straight to the CLI is staged, not refused

    func testGFF3PassedStraightToTheCLIIsStagedUnderAGFFNameBeforeNextflowStarts() async throws {
        let gff3 = try writeGFF3(to: root.appendingPathComponent("annotations/MN908947.3.gff3"))
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let runner = try await run(try arguments(gff: gff3, runBundle: runBundle))

        let launch = try XCTUnwrap(runner.launches.first)
        let staged = runBundle.appendingPathComponent("inputs/reference/MN908947.3.gff")
        XCTAssertEqual(launch.gff, staged.path)
        XCTAssertNotNil(launch.gff?.range(of: Self.gffPattern, options: .regularExpression), launch.gff ?? "no --gff")
        XCTAssertEqual(launch.gffBytes, try Data(contentsOf: gff3), "only the name may change")
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: gff3), "the copy stays with the run")

        // The manifest and the recorded parameters keep the caller's path.
        XCTAssertEqual(try NFCoreRunBundleStore.read(from: runBundle).params["gff"], gff3.path)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: runBundle))
        XCTAssertEqual(provenance.options.explicit["gff"], .string(gff3.path))

        let record = try XCTUnwrap(try stagingRecord(in: runBundle))
        XCTAssertEqual(record["source"], .file(gff3))
        XCTAssertEqual(record["staged"], .file(staged))
        XCTAssertEqual(record["sha256"], .string(try FileDigest.sha256(of: gff3)))
        XCTAssertNil(record["sourceBundle"], "a loose file has no bundle")
        XCTAssertNil(record["sourceBundleRelativePath"])
    }

    // MARK: - The staged name survives the whitespace staging a project path needs

    func testBundleGFF3UnderAProjectPathWithSpacesReachesNextflowAsAGFFPath() async throws {
        let project = root.appendingPathComponent("My Genome Project.lungfish", isDirectory: true)
        let referenceBundle = project.appendingPathComponent("Downloads/MN908947.3.lungfishref", isDirectory: true)
        let gff3 = try writeGFF3(to: referenceBundle.appendingPathComponent("genome/genes.gff3"))
        let runBundle = project.appendingPathComponent("Analyses/viralrecon.lungfishrun", isDirectory: true)

        let runner = try await run(try arguments(gff: gff3, runBundle: runBundle))

        let launch = try XCTUnwrap(runner.launches.first)
        XCTAssertNotNil(launch.gff?.range(of: Self.gffPattern, options: .regularExpression), launch.gff ?? "no --gff")
        XCTAssertEqual(launch.gffBytes, try Data(contentsOf: gff3))

        let record = try XCTUnwrap(try stagingRecord(in: runBundle))
        XCTAssertEqual(record["staged"], .file(runBundle.appendingPathComponent("inputs/reference/genes.gff")))
        XCTAssertEqual(record["sourceBundle"], .file(referenceBundle))
        XCTAssertEqual(record["sourceBundleRelativePath"], .string("genome/genes.gff3"))
    }

    // MARK: - A missing annotation is refused before anything launches

    func testMissingGFF3IsRefusedBeforeNextflowStarts() async throws {
        let missing = root.appendingPathComponent("annotations/absent.gff3")
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
        let originalRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        let runner = CapturingNextflowRunner()
        RunSubcommand.nfCoreWorkflowProcessRunner = runner
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalRunner }

        do {
            try await RunSubcommand.parse(try arguments(gff: missing, runBundle: runBundle)).run()
            XCTFail("a missing annotation must be refused")
        } catch let error as CLIError {
            XCTAssertTrue(error.localizedDescription.contains(missing.path), error.localizedDescription)
            XCTAssertEqual(error.exitCode, .inputError)
        }
        XCTAssertTrue(runner.launches.isEmpty, "Nextflow must not start")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runBundle.appendingPathComponent("manifest.json").path))
    }

    // MARK: - Names the schema already accepts are launched as given

    func testGFFNameIsLaunchedAsGiven() async throws {
        let gff = try writeGFF3(to: root.appendingPathComponent("annotations/MN908947.3.gff"))
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let runner = try await run(try arguments(gff: gff, runBundle: runBundle))

        XCTAssertEqual(try XCTUnwrap(runner.launches.first).gff, gff.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runBundle.appendingPathComponent("inputs/reference").path))
        XCTAssertNil(try stagingRecord(in: runBundle))
    }

    // MARK: - Only viralrecon's gff is renamed

    /// `workflow run` accepts only nf-core/viralrecon today, so another
    /// pipeline cannot reach the launch through `RunSubcommand`. The launch
    /// staging step is checked directly with the same parameters under both
    /// workflow identities.
    func testAnotherWorkflowsGFFPassesThroughUnchangedAndUnstaged() throws {
        let gff3 = try writeGFF3(to: root.appendingPathComponent("annotations/genes.gff3"))
        let runBundle = root.appendingPathComponent("other.lungfishrun", isDirectory: true)
        let other = NFCoreSupportedWorkflow(
            name: "rnaseq",
            displayName: "RNA-seq",
            description: "Another nf-core pipeline with a gff parameter",
            pinnedVersion: "3.14.0",
            whenToUse: "",
            notFor: "",
            requiredInputs: "",
            expectedOutputs: "",
            exampleUseCase: "",
            runButtonTitle: "Run",
            acceptedInputSuffixes: [".csv"],
            difficulty: .moderate,
            resultSurfaces: [.reports]
        )
        func request(for workflow: NFCoreSupportedWorkflow) throws -> NFCoreRunRequest {
            NFCoreRunRequest(
                workflow: workflow,
                version: workflow.pinnedVersion,
                executor: .docker,
                inputURLs: [try samplesheet()],
                outputDirectory: root.appendingPathComponent("results", isDirectory: true),
                params: ["gff": gff3.path]
            )
        }

        let otherRequest = try request(for: other)
        XCTAssertNil(try NFCoreLaunchStaging.stageAnnotation(for: otherRequest, runBundleURL: runBundle))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: runBundle.appendingPathComponent("inputs/reference").path),
            "nothing is staged for another workflow"
        )
        let launched = otherRequest.replacing(params: ViralReconAnnotationStaging.launchParams(otherRequest.params, using: nil))
        let gffIndex = try XCTUnwrap(launched.nextflowArguments.firstIndex(of: "--gff"))
        XCTAssertEqual(launched.nextflowArguments[gffIndex + 1], gff3.path, "another workflow's gff reaches Nextflow as given")

        // The same parameters under viralrecon are staged, so the workflow identity decides.
        let viralrecon = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon"))
        let staged = try XCTUnwrap(try NFCoreLaunchStaging.stageAnnotation(for: try request(for: viralrecon), runBundleURL: runBundle))
        XCTAssertEqual(staged.stagedURL.lastPathComponent, "genes.gff")
    }

    // MARK: - A prepared bundle already holds the copy it will launch with

    func testPrepareOnlyStagesAndRecordsTheAnnotation() async throws {
        let gff3 = try writeGFF3(to: root.appendingPathComponent("annotations/MN908947.3.gff3.gz"))
        let runBundle = root.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)

        let runner = try await run(try arguments(gff: gff3, runBundle: runBundle, extra: ["--prepare-only"]))

        XCTAssertTrue(runner.launches.isEmpty)
        let staged = runBundle.appendingPathComponent("inputs/reference/MN908947.3.gff.gz")
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: gff3))
        XCTAssertEqual(try XCTUnwrap(try stagingRecord(in: runBundle))["staged"], .file(staged))
    }
}
