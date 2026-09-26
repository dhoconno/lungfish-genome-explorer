// AnalysisTemplateRunnerTests.swift - Preflight, execution order and run record for templates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class AnalysisTemplateRunnerTests: XCTestCase {

    // MARK: - Fake executor

    /// Pretends to be `lungfish-cli`: creates the files each step would leave
    /// behind and records the argv it was given.
    private final class FakeExecutor: AnalysisTemplateStepExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var executed: [RenderedTemplateStep] = []
        var kraken2ToolVersion = "2.17.1"
        var brackenToolVersion: String? = "3.0.1"
        var failStep: RenderedTemplateStepKind?
        var reportBundlePathInJSON = true

        private func record(_ step: RenderedTemplateStep) {
            lock.withLock { executed.append(step) }
        }

        func execute(_ step: RenderedTemplateStep, workingDirectory: URL) async throws -> AnalysisTemplateStepResult {
            record(step)
            if failStep == step.kind {
                return AnalysisTemplateStepResult(exitCode: 3, standardOutput: "", standardError: "simulated failure")
            }
            switch step.kind {
            case .importFASTQ:
                let bundleURL = step.expectedOutputURL
                let name = bundleURL.deletingPathExtension().lastPathComponent
                try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: bundleURL.appendingPathComponent("\(name).fastq"))
                try Data("{\"workflowName\":\"lungfish import fastq\"}".utf8)
                    .write(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
                let stdout = reportBundlePathInJSON
                    ? "{\"event\":\"sampleStart\",\"sample\":\"\(name)\"}\n{\"event\":\"sampleComplete\",\"sample\":\"\(name)\",\"bundle\":\"\(bundleURL.path)\",\"durationSeconds\":1}\n"
                    : "Imported \(name)\n"
                return AnalysisTemplateStepResult(exitCode: 0, standardOutput: stdout, standardError: "")
            case .kraken2:
                let outputIndex = try XCTUnwrap(step.arguments.firstIndex(of: "--output-dir"))
                let outputURL = URL(fileURLWithPath: step.arguments[outputIndex + 1])
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                var sidecar: [String: Any] = [
                    "config": [
                        "confidence": 0.5, "databaseName": "Viral", "databasePath": "database",
                        "goal": "profile", "inputFiles": ["source.fastq"], "isPairedEnd": false,
                        "memoryMapping": false, "minimumHitGroups": 3, "outputDirectory": ".",
                        "quickMode": false, "threads": 4,
                    ],
                    "outputPath": "classification.kraken",
                    "reportPath": "classification.kreport",
                    "runtime": 1.0,
                    "savedAt": "2026-09-26T00:00:00Z",
                    "toolVersion": kraken2ToolVersion,
                ]
                if let brackenToolVersion {
                    sidecar["profileOutcome"] = ["state": "completed", "toolVersion": brackenToolVersion]
                }
                try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
                    .write(to: outputURL.appendingPathComponent("classification-result.json"))
                return AnalysisTemplateStepResult(exitCode: 0, standardOutput: "Kraken2 done\n", standardError: "")
            }
        }
    }

    // MARK: - Helpers

    private var recipe: Recipe { AnalysisTemplateTestFixture.sampleRecipe }

    private func makeTemplate(recipe: Recipe? = nil, databaseVersion: String = "20260626", digest: String? = nil) throws -> AnalysisTemplate {
        AnalysisTemplate(
            name: "Kraken2 from S",
            origin: AnalysisTemplate.Origin(appVersion: "test", sourceAnalysisRelativePath: "Analyses/kraken2-x"),
            input: AnalysisTemplate.InputSpec(platform: .illumina, pairing: .paired),
            steps: [
                .importFASTQ(ImportFASTQStepSpec(
                    platform: .illumina,
                    pairing: .paired,
                    qualityBinning: .illumina4,
                    optimizeStorage: true,
                    clumpingTool: .auto,
                    compressionLevel: .balanced,
                    recipe: try recipe.map { try RecipeSnapshot(recipe: $0) }
                )),
                .kraken2(Kraken2StepSpec(
                    goal: .profile,
                    database: Kraken2StepSpec.DatabaseIdentity(name: "Viral", version: databaseVersion, catalogID: "kraken2-viral", digest: digest),
                    readFormat: .interleaved,
                    confidence: 0.5,
                    minimumHitGroups: 3,
                    memoryMapping: false,
                    quickMode: false,
                    bracken: .automaticDefault,
                    recordedKraken2Version: "2.17.1",
                    recordedBrackenVersion: "3.0.1"
                )),
            ]
        )
    }

    private struct Workspace {
        let root: URL
        let projectURL: URL
        let inputs: [URL]
        func cleanup() { TestTempDirectory.cleanup(root) }
    }

    private func makeWorkspace() throws -> Workspace {
        let root = try TestTempDirectory.make(prefix: "template-runner")
        let projectURL = root.appendingPathComponent("Run.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let r1 = root.appendingPathComponent("S2_R1.fastq")
        let r2 = root.appendingPathComponent("S2_R2.fastq")
        try Data("@a/1\nACGT\n+\n!!!!\n".utf8).write(to: r1)
        try Data("@a/2\nACGT\n+\n!!!!\n".utf8).write(to: r2)
        return Workspace(root: root, projectURL: projectURL, inputs: [r1, r2])
    }

    private func makeRunner(
        executor: FakeExecutor,
        installedRecipe: Recipe?,
        database: AnalysisTemplateDatabaseStatus?
    ) -> AnalysisTemplateRunner {
        AnalysisTemplateRunner(
            executor: executor,
            recipeResolver: { id in installedRecipe?.id == id ? installedRecipe : nil },
            databaseResolver: { _ in database },
            provenanceWriter: ProvenanceWriter(signingProvider: nil)
        )
    }

    private let readyDatabase = AnalysisTemplateDatabaseStatus(
        isReady: true,
        version: "20260626",
        digest: nil,
        path: URL(fileURLWithPath: "/dbs/viral")
    )

    // MARK: - Tests

    func testRunExecutesStepsInOrderBindsBundleAndWritesRunRecord() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let template = try makeTemplate(recipe: recipe)
        let executor = FakeExecutor()
        let runner = makeRunner(executor: executor, installedRecipe: recipe, database: readyDatabase)

        let result = try await runner.run(AnalysisTemplateRunRequest(
            template: template,
            inputs: workspace.inputs,
            projectURL: workspace.projectURL,
            sampleName: "S2",
            threads: 3
        ))

        XCTAssertEqual(executor.executed.map(\.kind), [.importFASTQ, .kraken2])
        XCTAssertEqual(executor.executed[0].arguments.prefix(2), ["import", "fastq"])
        XCTAssertTrue(executor.executed[0].arguments.contains("--recipe"))
        XCTAssertEqual(executor.executed[1].arguments.last, result.importBundleURL.path)
        XCTAssertEqual(result.importBundleURL.path, workspace.projectURL.appendingPathComponent("Imports/S2.lungfishfastq").path)
        XCTAssertEqual(result.analysisDirectoryURL.deletingLastPathComponent().lastPathComponent, "Analyses")
        XCTAssertTrue(result.analysisDirectoryURL.lastPathComponent.hasPrefix("kraken2-"))
        XCTAssertEqual(AnalysesFolder.readAnalysisMetadata(from: result.analysisDirectoryURL)?.tool, "kraken2")
        XCTAssertTrue(result.warnings.isEmpty, "no drift expected: \(result.warnings)")

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: result.runRecordURL))
        XCTAssertEqual(record.workflowName, AnalysisTemplate.runWorkflowName)
        XCTAssertEqual(record.exitStatus, 0)
        XCTAssertEqual(record.options.explicit["templateID"]?.stringValue, template.id.uuidString)
        XCTAssertEqual(record.options.explicit["templateSHA256"]?.stringValue, try template.sha256())
        XCTAssertEqual(record.options.explicit["sampleName"]?.stringValue, "S2")
        XCTAssertEqual(record.options.explicit["threads"]?.integerValue, 3)
        XCTAssertEqual(record.options.resolvedDefaults["importBundle"]?.fileValue?.path, result.importBundleURL.path)
        XCTAssertEqual(record.options.resolvedDefaults["analysisDirectory"]?.fileValue?.path, result.analysisDirectoryURL.path)
        XCTAssertEqual(record.steps.map(\.toolName), ["lungfish-cli import fastq", "lungfish-cli conda classify"])
        XCTAssertEqual(record.steps.map(\.exitStatus), [0, 0])
        XCTAssertTrue(record.outputs.contains { $0.path.hasSuffix("S2.lungfishfastq/\(ProvenanceRecorder.provenanceFilename)") })
        XCTAssertTrue(record.outputs.contains { $0.path.hasSuffix("classification-result.json") })
        XCTAssertTrue(record.files.contains { $0.path.hasSuffix("S2_R1.fastq") })
        XCTAssertEqual(record.argv.prefix(4), ["lungfish-cli", "workflow", "template", "run"])
    }

    func testBundlePathFallsBackToExpectedLocationWithoutJSONEvent() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let executor = FakeExecutor()
        executor.reportBundlePathInJSON = false
        let runner = makeRunner(executor: executor, installedRecipe: nil, database: readyDatabase)

        let result = try await runner.run(AnalysisTemplateRunRequest(
            template: try makeTemplate(),
            inputs: workspace.inputs,
            projectURL: workspace.projectURL
        ))
        XCTAssertEqual(result.importBundleURL.lastPathComponent, "S2.lungfishfastq")
    }

    func testRecipeHashMismatchRefusesUnlessDriftAllowed() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        var changed = recipe
        changed.steps.append(RecipeStep(type: "fastp-trim", label: "Trim", params: nil))
        let executor = FakeExecutor()
        let runner = makeRunner(executor: executor, installedRecipe: changed, database: readyDatabase)
        let template = try makeTemplate(recipe: recipe)

        let strict = AnalysisTemplateRunRequest(template: template, inputs: workspace.inputs, projectURL: workspace.projectURL)
        let report = await runner.preflight(strict)
        XCTAssertFalse(report.isRunnable)
        XCTAssertTrue(report.blockingIssues.contains { $0.contains("has changed since this template was made") })
        do {
            _ = try await runner.run(strict)
            XCTFail("expected refusal")
        } catch let error as AnalysisTemplateRunError {
            guard case .preflightFailed(let issues) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(issues.count, 1)
        }
        XCTAssertTrue(executor.executed.isEmpty, "nothing may run after a refusal")

        var lenient = strict
        lenient.allowDrift = true
        let result = try await runner.run(lenient)
        XCTAssertTrue(result.warnings.contains { $0.contains("has changed since this template was made") })
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: result.runRecordURL))
        XCTAssertEqual(record.options.explicit["allowDrift"]?.booleanValue, true)
        let recorded = record.options.resolvedDefaults["driftWarnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertTrue(recorded.contains { $0.contains("has changed since this template was made") })
    }

    func testMissingRecipeIsBlockingEvenWithDriftAllowed() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let runner = makeRunner(executor: FakeExecutor(), installedRecipe: nil, database: readyDatabase)
        var request = AnalysisTemplateRunRequest(template: try makeTemplate(recipe: recipe), inputs: workspace.inputs, projectURL: workspace.projectURL)
        request.allowDrift = true
        let report = await runner.preflight(request)
        XCTAssertTrue(report.blockingIssues.contains { $0.contains("is not installed") })
    }

    func testUncapturedRecipeSnapshotNeedsDriftAllowance() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        var template = try makeTemplate()
        template.steps[0] = .importFASTQ(ImportFASTQStepSpec(
            platform: .illumina, pairing: .paired, qualityBinning: .none, optimizeStorage: true,
            clumpingTool: .auto, compressionLevel: .balanced,
            recipe: RecipeSnapshot(id: recipe.id, name: recipe.name)
        ))
        let runner = makeRunner(executor: FakeExecutor(), installedRecipe: recipe, database: readyDatabase)
        let strict = await runner.preflight(AnalysisTemplateRunRequest(template: template, inputs: workspace.inputs, projectURL: workspace.projectURL))
        XCTAssertTrue(strict.blockingIssues.contains { $0.contains("was not captured") })
        let lenient = await runner.preflight(AnalysisTemplateRunRequest(template: template, inputs: workspace.inputs, projectURL: workspace.projectURL, allowDrift: true))
        XCTAssertTrue(lenient.isRunnable)
        XCTAssertTrue(lenient.warnings.contains { $0.contains("was not captured") })
    }

    func testMissingDatabaseRefusesRegardlessOfDrift() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let runner = makeRunner(executor: FakeExecutor(), installedRecipe: nil, database: nil)
        let report = await runner.preflight(AnalysisTemplateRunRequest(
            template: try makeTemplate(), inputs: workspace.inputs, projectURL: workspace.projectURL, allowDrift: true
        ))
        XCTAssertEqual(report.blockingIssues, ["Kraken2 database \"Viral\" is not installed on this Mac."])

        let notReady = AnalysisTemplateDatabaseStatus(isReady: false, version: "20260626", digest: nil, path: nil)
        let runner2 = makeRunner(executor: FakeExecutor(), installedRecipe: nil, database: notReady)
        let report2 = await runner2.preflight(AnalysisTemplateRunRequest(template: try makeTemplate(), inputs: workspace.inputs, projectURL: workspace.projectURL))
        XCTAssertFalse(report2.isRunnable)
    }

    func testDatabaseVersionMismatchRefusesUnlessDriftAllowed() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let newer = AnalysisTemplateDatabaseStatus(isReady: true, version: "20270101", digest: nil, path: URL(fileURLWithPath: "/dbs/viral"))
        let runner = makeRunner(executor: FakeExecutor(), installedRecipe: nil, database: newer)
        let template = try makeTemplate()

        let strict = await runner.preflight(AnalysisTemplateRunRequest(template: template, inputs: workspace.inputs, projectURL: workspace.projectURL))
        XCTAssertEqual(strict.blockingIssues.count, 1)
        XCTAssertTrue(strict.blockingIssues[0].contains("is version 20270101 on this Mac. The template used 20260626."))

        let lenient = await runner.preflight(AnalysisTemplateRunRequest(template: template, inputs: workspace.inputs, projectURL: workspace.projectURL, allowDrift: true))
        XCTAssertTrue(lenient.isRunnable)
        XCTAssertTrue(lenient.warnings.contains { $0.contains("Taxon assignments can change") })
    }

    func testUnknownRecordedDatabaseVersionWarnsOnly() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let runner = makeRunner(executor: FakeExecutor(), installedRecipe: nil, database: readyDatabase)
        let report = await runner.preflight(AnalysisTemplateRunRequest(
            template: try makeTemplate(databaseVersion: Kraken2StepSpec.DatabaseIdentity.unknownVersion),
            inputs: workspace.inputs, projectURL: workspace.projectURL
        ))
        XCTAssertTrue(report.isRunnable)
        XCTAssertTrue(report.warnings.contains { $0.contains("was not recorded") })
    }

    func testDigestMismatchRefusesUnlessDriftAllowed() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let installed = AnalysisTemplateDatabaseStatus(isReady: true, version: "20260626", digest: "sha256:new", path: URL(fileURLWithPath: "/dbs/viral"))
        let runner = makeRunner(executor: FakeExecutor(), installedRecipe: nil, database: installed)
        let template = try makeTemplate(digest: "sha256:old")
        let strict = await runner.preflight(AnalysisTemplateRunRequest(template: template, inputs: workspace.inputs, projectURL: workspace.projectURL))
        XCTAssertTrue(strict.blockingIssues.contains { $0.contains("payload digest") })
        let lenient = await runner.preflight(AnalysisTemplateRunRequest(template: template, inputs: workspace.inputs, projectURL: workspace.projectURL, allowDrift: true))
        XCTAssertTrue(lenient.isRunnable)
    }

    func testInputCountAndMissingFilesBlock() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let runner = makeRunner(executor: FakeExecutor(), installedRecipe: nil, database: readyDatabase)
        let report = await runner.preflight(AnalysisTemplateRunRequest(
            template: try makeTemplate(),
            inputs: [workspace.inputs[0], workspace.root.appendingPathComponent("missing.fastq"), workspace.inputs[1]],
            projectURL: workspace.projectURL
        ))
        XCTAssertEqual(report.blockingIssues.count, 2)
        XCTAssertTrue(report.blockingIssues[0].contains("3 were given"))
        XCTAssertTrue(report.blockingIssues[1].contains("missing.fastq"))
    }

    func testToolVersionDriftIsRecordedAfterTheRun() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let executor = FakeExecutor()
        executor.kraken2ToolVersion = "2.18.0"
        executor.brackenToolVersion = "3.1.0"
        let runner = makeRunner(executor: executor, installedRecipe: nil, database: readyDatabase)
        let result = try await runner.run(AnalysisTemplateRunRequest(template: try makeTemplate(), inputs: workspace.inputs, projectURL: workspace.projectURL))
        XCTAssertTrue(result.warnings.contains("Ran with Kraken2 2.18.0; the template recorded 2.17.1. Results may differ slightly."))
        XCTAssertTrue(result.warnings.contains("Ran with Bracken 3.1.0; the template recorded 3.0.1. Results may differ slightly."))
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: result.runRecordURL))
        let recorded = record.options.resolvedDefaults["driftWarnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertEqual(recorded.count, 2)
    }

    func testFailedStepStopsTheRunAndWritesFailedRecord() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let executor = FakeExecutor()
        executor.failStep = .importFASTQ
        let runner = makeRunner(executor: executor, installedRecipe: nil, database: readyDatabase)
        do {
            _ = try await runner.run(AnalysisTemplateRunRequest(template: try makeTemplate(), inputs: workspace.inputs, projectURL: workspace.projectURL))
            XCTFail("expected failure")
        } catch let error as AnalysisTemplateRunError {
            XCTAssertEqual(error, .stepFailed(step: "Import FASTQ", exitCode: 3, detail: "simulated failure"))
        }
        XCTAssertEqual(executor.executed.map(\.kind), [.importFASTQ])

        let analyses = try FileManager.default.contentsOfDirectory(at: workspace.projectURL.appendingPathComponent("Analyses"), includingPropertiesForKeys: nil)
        let recordURL = try XCTUnwrap(analyses.first).appendingPathComponent(AnalysisTemplateRunner.runRecordFilename)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: recordURL))
        XCTAssertEqual(record.exitStatus, 1)
        XCTAssertEqual(record.options.resolvedDefaults["failure"]?.stringValue, "Import FASTQ failed with exit code 3: simulated failure")
        XCTAssertEqual(record.steps.map(\.exitStatus), [3])
    }

    func testDryRunRendersWithoutTouchingTheProject() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let executor = FakeExecutor()
        let runner = makeRunner(executor: executor, installedRecipe: nil, database: readyDatabase)
        let (report, steps) = try await runner.dryRun(AnalysisTemplateRunRequest(template: try makeTemplate(), inputs: workspace.inputs, projectURL: workspace.projectURL))
        XCTAssertTrue(report.isRunnable)
        XCTAssertEqual(steps.map(\.kind), [.importFASTQ, .kraken2])
        XCTAssertTrue(executor.executed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.projectURL.appendingPathComponent("Analyses").path))
    }

    func testImportedBundlePathParsing() {
        let output = """
        Some banner
        {"event":"sampleStart","sample":"S"}
        {"event":"sampleComplete","sample":"S","bundle":"/p/Imports/S.lungfishfastq","durationSeconds":2}
        """
        XCTAssertEqual(AnalysisTemplateRunner.importedBundlePath(fromImportOutput: output), "/p/Imports/S.lungfishfastq")
        XCTAssertNil(AnalysisTemplateRunner.importedBundlePath(fromImportOutput: "nothing here"))
    }
}
