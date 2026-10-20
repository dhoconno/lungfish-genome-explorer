// Kraken2RunRecordOptionsTests.swift - The record facts a Kraken2 root record keeps from the pipeline and the command line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The facts the `conda classify` wrapper record pinned in `CLIRegressionTests` before 2.7, now
/// made by `Kraken2RunRecordOptions` for the executor's root record (lane A8).
final class Kraken2RunRecordOptionsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken2-record-options")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testThePipelinesStepsFollowItsKraken2StepAndKeepItsExactBrackenStep() throws {
        let made = try result(withBracken: true)
        let copy = step("Lungfish Classification Replay Input Materialization", outputs: [])
        let kraken = step("kraken2", outputs: [made.result.reportURL], dependsOn: [copy.id])
        let bracken = step("bracken", outputs: [made.brackenURL], dependsOn: [kraken.id])
        let sidecar = step("Lungfish Classification Result Sidecar", outputs: [], dependsOn: [bracken.id])
        let envelope = pipelineEnvelope(steps: [copy, kraken, bracken, sidecar], outputs: [made.result.reportURL])

        let steps = try Kraken2RunRecordOptions.steps(
            for: made.result,
            pipelineEnvelope: envelope,
            executionInputs: [],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 110)
        )

        XCTAssertEqual(steps.map(\.id), [kraken.id, copy.id, bracken.id, sidecar.id])
        XCTAssertEqual(steps[2], bracken, "the pipeline's own Bracken step, exactly")
        XCTAssertEqual(steps[3].dependsOn, [bracken.id])
    }

    func testAKraken2StepIsMadeFromTheResultWhenThePipelineLeftNoRecordOfThisRun() throws {
        let made = try result(withBracken: false)
        let other = pipelineEnvelope(steps: [step("kraken2", outputs: [])], outputs: [root.appendingPathComponent("elsewhere.kreport")])

        let steps = try Kraken2RunRecordOptions.steps(
            for: made.result,
            pipelineEnvelope: other,
            executionInputs: [],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 110)
        )

        XCTAssertEqual(steps.map(\.toolName), ["kraken2"])
        XCTAssertEqual(steps[0].argv, ["kraken2"] + made.result.config.kraken2Arguments())
        XCTAssertEqual(steps[0].outputs.map(\.path), [made.result.reportURL.path, made.result.config.outputURL.path])
    }

    func testOnlyTheOptionsGivenAreExplicitAndTheDefaultsAreTheCommandsOwn() throws {
        let made = try result(withBracken: false)
        let request = Kraken2RunRequest(inputArguments: ["reads.fastq"], databaseName: "Viral", confidence: 0.3)
        let argv = ["lungfish-cli", "kraken2", "classify", "reads.fastq", "--db", "Viral", "--confidence", "0.3"]

        let options = Kraken2RunRecordOptions.rootOptions(
            config: made.result.config,
            outcome: .notRequested,
            request: request,
            argv: argv,
            originalInputURLs: made.result.config.inputFiles,
            executionInputURLs: made.result.config.inputFiles
        )

        XCTAssertEqual(Set(options.explicit.keys), ["databaseName", "originalInputs", "confidence"])
        XCTAssertNil(options.defaults["preset"])
        XCTAssertEqual(options.defaults["threads"], .integer(4))
        XCTAssertEqual(options.defaults["readFormat"], .string("auto"))
        XCTAssertNil(options.resolved["preset"])
        XCTAssertNil(options.readSetPlan, "single reads record no read-set plan")
    }

    /// 2.13 lane 13.15, SW26 note 2. A typed `--read-format auto` is the explicit `auto` the user gave, and the format
    /// the run resolved stays a resolved option.
    func testATypedAutoReadFormatIsRecordedAsTheChoiceGiven() throws {
        let made = try result(withBracken: false)
        let request = Kraken2RunRequest(inputArguments: ["reads.fastq"], databaseName: "Viral")
        let argv = ["lungfish-cli", "kraken2", "classify", "reads.fastq", "--db", "Viral", "--read-format", "auto"]

        let options = Kraken2RunRecordOptions.rootOptions(
            config: made.result.config,
            outcome: .notRequested,
            request: request,
            argv: argv,
            originalInputURLs: made.result.config.inputFiles,
            executionInputURLs: made.result.config.inputFiles
        )

        XCTAssertEqual(request.readFormat, .auto)
        XCTAssertEqual(options.explicit["readFormat"], .string("auto"))
        XCTAssertEqual(options.resolved["readFormat"], .string(made.result.config.readFormat.rawValue))
        XCTAssertNotEqual(made.result.config.readFormat.rawValue, "auto", "the run resolved a format")
    }

    /// B16. The pipeline writes the read-set plan under the resolved options itself, so the convergence changes
    /// the defaults and moves no plan. A plan that an earlier build filed among the explicit options stays there,
    /// and the one reader still finds it.
    func testConvergingASampleLeavesTheReadSetPlanWhereTheRecordHoldsIt() {
        let key = AnalysisRootRecordOptions.readSetPlanKey
        let plan = ParameterValue.dictionary(["capability": .string("pairsOrSinglesPerRun"), "runs": .integer(2)])

        let current = Kraken2RunRecordOptions.convergedSampleOptions(ProvenanceOptions(
            explicit: ["databaseName": .string("Viral")],
            defaults: ["readFormat": .string("unpaired"), "preset": .string("balanced")],
            resolvedDefaults: [key: plan]
        ))
        XCTAssertEqual(current.resolvedDefaults[key], plan)
        XCTAssertNil(current.explicit[key])
        XCTAssertEqual(current.defaults["readFormat"], .string("auto"), "the defaults still converge")
        XCTAssertNil(current.defaults["preset"])

        let earlier = Kraken2RunRecordOptions.convergedSampleOptions(ProvenanceOptions(explicit: [key: plan]))
        XCTAssertEqual(earlier.explicit[key], plan, "an earlier layout keeps its home")
        XCTAssertNil(earlier.resolvedDefaults[key])
        XCTAssertEqual(
            ProvenanceEnvelope(workflowName: "fixture", toolName: "kraken2", toolVersion: "2.1.3", options: earlier).readSetPlan?.place,
            .explicitOptions
        )
    }

    /// 2.12 lane 12.26, B5 (BIO 3 and 4). The CLI writes the same record as the wizard. A ready Standard-8 row that
    /// nothing checked (the catalog identity and the catalog's version, no payload digest) records no version and no
    /// digest. The same row with a payload digest records the catalog's version and that digest.
    func testMakeConfigGivesAnUnverifiedDatabaseNoVersionAndACheckedOneItsVersion() throws {
        let catalogID = "kraken2-standard-8"
        let version = try XCTUnwrap(MetagenomicsDatabaseInfo.catalogEntry(catalogID: catalogID)?.version)
        let databasePath = root.appendingPathComponent("db", isDirectory: true)
        var row = MetagenomicsDatabaseInfo(
            name: "Standard-8", tool: MetagenomicsTool.kraken2.rawValue, version: version, sizeBytes: 1024,
            catalogID: catalogID, description: "Adopted from a folder", collection: .standard8,
            path: databasePath, status: .ready, recommendedRAM: 1024
        )
        let request = Kraken2RunRequest(inputArguments: ["reads.fastq"], databaseName: "Standard-8", confidence: 0.3)
        func config(for database: MetagenomicsDatabaseInfo) -> ClassificationConfig {
            request.makeConfig(
                inputURLs: [root.appendingPathComponent("reads.fastq")],
                readFormat: Kraken2ResolvedReadFormat(format: .unpaired, layout: nil),
                databaseInfo: database, databasePath: databasePath, inputFormat: .fastq,
                outputDirectory: root, extraArguments: []
            )
        }

        let unverified = config(for: row)
        XCTAssertEqual(unverified.databaseVersion, "unknown")
        XCTAssertNil(unverified.databaseDigest)

        row.payloadDigest = "sha256:payload-fixture"
        let checked = config(for: row)
        XCTAssertEqual(checked.databaseVersion, version)
        XCTAssertEqual(checked.databaseDigest, "sha256:payload-fixture")
    }

    // MARK: - Helpers

    private func result(withBracken: Bool) throws -> (result: ClassificationResult, brackenURL: URL) {
        let input = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
        let database = root.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let config = ClassificationConfig(
            goal: withBracken ? .profile : .classify,
            inputFiles: [input],
            isPairedEnd: false,
            databaseName: "Viral",
            databaseVersion: "2026.1",
            databasePath: database,
            confidence: 0.2,
            outputDirectory: root
        )
        try "100.00\t1\t1\tR\t1\troot\n".write(to: config.reportURL, atomically: true, encoding: .utf8)
        try "C\tr1\t1\t4\t1:4\n".write(to: config.outputURL, atomically: true, encoding: .utf8)
        let brackenURL = config.brackenURL
        if withBracken { try "name\n".write(to: brackenURL, atomically: true, encoding: .utf8) }
        let result = ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: config.reportURL),
            reportURL: config.reportURL,
            outputURL: config.outputURL,
            brackenURL: withBracken ? brackenURL : nil,
            profileOutcome: .notRequested,
            runtime: 1,
            toolVersion: "2.17.1",
            provenanceId: nil
        )
        return (result, brackenURL)
    }

    private func step(_ name: String, outputs: [URL], dependsOn: [UUID] = []) -> ProvenanceStep {
        ProvenanceStep(
            toolName: name,
            toolVersion: "1",
            argv: [name],
            outputs: outputs.compactMap { try? ProvenanceFileDescriptor.file(url: $0, format: .text, role: .output) },
            exitStatus: 0,
            wallTimeSeconds: 1,
            dependsOn: dependsOn,
            startedAt: Date(timeIntervalSince1970: 100),
            completedAt: Date(timeIntervalSince1970: 101)
        )
    }

    private func pipelineEnvelope(steps: [ProvenanceStep], outputs: [URL]) -> ProvenanceEnvelope {
        let descriptors = outputs.map {
            ProvenanceFileDescriptor(path: $0.path, checksumSHA256: String(repeating: "0", count: 64), fileSize: 1, format: .text, role: .report)
        }
        return ProvenanceEnvelope(
            workflowName: "Metagenomics Profiling",
            workflowVersion: "1",
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2"],
            runtimeIdentity: ProvenanceRuntimeIdentity(appVersion: "1"),
            files: descriptors,
            output: descriptors.first,
            outputs: descriptors,
            steps: steps,
            wallTimeSeconds: 1,
            exitStatus: 0
        )
    }
}
