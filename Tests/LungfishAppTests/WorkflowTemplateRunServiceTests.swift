// WorkflowTemplateRunServiceTests.swift - GUI service and run-sheet model for workflow templates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class WorkflowTemplateRunServiceTests: XCTestCase {

    // MARK: - Fake CLI

    /// Stands in for the bundled lungfish-cli: leaves the files each step
    /// would produce and records every invocation.
    private final class FakeTemplateCLI: LocalWorkflowCLIProcessRunning {
        struct Invocation: Equatable {
            let arguments: [String]
            let workingDirectory: URL
        }

        private(set) var invocations: [Invocation] = []
        private(set) var cancelCount = 0
        var failClassify = false

        func runLungfishCLI(
            arguments: [String],
            workingDirectory: URL,
            outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
        ) async throws -> LocalWorkflowCLIProcessResult {
            invocations.append(Invocation(arguments: arguments, workingDirectory: workingDirectory.standardizedFileURL))
            switch Array(arguments.prefix(2)) {
            case ["import", "fastq"]:
                let projectURL = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--project")! + 1])
                let name = arguments[arguments.firstIndex(of: "--name")! + 1]
                let bundleURL = projectURL.appendingPathComponent("Imports/\(name).lungfishfastq", isDirectory: true)
                try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
                try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: bundleURL.appendingPathComponent("\(name).fastq"))
                try Data("{\"workflowName\":\"lungfish import fastq\"}".utf8)
                    .write(to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
                let line = "{\"event\":\"sampleComplete\",\"sample\":\"\(name)\",\"bundle\":\"\(bundleURL.path)\"}"
                outputHandler?(.standardOutput(line))
                return LocalWorkflowCLIProcessResult(exitCode: 0, standardOutput: line + "\n", standardError: "", didStreamOutput: true)
            case ["conda", "classify"]:
                if failClassify {
                    outputHandler?(.standardError("kraken2 exploded"))
                    return LocalWorkflowCLIProcessResult(exitCode: 2, standardOutput: "", standardError: "kraken2 exploded", didStreamOutput: true)
                }
                let outputURL = URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--output-dir")! + 1])
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
                let sidecar: [String: Any] = [
                    "config": [
                        "confidence": 0.2, "databaseName": "Viral", "databasePath": "database", "goal": "profile",
                        "inputFiles": ["source.fastq"], "isPairedEnd": false, "memoryMapping": false,
                        "minimumHitGroups": 2, "outputDirectory": ".", "quickMode": false, "threads": 4,
                    ],
                    "outputPath": "classification.kraken", "reportPath": "classification.kreport",
                    "runtime": 1.0, "savedAt": "2026-09-26T00:00:00Z", "toolVersion": "2.17.1",
                    "profileOutcome": ["state": "completed", "toolVersion": "3.0.1"],
                ]
                try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
                    .write(to: outputURL.appendingPathComponent("classification-result.json"))
                return LocalWorkflowCLIProcessResult(exitCode: 0, standardOutput: "done\n", standardError: "")
            default:
                return LocalWorkflowCLIProcessResult(exitCode: 1, standardOutput: "", standardError: "unexpected \(arguments)")
            }
        }

        func cancel() {
            cancelCount += 1
        }
    }

    // MARK: - Helpers

    private struct Workspace {
        let fixture: AnalysisTemplateTestFixture
        let libraryURL: URL
        let target: URL
        let inputs: [URL]
        func cleanup() { fixture.cleanup() }
    }

    private func makeWorkspace() throws -> Workspace {
        let fixture = try AnalysisTemplateTestFixture.make()
        let target = fixture.rootURL.appendingPathComponent("Target.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let r1 = fixture.rootURL.appendingPathComponent("N_R1.fastq")
        let r2 = fixture.rootURL.appendingPathComponent("N_R2.fastq")
        try Data("@a/1\nACGT\n+\n!!!!\n".utf8).write(to: r1)
        try Data("@a/2\nACGT\n+\n!!!!\n".utf8).write(to: r2)
        return Workspace(fixture: fixture, libraryURL: fixture.rootURL.appendingPathComponent("Library"), target: target, inputs: [r1, r2])
    }

    private func makeService(
        workspace: Workspace,
        cli: FakeTemplateCLI,
        operationCenter: OperationCenter,
        database: AnalysisTemplateDatabaseStatus? = AnalysisTemplateDatabaseStatus(isReady: true, version: "20260626", digest: nil, path: URL(fileURLWithPath: "/dbs/viral"))
    ) -> WorkflowTemplateRunService {
        WorkflowTemplateRunService(
            operationCenter: operationCenter,
            processRunner: cli,
            library: AnalysisTemplateLibrary(directoryURL: workspace.libraryURL),
            databaseResolver: { _ in database },
            recipeResolver: { id in id == AnalysisTemplateTestFixture.sampleRecipe.id ? AnalysisTemplateTestFixture.sampleRecipe : nil }
        )
    }

    // MARK: - Save

    func testSaveTemplateWritesLibraryFileAndCompletedOperationRow() throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let operationCenter = OperationCenter()
        let service = makeService(workspace: workspace, cli: FakeTemplateCLI(), operationCenter: operationCenter)

        let extraction = try service.extract(analysisURL: workspace.fixture.analysisURL, projectURL: nil)
        var template = extraction.template
        template.name = "Viral screen"
        let saved = try service.saveTemplate(template, sourceAnalysisURL: workspace.fixture.analysisURL, routeContext: nil)

        XCTAssertEqual(saved.fileURL.lastPathComponent, "Viral screen.lungfishtemplate")
        XCTAssertEqual(try AnalysisTemplate.load(from: saved.fileURL).name, "Viral screen")
        XCTAssertEqual(service.templateLibrary.list().map(\.name), ["Viral screen"])
        let row = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(row.title, "Save Workflow Template: Viral screen")
        XCTAssertEqual(row.state, .completed)
        XCTAssertTrue(row.detail.contains("Tools > Workflows > Run Workflow Template"))
        XCTAssertTrue(row.cliCommand?.contains("workflow template create --from") == true)
    }

    // MARK: - Run

    func testRunLaunchesBundledCLIPerStepAndRecordsOperations() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let operationCenter = OperationCenter()
        let cli = FakeTemplateCLI()
        let service = makeService(workspace: workspace, cli: cli, operationCenter: operationCenter)
        let extraction = try service.extract(analysisURL: workspace.fixture.analysisURL, projectURL: nil)
        let saved = try service.saveTemplate(extraction.template, sourceAnalysisURL: workspace.fixture.analysisURL, routeContext: nil)

        let request = AnalysisTemplateRunRequest(
            template: extraction.template,
            templateURL: saved.fileURL,
            inputs: workspace.inputs,
            projectURL: workspace.target,
            sampleName: "N",
            threads: 2
        )
        let routeContext = OperationRouteContext(projectURL: workspace.target, windowStateScopeID: nil)
        let result = try await service.run(request, routeContext: routeContext)

        XCTAssertEqual(cli.invocations.map { Array($0.arguments.prefix(2)) }, [["import", "fastq"], ["conda", "classify"]])
        XCTAssertEqual(cli.invocations.map(\.workingDirectory), [workspace.target, workspace.target])
        XCTAssertTrue(cli.invocations[0].arguments.contains("--recipe"))
        XCTAssertEqual(cli.invocations[1].arguments.last, result.importBundleURL.path)
        XCTAssertEqual(result.importBundleURL.lastPathComponent, "N.lungfishfastq")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.runRecordURL.path))
        XCTAssertTrue(result.analysisDirectoryURL.path.hasPrefix(workspace.target.appendingPathComponent("Analyses").path))

        // The panel orders rows newest first, so look them up by title.
        let titles = [
            "Workflow Template: \(extraction.template.name)",
            "Step 1: Import FASTQ and apply recipe VSP2 Target Enrichment",
            "Step 2: Kraken2 + Bracken",
        ]
        XCTAssertEqual(Set(operationCenter.items.map(\.title)), Set(titles + ["Save Workflow Template: \(extraction.template.name)"]))
        let rows = try titles.map { title in try XCTUnwrap(operationCenter.items.first { $0.title == title }, title) }
        XCTAssertEqual(rows.map(\.state), [.completed, .completed, .completed])
        XCTAssertEqual(Set(rows.compactMap(\.workflowRunID)).count, 1)
        XCTAssertEqual(rows[0].routeContext, routeContext)
        XCTAssertTrue(rows[0].cliCommand?.hasPrefix("lungfish workflow template run ") == true, rows[0].cliCommand ?? "nil")
        XCTAssertTrue(rows[0].cliCommand?.contains("--allow-drift") == false)
        XCTAssertTrue(rows[1].cliCommand?.hasPrefix("lungfish-cli import fastq ") == true, rows[1].cliCommand ?? "nil")
        XCTAssertTrue(rows[2].cliCommand?.hasPrefix("lungfish-cli conda classify --db Viral") == true, rows[2].cliCommand ?? "nil")
        XCTAssertEqual(rows[0].outputURLs.map(\.lastPathComponent), ["N.lungfishfastq", result.analysisDirectoryURL.lastPathComponent])
        XCTAssertTrue(rows[1].logEntries.contains { $0.message.contains("sampleComplete") })
    }

    func testFailingStepFailsParentAndStepRows() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let operationCenter = OperationCenter()
        let cli = FakeTemplateCLI()
        cli.failClassify = true
        let service = makeService(workspace: workspace, cli: cli, operationCenter: operationCenter)
        let extraction = try service.extract(analysisURL: workspace.fixture.analysisURL, projectURL: nil)
        let request = AnalysisTemplateRunRequest(template: extraction.template, inputs: workspace.inputs, projectURL: workspace.target)

        do {
            _ = try await service.run(request, routeContext: nil)
            XCTFail("expected failure")
        } catch let error as AnalysisTemplateRunError {
            guard case .stepFailed(let step, let exitCode, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(step, "Kraken2 + Bracken")
            XCTAssertEqual(exitCode, 2)
        }
        let parent = try XCTUnwrap(operationCenter.items.first { $0.title.hasPrefix("Workflow Template:") })
        let importRow = try XCTUnwrap(operationCenter.items.first { $0.title.hasPrefix("Step 1:") })
        let classifyRow = try XCTUnwrap(operationCenter.items.first { $0.title.hasPrefix("Step 2:") })
        XCTAssertEqual([parent.state, importRow.state, classifyRow.state], [.failed, .completed, .failed])
        XCTAssertTrue(classifyRow.logEntries.contains { $0.message == "kraken2 exploded" })
        XCTAssertEqual(parent.errorMessage, "Workflow template run failed")
    }

    func testPreflightRefusalNeverLaunchesTheCLI() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let operationCenter = OperationCenter()
        let cli = FakeTemplateCLI()
        let service = makeService(workspace: workspace, cli: cli, operationCenter: operationCenter, database: nil)
        let extraction = try service.extract(analysisURL: workspace.fixture.analysisURL, projectURL: nil)
        let request = AnalysisTemplateRunRequest(template: extraction.template, inputs: workspace.inputs, projectURL: workspace.target)

        let report = await service.preflight(request)
        XCTAssertEqual(report.blockingIssues, ["Kraken2 database \"Viral\" is not installed on this Mac."])

        do {
            _ = try await service.run(request, routeContext: nil)
            XCTFail("expected refusal")
        } catch let error as AnalysisTemplateRunError {
            guard case .preflightFailed = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(cli.invocations.isEmpty)
        XCTAssertEqual(operationCenter.items.map(\.state), [.failed])
    }

    // MARK: - Run sheet model

    func testRunSheetModelReadinessFollowsInputsAndPreflight() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.cleanup() }
        let service = makeService(workspace: workspace, cli: FakeTemplateCLI(), operationCenter: OperationCenter())
        let extraction = try service.extract(analysisURL: workspace.fixture.analysisURL, projectURL: nil)
        _ = try service.saveTemplate(extraction.template, sourceAnalysisURL: workspace.fixture.analysisURL, routeContext: nil)

        let model = RunWorkflowTemplateSheetModel(
            entries: service.templateLibrary.list(),
            projectURL: workspace.target,
            threads: 3,
            preflight: { request in await service.preflight(request) }
        )
        XCTAssertEqual(model.selectedTemplate?.name, extraction.template.name)
        XCTAssertFalse(model.canRun)
        XCTAssertEqual(model.localIssues, ["Choose paired illumina fastq files."])

        model.inputs = [workspace.inputs[0]]
        XCTAssertEqual(model.localIssues, ["This template expects 2 FASTQ files per run. 1 chosen."])

        model.inputs = workspace.inputs
        XCTAssertTrue(model.localIssues.isEmpty)
        XCTAssertEqual(model.resolvedSampleName, "N")
        XCTAssertEqual(model.expectedOutputs, ["Imports/N.lungfishfastq", "Analyses/kraken2-<timestamp>"])
        try await waitUntil { !model.isChecking && model.report != nil }
        XCTAssertTrue(model.canRun, "blocking: \(model.blockingIssues)")
        XCTAssertNil(model.statusText)

        let request = try XCTUnwrap(model.runRequest)
        XCTAssertEqual(request.inputs, workspace.inputs)
        XCTAssertEqual(request.threads, 3)
        XCTAssertNil(request.sampleName)
        XCTAssertFalse(request.allowDrift)

        model.allowDrift = true
        try await waitUntil { !model.isChecking }
        XCTAssertEqual(model.runRequest?.allowDrift, true)
    }

    func testRunSheetModelWithUnreadableTemplateCannotRun() async throws {
        let root = try TestTempDirectory.make(prefix: "template-sheet")
        defer { TestTempDirectory.cleanup(root) }
        let libraryURL = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\": 7}".utf8).write(to: libraryURL.appendingPathComponent("Future.lungfishtemplate"))

        let model = RunWorkflowTemplateSheetModel(
            entries: AnalysisTemplateLibrary(directoryURL: libraryURL).list(),
            projectURL: root,
            preflight: { _ in AnalysisTemplatePreflightReport() }
        )
        // Nothing readable is preselected; the unreadable entry can be chosen but never run.
        XCTAssertNil(model.selectedTemplate)
        model.selectedEntryID = model.entries.first?.id
        XCTAssertNil(model.selectedTemplate)
        XCTAssertFalse(model.canRun)
        XCTAssertTrue(model.localIssues.first?.contains("newer version of LGE") == true)
    }

    private struct TimedOut: Error {}

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
