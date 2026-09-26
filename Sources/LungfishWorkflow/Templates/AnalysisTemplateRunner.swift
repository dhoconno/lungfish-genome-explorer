// AnalysisTemplateRunner.swift - Preflight, execution and run record for a template
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

// MARK: - Executor protocol

/// Result of one executed CLI step.
public struct AnalysisTemplateStepResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// Runs one rendered step. The CLI and the GUI supply their own transports
/// (a child `lungfish-cli` process); tests supply a fake.
public protocol AnalysisTemplateStepExecuting: Sendable {
    func execute(_ step: RenderedTemplateStep, workingDirectory: URL) async throws -> AnalysisTemplateStepResult
}

// MARK: - Database status

/// What the runner needs to know about an installed Kraken2 database.
public struct AnalysisTemplateDatabaseStatus: Sendable, Equatable {
    public var isReady: Bool
    public var version: String?
    public var digest: String?
    public var path: URL?

    public init(isReady: Bool, version: String?, digest: String?, path: URL?) {
        self.isReady = isReady
        self.version = version
        self.digest = digest
        self.path = path
    }

    public init(info: MetagenomicsDatabaseInfo) {
        self.init(
            isReady: info.status == .ready && info.path != nil,
            version: info.version,
            digest: info.payloadDigest,
            path: info.path
        )
    }
}

// MARK: - Request, preflight and result

/// Everything a run needs beyond the template.
public struct AnalysisTemplateRunRequest: Sendable, Equatable {
    public var template: AnalysisTemplate
    /// The template file, recorded in the run record when present.
    public var templateURL: URL?
    public var inputs: [URL]
    public var projectURL: URL
    public var sampleName: String?
    public var threads: Int?
    /// Warn instead of refusing when the recipe or database differs from the record.
    public var allowDrift: Bool

    public init(
        template: AnalysisTemplate,
        templateURL: URL? = nil,
        inputs: [URL],
        projectURL: URL,
        sampleName: String? = nil,
        threads: Int? = nil,
        allowDrift: Bool = false
    ) {
        self.template = template
        self.templateURL = templateURL
        self.inputs = inputs
        self.projectURL = projectURL
        self.sampleName = sampleName
        self.threads = threads
        self.allowDrift = allowDrift
    }
}

/// Checks that run before anything executes.
public struct AnalysisTemplatePreflightReport: Sendable, Equatable {
    /// Problems that stop the run.
    public var blockingIssues: [String]
    /// Differences the run proceeds with and records.
    public var warnings: [String]

    public init(blockingIssues: [String] = [], warnings: [String] = []) {
        self.blockingIssues = blockingIssues
        self.warnings = warnings
    }

    public var isRunnable: Bool { blockingIssues.isEmpty }
}

/// The outcome of a completed run.
public struct AnalysisTemplateRunResult: Sendable, Equatable {
    public let runID: UUID
    public let steps: [RenderedTemplateStep]
    public let importBundleURL: URL
    public let analysisDirectoryURL: URL
    /// Drift and version warnings, also stored in the run record.
    public let warnings: [String]
    /// The run-level provenance sidecar.
    public let runRecordURL: URL
}

/// Run refusals and failures.
public enum AnalysisTemplateRunError: Error, LocalizedError, Equatable, Sendable {
    case preflightFailed([String])
    case stepFailed(step: String, exitCode: Int32, detail: String)
    case outputMissing(step: String, path: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .preflightFailed(let issues):
            return "The template cannot run:\n" + issues.map { "- \($0)" }.joined(separator: "\n")
        case .stepFailed(let step, let exitCode, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "\(step) failed with exit code \(exitCode)."
                : "\(step) failed with exit code \(exitCode): \(trimmed)"
        case .outputMissing(let step, let path):
            return "\(step) finished but its output was not found at \(path)."
        case .cancelled:
            return "The template run was cancelled."
        }
    }
}

// MARK: - AnalysisTemplateRunner

/// Runs a template: preflight, one `lungfish-cli` invocation per step, output
/// location, then a run-level provenance record that links the step outputs.
///
/// Each step writes its own normal provenance with its real argv because it
/// runs as a separate CLI process. The run record (`workflowName`
/// ``AnalysisTemplate/runWorkflowName``) sits beside the Kraken2 output as
/// `template-run.lungfish-provenance.json` and stores the template SHA-256,
/// the per-run values and every drift warning.
public struct AnalysisTemplateRunner: Sendable {

    public static let runRecordFilename = "template-run.lungfish-provenance.json"

    public typealias RecipeResolver = @Sendable (String) -> Recipe?
    public typealias DatabaseResolver = @Sendable (Kraken2StepSpec.DatabaseIdentity) async throws -> AnalysisTemplateDatabaseStatus?
    /// Called with each step before it runs and with its result after.
    public typealias ProgressHandler = @Sendable (AnalysisTemplateRunEvent) -> Void

    private let executor: any AnalysisTemplateStepExecuting
    private let recipeResolver: RecipeResolver
    private let databaseResolver: DatabaseResolver
    private let provenanceWriter: ProvenanceWriter
    private let progress: ProgressHandler?

    public init(
        executor: any AnalysisTemplateStepExecuting,
        recipeResolver: @escaping RecipeResolver = { RecipeRegistryV2.recipe(id: $0) },
        databaseResolver: @escaping DatabaseResolver = AnalysisTemplateRunner.registryDatabaseResolver,
        provenanceWriter: ProvenanceWriter = ProvenanceWriter(),
        progress: ProgressHandler? = nil
    ) {
        self.executor = executor
        self.recipeResolver = recipeResolver
        self.databaseResolver = databaseResolver
        self.provenanceWriter = provenanceWriter
        self.progress = progress
    }

    /// Looks a pinned database up in the shared metagenomics registry.
    public static let registryDatabaseResolver: DatabaseResolver = { identity in
        guard let info = try await MetagenomicsDatabaseRegistry.shared.database(named: identity.name) else {
            return nil
        }
        return AnalysisTemplateDatabaseStatus(info: info)
    }

    // MARK: Preflight

    public func preflight(_ request: AnalysisTemplateRunRequest) async -> AnalysisTemplatePreflightReport {
        var report = AnalysisTemplatePreflightReport()
        let template = request.template

        if request.inputs.count != template.input.fileCount {
            report.blockingIssues.append(
                "This template expects \(template.input.summary.lowercased()) (\(template.input.fileCount) file\(template.input.fileCount == 1 ? "" : "s") per run) but \(request.inputs.count) were given."
            )
        }
        for input in request.inputs where !FileManager.default.fileExists(atPath: input.path) {
            report.blockingIssues.append("Input file not found: \(input.path)")
        }
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: request.projectURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            report.blockingIssues.append("Project folder not found: \(request.projectURL.path)")
        }

        if let importSpec = template.importStep, let snapshot = importSpec.recipe {
            checkRecipe(snapshot, allowDrift: request.allowDrift, report: &report)
        }
        if let kraken2 = template.kraken2Step {
            await checkDatabase(kraken2.database, allowDrift: request.allowDrift, report: &report)
        } else {
            report.blockingIssues.append("The template has no Kraken2 step.")
        }
        return report
    }

    private func checkRecipe(_ snapshot: RecipeSnapshot, allowDrift: Bool, report: inout AnalysisTemplatePreflightReport) {
        guard let installed = recipeResolver(snapshot.id) else {
            report.blockingIssues.append("Recipe \(snapshot.name) (\(snapshot.id)) is not installed on this Mac.")
            return
        }
        guard let recordedHash = snapshot.sha256 else {
            let message = "Recipe \(snapshot.name) was not captured when the template was made, so LGE cannot check whether the installed recipe matches."
            if allowDrift {
                report.warnings.append(message + " The run uses the installed recipe.")
            } else {
                report.blockingIssues.append(message + " Pass --allow-drift to run with the installed recipe.")
            }
            return
        }
        let installedHash = (try? RecipeSnapshot.sha256(of: installed)) ?? ""
        if installedHash != recordedHash {
            let message = "Recipe \(snapshot.name) has changed since this template was made."
            if allowDrift {
                report.warnings.append(message + " The run uses the installed recipe.")
            } else {
                report.blockingIssues.append(message + " Pass --allow-drift to run with the installed recipe.")
            }
        }
    }

    private func checkDatabase(
        _ identity: Kraken2StepSpec.DatabaseIdentity,
        allowDrift: Bool,
        report: inout AnalysisTemplatePreflightReport
    ) async {
        let status: AnalysisTemplateDatabaseStatus?
        do {
            status = try await databaseResolver(identity)
        } catch {
            report.blockingIssues.append("Could not read the database registry: \(error.localizedDescription)")
            return
        }
        guard let status, status.isReady else {
            report.blockingIssues.append("Kraken2 database \"\(identity.name)\" is not installed on this Mac.")
            return
        }
        if identity.version == Kraken2StepSpec.DatabaseIdentity.unknownVersion {
            report.warnings.append("The Kraken2 database version was not recorded when this template was made, so LGE cannot tell if it changed.")
        } else if let installedVersion = status.version, installedVersion != identity.version {
            let message = "Kraken2 database \"\(identity.name)\" is version \(installedVersion) on this Mac. The template used \(identity.version). Taxon assignments can change between database releases."
            if allowDrift {
                report.warnings.append(message)
            } else {
                report.blockingIssues.append(message + " Pass --allow-drift to run with the installed version.")
            }
        }
        if let recordedDigest = identity.digest, let installedDigest = status.digest, recordedDigest != installedDigest {
            let message = "Kraken2 database \"\(identity.name)\" has a different payload digest than the template recorded."
            if allowDrift {
                report.warnings.append(message)
            } else {
                report.blockingIssues.append(message + " Pass --allow-drift to run with the installed database.")
            }
        }
    }

    // MARK: Dry run

    /// Preflight plus the rendered steps, without touching the project.
    public func dryRun(_ request: AnalysisTemplateRunRequest) async throws -> (report: AnalysisTemplatePreflightReport, steps: [RenderedTemplateStep]) {
        let report = await preflight(request)
        let steps = try AnalysisTemplateRenderer.render(request.template, request: AnalysisTemplateRenderRequest(
            inputs: request.inputs,
            projectURL: request.projectURL,
            sampleName: request.sampleName,
            threads: request.threads
        ))
        return (report, steps)
    }

    // MARK: Run

    public func run(_ request: AnalysisTemplateRunRequest) async throws -> AnalysisTemplateRunResult {
        let report = await preflight(request)
        guard report.isRunnable else {
            throw AnalysisTemplateRunError.preflightFailed(report.blockingIssues)
        }
        var warnings = report.warnings
        let template = request.template
        let runID = UUID()
        let startedAt = Date()

        let analysisURL = try AnalysesFolder.createAnalysisDirectory(tool: "kraken2", in: request.projectURL)
        let sampleName = AnalysisTemplateRenderer.resolvedSampleName(inputs: request.inputs, sampleName: request.sampleName)
        var renderRequest = AnalysisTemplateRenderRequest(
            inputs: request.inputs,
            projectURL: request.projectURL,
            sampleName: sampleName,
            threads: request.threads,
            analysisDirectoryURL: analysisURL
        )
        var steps = try AnalysisTemplateRenderer.render(template, request: renderRequest)
        var executed: [ExecutedStep] = []
        var bundleURL: URL?

        do {
            for index in steps.indices {
                var step = steps[index]
                if step.kind == .kraken2, let bundleURL {
                    // Re-render against the bundle the import actually produced.
                    renderRequest.classificationInputs = [bundleURL]
                    let rerendered = try AnalysisTemplateRenderer.render(template, request: renderRequest)
                    if let match = rerendered.first(where: { $0.kind == .kraken2 }) {
                        step = match
                        steps[index] = match
                    }
                }
                progress?(.stepStarted(step))
                let stepStartedAt = Date()
                let result = try await executor.execute(step, workingDirectory: request.projectURL)
                let stepEndedAt = Date()
                guard result.exitCode == 0 else {
                    executed.append(ExecutedStep(step: step, result: result, startedAt: stepStartedAt, endedAt: stepEndedAt, outputURL: nil))
                    throw AnalysisTemplateRunError.stepFailed(
                        step: step.title,
                        exitCode: result.exitCode,
                        detail: result.standardError.isEmpty ? result.standardOutput.suffix(2000).description : result.standardError
                    )
                }
                let outputURL = try locateOutput(for: step, result: result)
                executed.append(ExecutedStep(step: step, result: result, startedAt: stepStartedAt, endedAt: stepEndedAt, outputURL: outputURL))
                if step.kind == .importFASTQ {
                    bundleURL = outputURL
                }
                progress?(.stepCompleted(step))
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            _ = try? writeRunRecord(
                runID: runID,
                request: request,
                sampleName: sampleName,
                executed: executed,
                bundleURL: bundleURL,
                analysisURL: analysisURL,
                warnings: warnings,
                startedAt: startedAt,
                exitStatus: 1,
                failure: message
            )
            throw error
        }

        guard let importBundleURL = bundleURL else {
            throw AnalysisTemplateRunError.outputMissing(step: "Import FASTQ", path: steps.first?.expectedOutputURL.path ?? "")
        }
        warnings += versionDriftWarnings(template: template, analysisURL: analysisURL)

        let runRecordURL = try writeRunRecord(
            runID: runID,
            request: request,
            sampleName: sampleName,
            executed: executed,
            bundleURL: importBundleURL,
            analysisURL: analysisURL,
            warnings: warnings,
            startedAt: startedAt,
            exitStatus: 0,
            failure: nil
        )
        return AnalysisTemplateRunResult(
            runID: runID,
            steps: steps,
            importBundleURL: importBundleURL,
            analysisDirectoryURL: analysisURL,
            warnings: warnings,
            runRecordURL: runRecordURL
        )
    }

    // MARK: Output location

    private struct ExecutedStep {
        let step: RenderedTemplateStep
        let result: AnalysisTemplateStepResult
        let startedAt: Date
        let endedAt: Date
        let outputURL: URL?
    }

    private func locateOutput(for step: RenderedTemplateStep, result: AnalysisTemplateStepResult) throws -> URL {
        switch step.kind {
        case .importFASTQ:
            // The importer reports the bundle name relative to the project's
            // Imports folder (an absolute path when a sample sheet placed it
            // elsewhere), so resolve it beside the expected bundle.
            let importsURL = step.expectedOutputURL.deletingLastPathComponent()
            let reported = Self.importedBundlePath(fromImportOutput: result.standardOutput).map { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path) : importsURL.appendingPathComponent(path)
            }
            let candidate = (reported ?? step.expectedOutputURL).standardizedFileURL
            guard FASTQBundle.isBundleURL(candidate),
                  FileManager.default.fileExists(atPath: candidate.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path) else {
                throw AnalysisTemplateRunError.outputMissing(step: step.title, path: candidate.path)
            }
            return candidate
        case .kraken2:
            let sidecar = step.expectedOutputURL.appendingPathComponent(ClassificationResult.sidecarFilename)
            guard FileManager.default.fileExists(atPath: sidecar.path) else {
                throw AnalysisTemplateRunError.outputMissing(step: step.title, path: sidecar.path)
            }
            return step.expectedOutputURL
        }
    }

    /// Reads the bundle path from the importer's JSON `sampleComplete` event.
    static func importedBundlePath(fromImportOutput output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["event"] as? String == "sampleComplete",
                  let bundle = object["bundle"] as? String, !bundle.isEmpty else {
                continue
            }
            return bundle
        }
        return nil
    }

    // MARK: Version drift

    private func versionDriftWarnings(template: AnalysisTemplate, analysisURL: URL) -> [String] {
        guard let kraken2 = template.kraken2Step else { return [] }
        let sidecarURL = analysisURL.appendingPathComponent(ClassificationResult.sidecarFilename)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? decoder.decode(PersistedClassificationResult.self, from: data) else {
            return []
        }
        var warnings: [String] = []
        if let recorded = kraken2.recordedKraken2Version, !sidecar.toolVersion.isEmpty, sidecar.toolVersion != recorded {
            warnings.append("Ran with Kraken2 \(sidecar.toolVersion); the template recorded \(recorded). Results may differ slightly.")
        }
        if let recorded = kraken2.recordedBrackenVersion,
           let actual = sidecar.profileOutcome?.toolVersion, actual != recorded {
            warnings.append("Ran with Bracken \(actual); the template recorded \(recorded). Results may differ slightly.")
        }
        return warnings
    }

    // MARK: Run record

    private func writeRunRecord(
        runID: UUID,
        request: AnalysisTemplateRunRequest,
        sampleName: String,
        executed: [ExecutedStep],
        bundleURL: URL?,
        analysisURL: URL,
        warnings: [String],
        startedAt: Date,
        exitStatus: Int,
        failure: String?
    ) throws -> URL {
        let template = request.template
        let templateSHA256 = (try? template.sha256()) ?? ""
        var argv = [CLICommandIdentity.executableName, "workflow", "template", "run", request.templateURL?.path ?? template.name]
        argv += ["--project", request.projectURL.path]
        argv += request.inputs.map(\.path)
        argv += ["--name", sampleName]
        if let threads = request.threads { argv += ["--threads", String(threads)] }
        if request.allowDrift { argv.append("--allow-drift") }

        var builder = ProvenanceRunBuilder(
            workflowName: AnalysisTemplate.runWorkflowName,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish-cli workflow template run",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(
            explicit: [
                "templateID": .string(template.id.uuidString),
                "templateName": .string(template.name),
                "templateSHA256": .string(templateSHA256),
                "templateFile": request.templateURL.map(ParameterValue.file) ?? .null,
                "project": .file(request.projectURL),
                "sampleName": .string(sampleName),
                "threads": request.threads.map(ParameterValue.integer) ?? .null,
                "allowDrift": .boolean(request.allowDrift),
                "runID": .string(runID.uuidString),
            ],
            defaults: [
                "threads": .null,
                "allowDrift": .boolean(false),
            ],
            resolved: [
                "importBundle": bundleURL.map(ParameterValue.file) ?? .null,
                "analysisDirectory": .file(analysisURL),
                "driftWarnings": .array(warnings.map(ParameterValue.string)),
                "creationWarnings": .array(template.creationWarnings.map(ParameterValue.string)),
                "failure": failure.map(ParameterValue.string) ?? .null,
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())

        if let templateURL = request.templateURL, FileManager.default.fileExists(atPath: templateURL.path) {
            builder = try builder.input(templateURL, format: .json, role: .input)
        }
        for input in request.inputs where FileManager.default.fileExists(atPath: input.path) {
            builder = try builder.input(input, format: .fastq, role: .input)
        }
        if let bundleURL {
            let sidecar = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                builder = try builder.output(sidecar, format: .json, role: .output)
            }
        }
        let resultSidecar = analysisURL.appendingPathComponent(ClassificationResult.sidecarFilename)
        if FileManager.default.fileExists(atPath: resultSidecar.path) {
            builder = try builder.output(resultSidecar, format: .json, role: .output)
        }

        for item in executed {
            var outputs: [ProvenanceFileDescriptor] = []
            if let outputURL = item.outputURL {
                let sidecarName = item.step.kind == .importFASTQ
                    ? ProvenanceRecorder.provenanceFilename
                    : ClassificationResult.sidecarFilename
                let sidecar = outputURL.appendingPathComponent(sidecarName)
                if let descriptor = try? ProvenanceFileDescriptor.file(url: sidecar, format: .json, role: .output) {
                    outputs.append(descriptor)
                }
            }
            builder = builder.step(ProvenanceStep(
                toolName: "lungfish-cli \(item.step.arguments.prefix(2).joined(separator: " "))",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: [CLICommandIdentity.executableName] + item.step.arguments,
                durableReplayArgv: [CLICommandIdentity.executableName] + item.step.arguments,
                resolvedOptions: [
                    "templateStep": .string(item.step.kind.rawValue),
                    "settings": .string(item.step.settingsSummary),
                ],
                outputs: outputs,
                exitStatus: Int(item.result.exitCode),
                wallTimeSeconds: item.endedAt.timeIntervalSince(item.startedAt),
                stderr: item.result.standardError.isEmpty ? nil : String(item.result.standardError.suffix(4000)),
                startedAt: item.startedAt,
                completedAt: item.endedAt
            ))
        }

        let envelope = try builder.complete(
            exitStatus: exitStatus,
            stderr: failure,
            startedAt: startedAt,
            endedAt: Date()
        )
        let recordURL = analysisURL.appendingPathComponent(Self.runRecordFilename)
        return try provenanceWriter.write(envelope, toSidecar: recordURL)
    }
}

/// Progress events for a running template.
public enum AnalysisTemplateRunEvent: Sendable {
    case stepStarted(RenderedTemplateStep)
    case stepCompleted(RenderedTemplateStep)
}

// MARK: - ProcessAnalysisTemplateStepExecutor

/// Runs each step as a child `lungfish-cli` process, streaming its output.
public struct ProcessAnalysisTemplateStepExecutor: AnalysisTemplateStepExecuting {
    public typealias OutputHandler = @Sendable (_ line: String, _ isError: Bool) -> Void

    private let executableURL: URL
    private let environment: [String: String]
    private let outputHandler: OutputHandler?

    /// - Parameters:
    ///   - executableURL: The `lungfish-cli` binary to launch.
    ///   - environment: Environment for the child; defaults to the managed
    ///     storage environment so the child sees the same databases and tools.
    ///   - outputHandler: Receives each output line as it arrives.
    public init(
        executableURL: URL,
        environment: [String: String]? = nil,
        outputHandler: OutputHandler? = nil
    ) {
        self.executableURL = executableURL
        self.environment = environment ?? ManagedStorageConfigStore().subprocessEnvironment()
        self.outputHandler = outputHandler
    }

    public func execute(_ step: RenderedTemplateStep, workingDirectory: URL) async throws -> AnalysisTemplateStepResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = step.arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = LineCollector(isError: false, handler: outputHandler)
        let stderrCollector = LineCollector(isError: true, handler: outputHandler)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        // The termination handler is installed before launch so a process that
        // exits immediately cannot slip past it.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        stdoutCollector.flush()
        stderrCollector.flush()

        if Task.isCancelled {
            throw AnalysisTemplateRunError.cancelled
        }
        return AnalysisTemplateStepResult(
            exitCode: process.terminationStatus,
            standardOutput: stdoutCollector.text,
            standardError: stderrCollector.text
        )
    }

    /// Accumulates pipe data and forwards complete lines to the handler.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var pending = ""
        private let isError: Bool
        private let handler: OutputHandler?

        init(isError: Bool, handler: OutputHandler?) {
            self.isError = isError
            self.handler = handler
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            pending += String(decoding: data, as: UTF8.self)
            var lines: [String] = []
            while let newline = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                lines.append(String(pending[..<newline]))
                pending = String(pending[pending.index(after: newline)...])
            }
            lock.unlock()
            for line in lines where !line.isEmpty {
                handler?(line, isError)
            }
        }

        func flush() {
            lock.lock()
            let rest = pending
            pending = ""
            lock.unlock()
            if !rest.isEmpty {
                handler?(rest, isError)
            }
        }
    }
}
