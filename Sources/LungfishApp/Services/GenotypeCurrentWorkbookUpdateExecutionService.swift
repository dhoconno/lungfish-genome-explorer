import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
final class GenotypeCurrentWorkbookUpdateExecutionService {
    private let operationCenter: OperationCenter
    private let processRunner: LocalWorkflowCLIProcessRunning
    private let fileManager: FileManager

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: LocalWorkflowCLIProcessRunning = ProcessLocalWorkflowCLIProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    @discardableResult
    func run(
        bundleURL: URL,
        calls: [GenotypeWorkbookHaplotypeCall],
        includedLoci: [String] = [],
        annotationSidecarURL: URL?,
        routeContext: OperationRouteContext? = nil
    ) async throws -> URL {
        let bundle = bundleURL.standardizedFileURL
        let callsURL = try writeCallsSnapshot(calls, bundleURL: bundle)
        let arguments = cliArguments(
            bundleURL: bundle,
            callsURL: callsURL,
            includedLoci: includedLoci,
            annotationSidecarURL: annotationSidecarURL
        )
        let cliCommand = ViralReconWorkflowCommandPreview.build(
            executableName: "lungfish-cli",
            arguments: arguments
        )
        let operationID = operationCenter.start(
            title: "Update current.xlsx",
            detail: "Preparing current.xlsx update",
            operationType: .fastqOperation,
            targetBundleURL: bundle,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)
        operationCenter.log(id: operationID, level: .info, message: "Calls snapshot: \(callsURL.path)")
        if !includedLoci.isEmpty {
            operationCenter.log(id: operationID, level: .info, message: "Included loci: \(includedLoci.joined(separator: ", "))")
        }
        if let annotationSidecarURL {
            operationCenter.log(id: operationID, level: .info, message: "Annotations: \(annotationSidecarURL.path)")
        }

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: bundle,
                outputHandler: { [operationCenter] output in
                    Self.recordProcessOutput(output, operationID: operationID, operationCenter: operationCenter)
                }
            )
            if !result.didStreamOutput {
                Self.logProcessOutput(result, operationID: operationID, operationCenter: operationCenter)
            }
            if result.exitCode != 0 {
                let detail = "current.xlsx update failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: detail)
                operationCenter.fail(
                    id: operationID,
                    detail: detail,
                    errorMessage: "current.xlsx update failed",
                    errorDetail: failureDiagnostics(result: result, cliCommand: cliCommand)
                )
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
            let currentWorkbookURL = Self.currentWorkbookURL(for: bundle)
            operationCenter.complete(
                id: operationID,
                detail: "Updated current.xlsx",
                outputURLs: [currentWorkbookURL]
            )
            return currentWorkbookURL
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                operationCenter.fail(
                    id: operationID,
                    detail: "current.xlsx update failed",
                    errorMessage: "current.xlsx update failed",
                    errorDetail: String(describing: error)
                )
            }
            throw error
        }
    }

    private func writeCallsSnapshot(
        _ calls: [GenotypeWorkbookHaplotypeCall],
        bundleURL: URL
    ) throws -> URL {
        let updatesDirectory = bundleURL
            .appendingPathComponent("artifacts/workbooks/updates", isDirectory: true)
        try fileManager.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
        let url = updatesDirectory
            .appendingPathComponent("\(timestampSlug())-displayed-haplotype-calls-\(UUID().uuidString.prefix(8)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(calls).write(to: url, options: .atomic)
        return url
    }

    private func cliArguments(
        bundleURL: URL,
        callsURL: URL,
        includedLoci: [String],
        annotationSidecarURL: URL?
    ) -> [String] {
        var arguments = [
            "fastq",
            "update-current-workbook",
            bundleURL.path,
            "--calls-json",
            callsURL.path,
        ]
        for locus in includedLoci {
            arguments += ["--included-locus", locus]
        }
        if let annotationSidecarURL,
           fileManager.fileExists(atPath: annotationSidecarURL.path) {
            arguments += ["--annotations", annotationSidecarURL.standardizedFileURL.path]
        }
        return arguments
    }

    private func timestampSlug() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func currentWorkbookURL(for bundleURL: URL) -> URL {
        if let manifestURL = try? ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL) {
            return manifestURL
        }
        return bundleURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    private static func logProcessOutput(
        _ result: LocalWorkflowCLIProcessResult,
        operationID: UUID,
        operationCenter: OperationCenter
    ) {
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            recordProcessOutput(.standardOutput(String(line)), operationID: operationID, operationCenter: operationCenter)
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            recordProcessOutput(.standardError(String(line)), operationID: operationID, operationCenter: operationCenter)
        }
    }

    private static func recordProcessOutput(
        _ output: ViralReconWorkflowProcessOutput,
        operationID: UUID,
        operationCenter: OperationCenter
    ) {
        switch output {
        case .standardOutput(let line):
            operationCenter.log(id: operationID, level: .info, message: line)
        case .standardError(let line):
            if let progress = parseCLIProgressLine(line) {
                operationCenter.updateWithLog(
                    id: operationID,
                    progress: progress.fraction,
                    detail: progress.message
                )
            } else {
                operationCenter.log(id: operationID, level: .warning, message: line)
            }
        }
    }

    private static func parseCLIProgressLine(_ line: String) -> (fraction: Double, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[",
              let closingBracket = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let percentRange = trimmed.index(after: trimmed.startIndex)..<closingBracket
        let percentText = trimmed[percentRange]
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Double(percentText) else {
            return nil
        }
        let messageStart = trimmed.index(after: closingBracket)
        let message = trimmed[messageStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (max(0, min(1, percent / 100)), message.isEmpty ? trimmed : message)
    }

    private func failureDiagnostics(
        result: LocalWorkflowCLIProcessResult,
        cliCommand: String
    ) -> String {
        var parts = [
            "lungfish-cli exited with exit code \(result.exitCode).",
            "",
            "CLI command:",
            cliCommand,
        ]
        let stderr = tail(result.standardError)
        if !stderr.isEmpty {
            parts += ["", "stderr:", stderr]
        }
        let stdout = tail(result.standardOutput)
        if !stdout.isEmpty {
            parts += ["", "stdout:", stdout]
        }
        return parts.joined(separator: "\n")
    }

    private func tail(_ text: String, lineLimit: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > lineLimit else { return trimmed }
        return lines.suffix(lineLimit).joined(separator: "\n")
    }
}
