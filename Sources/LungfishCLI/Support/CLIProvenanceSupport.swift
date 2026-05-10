import Foundation
import LungfishWorkflow

enum CLIProvenanceSupport {
    static func condaCommand(toolName: String, environment: String, arguments: [String]) -> [String] {
        ["micromamba", "run", "-n", environment, toolName] + arguments
    }

    static func detectCondaToolVersion(
        toolName: String,
        environment: String,
        flags: [String] = ["--version", "-v"],
        fallback: String = "unknown"
    ) async -> String {
        for flag in flags {
            do {
                let result = try await CondaManager.shared.runTool(
                    name: toolName,
                    arguments: [flag],
                    environment: environment,
                    timeout: 30
                )
                let trimmed = (result.stdout + result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = trimmed.range(
                    of: #"\d+\.\d+(\.\d+)?"#,
                    options: .regularExpression
                ) {
                    return String(trimmed[range])
                }
                if let firstLine = trimmed.split(whereSeparator: \.isNewline).first {
                    return String(firstLine)
                }
            } catch {
                continue
            }
        }
        return fallback
    }

    static func recordSingleStepRun(
        name: String,
        parameters: [String: ParameterValue],
        toolName: String,
        toolVersion: String,
        command: [String],
        inputs: [FileRecord],
        outputs: [FileRecord],
        exitCode: Int32,
        wallTime: TimeInterval,
        peakMemoryBytes: UInt64? = nil,
        stderr: String?,
        status: RunStatus,
        outputDirectory: URL
    ) async throws {
        let runID = await ProvenanceRecorder.shared.beginRun(name: name, parameters: parameters)
        await ProvenanceRecorder.shared.recordStep(
            runID: runID,
            toolName: toolName,
            toolVersion: toolVersion,
            command: command,
            inputs: inputs,
            outputs: outputs,
            exitCode: exitCode,
            wallTime: wallTime,
            peakMemoryBytes: peakMemoryBytes,
            stderr: stderr
        )
        await ProvenanceRecorder.shared.completeRun(runID, status: status)
        try await ProvenanceRecorder.shared.save(runID: runID, to: outputDirectory)
    }
}
