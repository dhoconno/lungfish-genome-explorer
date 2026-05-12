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
        defaults: [String: ParameterValue] = [:],
        resolved: [String: ParameterValue]? = nil,
        toolName: String,
        toolVersion: String,
        command: [String],
        stepCommand: [String]? = nil,
        inputs: [FileRecord],
        outputs: [FileRecord],
        exitCode: Int32,
        wallTime: TimeInterval,
        peakMemoryBytes: UInt64? = nil,
        stderr: String?,
        status: RunStatus,
        outputDirectory: URL,
        writeFileSidecars: Bool = true
    ) async throws {
        _ = peakMemoryBytes
        _ = status

        let startedAt = Date().addingTimeInterval(-wallTime)
        let completedAt = Date()
        let inputDescriptors = inputs.map { ProvenanceFileDescriptor(fileRecord: $0) }
        let outputDescriptors = outputs.map { ProvenanceFileDescriptor(fileRecord: $0) }
        let step = ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: stepCommand ?? command,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: Int(exitCode),
            wallTimeSeconds: wallTime,
            stderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )

        let envelope = try ProvenanceRunBuilder(
            workflowName: name,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: toolVersion
        )
        .argv(command)
        .options(explicit: parameters, defaults: defaults, resolved: resolved ?? parameters)
        .runtime(ProvenanceRuntimeIdentity())
        .step(step)
        .complete(
            exitStatus: Int(exitCode),
            stderr: stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )

        let writer = ProvenanceWriter()
        try writer.write(envelope, to: outputDirectory)

        guard writeFileSidecars else { return }
        for output in outputs {
            let outputURL = URL(fileURLWithPath: output.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                if isDirectory.boolValue {
                    let focusedEnvelope = envelope.focusedOnOutput(ProvenanceFileDescriptor(fileRecord: output))
                    try writer.write(focusedEnvelope, to: outputURL)
                }
                continue
            }
            let focusedEnvelope = envelope.focusedOnOutput(ProvenanceFileDescriptor(fileRecord: output))
            try writer.write(focusedEnvelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        }
    }
}
