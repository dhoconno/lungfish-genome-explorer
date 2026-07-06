import Foundation
import LungfishWorkflow

enum CLIProvenanceSupport {
    static func condaCommand(toolName: String, environment: String, arguments: [String]) -> [String] {
        ["micromamba", "run", "-n", environment, toolName] + arguments
    }

    static func resolvedOptions(
        explicit: [String: ParameterValue],
        defaults: [String: ParameterValue],
        resolved: [String: ParameterValue]? = nil
    ) -> [String: ParameterValue] {
        var merged = defaults
        for (key, value) in explicit {
            merged[key] = value
        }
        if let resolved {
            for (key, value) in resolved {
                merged[key] = value
            }
        }
        return merged
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

    static func bundlePayloadURLs(in bundleURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }

        let rootProvenancePath = bundleURL
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            .standardizedFileURL
            .path
        let provenanceDirectoryPrefix = bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .standardizedFileURL
            .path + "/"

        var payloadURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let standardized = fileURL.standardizedFileURL
            guard standardized.path != rootProvenancePath,
                  !standardized.path.hasPrefix(provenanceDirectoryPrefix),
                  !isProvenanceArtifactFilename(standardized.lastPathComponent)
            else {
                continue
            }
            guard (try? standardized.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            payloadURLs.append(standardized)
        }

        return payloadURLs.sorted { $0.path < $1.path }
    }

    private static func isProvenanceArtifactFilename(_ filename: String) -> Bool {
        filename == ProvenanceRecorder.provenanceFilename
            || filename.contains(".lungfish-provenance.json")
    }

    @discardableResult
    static func recordSingleStepRun(
        name: String,
        parameters: [String: ParameterValue],
        defaults: [String: ParameterValue] = [:],
        resolved: [String: ParameterValue]? = nil,
        toolName: String,
        toolVersion: String,
        command: [String],
        stepCommand: [String]? = nil,
        extraSteps: [ProvenanceStep] = [],
        inputs: [FileRecord],
        outputs: [FileRecord],
        exitCode: Int32,
        wallTime: TimeInterval,
        peakMemoryBytes: UInt64? = nil,
        stderr: String?,
        status: RunStatus,
        outputDirectory: URL,
        writeFileSidecars: Bool = true
    ) async throws -> ProvenanceEnvelope {
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

        var builder = ProvenanceRunBuilder(
            workflowName: name,
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: toolVersion
        )
        .argv(command)
        .durableReplayArgv(command)
        .options(
            explicit: parameters,
            defaults: defaults,
            resolved: resolvedOptions(explicit: parameters, defaults: defaults, resolved: resolved)
        )
        .runtime(ProvenanceRuntimeIdentity())

        for input in inputs {
            builder = try appendInputRecord(input, to: builder)
        }
        for output in outputs {
            builder = try appendOutputRecord(output, to: builder)
        }

        builder = builder.step(step)

        for extraStep in extraSteps {
            builder = builder.step(extraStep)
        }

        let envelope = try builder.complete(
            exitStatus: Int(exitCode),
            stderr: stderr,
            startedAt: startedAt,
            endedAt: completedAt
        )

        let writer = ProvenanceWriter()
        try writer.write(envelope, to: outputDirectory)

        guard writeFileSidecars else { return envelope }
        for output in outputs {
            guard !shouldUseDescriptorVerbatim(for: output.path) else {
                continue
            }
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
        return envelope
    }

    private static func appendInputRecord(
        _ record: FileRecord,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if shouldUseDescriptorVerbatim(for: record.path) {
            return try builder.input(ProvenanceFileDescriptor(fileRecord: record))
        }
        return try builder.input(URL(fileURLWithPath: record.path), format: record.format, role: record.role)
    }

    private static func appendOutputRecord(
        _ record: FileRecord,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if shouldUseDescriptorVerbatim(for: record.path) {
            return try builder.output(ProvenanceFileDescriptor(fileRecord: record))
        }
        return try builder.output(URL(fileURLWithPath: record.path), format: record.format, role: record.role)
    }

    private static func shouldUseDescriptorVerbatim(for path: String) -> Bool {
        guard path.contains("://") else {
            return false
        }
        guard let scheme = URLComponents(string: path)?.scheme else {
            return false
        }
        return scheme.lowercased() != "file"
    }
}
