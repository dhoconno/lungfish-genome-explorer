// WorkflowTemplateRunService.swift - GUI entry point for saving and running workflow templates
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "WorkflowTemplateRunService")

/// Saves workflow templates from Kraken2 analyses and runs them from the GUI.
///
/// Every run goes through ``OperationCenter``: one parent row for the
/// template run plus one row per step. Each step launches the bundled
/// `lungfish-cli` (the same pattern as ``WorkflowBuilderRunService``), so the
/// GUI and the CLI share ``AnalysisTemplateRunner`` and every step writes
/// its own provenance with its real argv.
@MainActor
public final class WorkflowTemplateRunService {

    /// A saved template and where it went.
    public struct SaveResult: Sendable, Equatable {
        public let template: AnalysisTemplate
        public let fileURL: URL
    }

    private let operationCenter: OperationCenter
    private let processRunner: any LocalWorkflowCLIProcessRunning
    private let library: AnalysisTemplateLibrary
    private let databaseResolver: AnalysisTemplateRunner.DatabaseResolver
    private let recipeResolver: AnalysisTemplateRunner.RecipeResolver

    public convenience init(operationCenter: OperationCenter = .shared) {
        self.init(
            operationCenter: operationCenter,
            processRunner: ProcessLocalWorkflowCLIProcessRunner(),
            library: AnalysisTemplateLibrary()
        )
    }

    init(
        operationCenter: OperationCenter,
        processRunner: any LocalWorkflowCLIProcessRunning,
        library: AnalysisTemplateLibrary,
        databaseResolver: @escaping AnalysisTemplateRunner.DatabaseResolver = AnalysisTemplateRunner.registryDatabaseResolver,
        recipeResolver: @escaping AnalysisTemplateRunner.RecipeResolver = { RecipeRegistryV2.recipe(id: $0) }
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
        self.library = library
        self.databaseResolver = databaseResolver
        self.recipeResolver = recipeResolver
    }

    /// The library this service saves to and lists from.
    public var templateLibrary: AnalysisTemplateLibrary { library }

    // MARK: - Save

    /// Builds the template for the save sheet without writing anything.
    public func extract(analysisURL: URL, projectURL: URL?, name: String? = nil) throws -> AnalysisTemplateExtractor.Extraction {
        try AnalysisTemplateExtractor(recipeResolver: recipeResolver)
            .extract(analysisURL: analysisURL, projectURL: projectURL, name: name)
    }

    /// Saves a template into the library and records the save in the
    /// Operations panel (the panel's completed row doubles as the quiet
    /// confirmation that names where the template now lives).
    @discardableResult
    public func saveTemplate(
        _ template: AnalysisTemplate,
        sourceAnalysisURL: URL,
        routeContext: OperationRouteContext?
    ) throws -> SaveResult {
        let command = CLIInvocation(arguments: [
            "workflow", "template", "create", "--from", sourceAnalysisURL.path, "--name", template.name,
        ]).displayString
        guard case .started(let operationID) = operationCenter.begin(
            title: "Save Workflow Template: \(template.name)",
            detail: "Saving to the workflow template library",
            operationType: .workflow,
            cliCommand: command,
            routeContext: routeContext
        ) else {
            throw WorkflowTemplateRunServiceError.operationRefused
        }
        do {
            let fileURL = try library.save(template)
            operationCenter.log(id: operationID, level: .info, message: "Saved \(fileURL.path)")
            for warning in template.creationWarnings {
                operationCenter.log(id: operationID, level: .warning, message: warning)
            }
            _ = operationCenter.complete(
                id: operationID,
                detail: "Template \"\(template.name)\" saved. Run it from Tools > Workflows > Run Workflow Template…",
                outputURLs: [fileURL]
            )
            return SaveResult(template: template, fileURL: fileURL)
        } catch {
            _ = operationCenter.fail(
                id: operationID,
                detail: "Could not save the template: \(error.localizedDescription)",
                errorMessage: "Template not saved",
                errorDetail: String(describing: error)
            )
            throw error
        }
    }

    // MARK: - Run

    /// Readiness for the run sheet; runs no tools.
    public func preflight(_ request: AnalysisTemplateRunRequest) async -> AnalysisTemplatePreflightReport {
        let runner = AnalysisTemplateRunner(
            executor: NoopTemplateStepExecutor(),
            recipeResolver: recipeResolver,
            databaseResolver: databaseResolver
        )
        return await runner.preflight(request)
    }

    /// Runs the template through the Operations panel.
    public func run(
        _ request: AnalysisTemplateRunRequest,
        routeContext: OperationRouteContext?
    ) async throws -> AnalysisTemplateRunResult {
        let runID = UUID()
        var commandArguments = ["workflow", "template", "run", request.templateURL?.path ?? request.template.name]
        commandArguments += ["--project", request.projectURL.path]
        commandArguments += request.inputs.map(\.path)
        if let sampleName = request.sampleName, !sampleName.isEmpty { commandArguments += ["--name", sampleName] }
        if let threads = request.threads { commandArguments += ["--threads", String(threads)] }
        if request.allowDrift { commandArguments.append("--allow-drift") }
        let command = CLIInvocation(arguments: commandArguments).displayString

        let startResult = operationCenter.begin(
            title: "Workflow Template: \(request.template.name)",
            detail: "Running \(request.template.steps.count) steps with the template's settings",
            operationType: .workflow,
            cliCommand: command,
            workflowRunID: runID,
            routeContext: routeContext
        )
        guard case .started(let parentOperationID) = startResult else {
            throw WorkflowTemplateRunServiceError.operationRefused
        }
        operationCenter.setCancelCallback(for: parentOperationID) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.processRunner.cancel()
                }
            }
        }
        operationCenter.log(id: parentOperationID, level: .info, message: command)
        for input in request.inputs {
            operationCenter.log(id: parentOperationID, level: .info, message: "Input: \(input.path)")
        }

        let executor = LocalWorkflowCLIStepExecutor(
            processRunner: processRunner,
            operationCenter: operationCenter,
            parentOperationID: parentOperationID,
            runID: runID,
            routeContext: routeContext,
            stepCount: request.template.steps.count
        )
        let runner = AnalysisTemplateRunner(
            executor: executor,
            recipeResolver: recipeResolver,
            databaseResolver: databaseResolver
        )

        do {
            let result = try await runner.run(request)
            for warning in result.warnings {
                operationCenter.log(id: parentOperationID, level: .warning, message: warning)
            }
            _ = operationCenter.complete(
                id: parentOperationID,
                detail: "Imported \(result.importBundleURL.lastPathComponent) and wrote \(result.analysisDirectoryURL.lastPathComponent)",
                outputURLs: [result.importBundleURL, result.analysisDirectoryURL]
            )
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if operationCenter.items.first(where: { $0.id == parentOperationID })?.state == .cancelling {
                _ = operationCenter.acknowledgeCancellation(id: parentOperationID)
            } else {
                logger.error("Workflow template run failed: \(message, privacy: .public)")
                _ = operationCenter.fail(
                    id: parentOperationID,
                    detail: message,
                    errorMessage: "Workflow template run failed",
                    errorDetail: String(describing: error)
                )
            }
            throw error
        }
    }
}

/// Failures specific to the GUI service.
public enum WorkflowTemplateRunServiceError: Error, LocalizedError, Equatable {
    case operationRefused

    public var errorDescription: String? {
        switch self {
        case .operationRefused:
            return "The Operations panel refused to start the template run."
        }
    }
}

// MARK: - Step executor

/// Runs one template step as a bundled `lungfish-cli` child process with its
/// own Operations row, streaming output to both the step and parent rows.
@MainActor
final class LocalWorkflowCLIStepExecutor: AnalysisTemplateStepExecuting {
    private let processRunner: any LocalWorkflowCLIProcessRunning
    private let operationCenter: OperationCenter
    private let parentOperationID: UUID
    private let runID: UUID
    private let routeContext: OperationRouteContext?
    private let stepCount: Int

    init(
        processRunner: any LocalWorkflowCLIProcessRunning,
        operationCenter: OperationCenter,
        parentOperationID: UUID,
        runID: UUID,
        routeContext: OperationRouteContext?,
        stepCount: Int
    ) {
        self.processRunner = processRunner
        self.operationCenter = operationCenter
        self.parentOperationID = parentOperationID
        self.runID = runID
        self.routeContext = routeContext
        self.stepCount = stepCount
    }

    func execute(_ step: RenderedTemplateStep, workingDirectory: URL) async throws -> AnalysisTemplateStepResult {
        let operationType: OperationType = step.kind == .importFASTQ ? .ingestion : .classification
        guard case .started(let stepOperationID) = operationCenter.begin(
            title: "Step \(step.index): \(step.title)",
            detail: step.settingsSummary,
            operationType: operationType,
            cliCommand: step.commandLine,
            workflowRunID: runID,
            routeContext: routeContext
        ) else {
            throw WorkflowTemplateRunServiceError.operationRefused
        }
        operationCenter.log(id: stepOperationID, level: .info, message: step.commandLine)
        _ = operationCenter.update(
            id: parentOperationID,
            progress: Double(step.index - 1) / Double(max(stepCount, 1)),
            detail: "Step \(step.index) of \(stepCount): \(step.title)"
        )

        let operationCenter = self.operationCenter
        let result: LocalWorkflowCLIProcessResult
        do {
            result = try await processRunner.runLungfishCLI(
                arguments: step.arguments,
                workingDirectory: workingDirectory,
                outputHandler: { output in
                    switch output {
                    case .standardOutput(let text):
                        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                            operationCenter.log(id: stepOperationID, level: .info, message: line)
                        }
                    case .standardError(let text):
                        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                            operationCenter.log(id: stepOperationID, level: .error, message: line)
                        }
                    }
                }
            )
        } catch {
            _ = operationCenter.fail(
                id: stepOperationID,
                detail: error.localizedDescription,
                errorMessage: "\(step.title) failed",
                errorDetail: String(describing: error)
            )
            throw error
        }

        if !result.didStreamOutput {
            for line in result.standardOutput.components(separatedBy: .newlines) where !line.isEmpty {
                operationCenter.log(id: stepOperationID, level: .info, message: line)
            }
            for line in result.standardError.components(separatedBy: .newlines) where !line.isEmpty {
                operationCenter.log(id: stepOperationID, level: .error, message: line)
            }
        }
        if result.exitCode == 0 {
            _ = operationCenter.complete(
                id: stepOperationID,
                detail: "Finished. Output: \(step.expectedOutputURL.path)",
                outputURLs: [step.expectedOutputURL]
            )
            _ = operationCenter.update(
                id: parentOperationID,
                progress: Double(step.index) / Double(max(stepCount, 1)),
                detail: "Finished step \(step.index) of \(stepCount): \(step.title)"
            )
        } else {
            _ = operationCenter.fail(
                id: stepOperationID,
                detail: "\(step.title) exited with code \(result.exitCode)",
                errorMessage: "\(step.title) failed",
                errorDetail: result.standardError
            )
        }
        return AnalysisTemplateStepResult(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
    }
}

/// Executor for preflight-only runners; never invoked.
private struct NoopTemplateStepExecutor: AnalysisTemplateStepExecuting {
    func execute(_ step: RenderedTemplateStep, workingDirectory: URL) async throws -> AnalysisTemplateStepResult {
        AnalysisTemplateStepResult(exitCode: 1, standardOutput: "", standardError: "Preflight-only executor")
    }
}
