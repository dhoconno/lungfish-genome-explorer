import ArgumentParser
import CryptoKit
import Foundation
import LungfishIO
import LungfishWorkflow

enum GenotypeReplayMatrixAnnotationError: Error, Equatable, LocalizedError {
    case emptyOption(String)
    case outputExists(String)
    case pathCollision(String, String)
    case missingReplayValue(String)
    case invalidBase64(String)
    case missingPriorInputDescriptor
    case checksumMismatch(name: String, expected: String, actual: String)
    case fileSizeMismatch(name: String, expected: UInt64, actual: UInt64)
    case replayFormatMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .emptyOption(let option):
            return "\(option) must not be empty."
        case .outputExists(let path):
            return "Replay output already exists: \(path). Pass --force to replace it."
        case .pathCollision(let first, let second):
            return "Replay paths must be distinct: \(first) and \(second)."
        case .missingReplayValue(let key):
            return "Replay provenance is missing required value '\(key)'."
        case .invalidBase64(let key):
            return "Replay provenance value '\(key)' is not valid base64."
        case .missingPriorInputDescriptor:
            return "Replay provenance is missing the embedded prior-sidecar input descriptor."
        case .checksumMismatch(let name, let expected, let actual):
            return "\(name) checksum mismatch: expected \(expected), found \(actual)."
        case .fileSizeMismatch(let name, let expected, let actual):
            return "\(name) file-size mismatch: expected \(expected), found \(actual)."
        case .replayFormatMismatch(let expected, let actual):
            return "Unsupported replay format '\(actual)'; expected '\(expected)'."
        }
    }
}

struct GenotypeReplayMatrixAnnotationSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: GenotypeMatrixAnnotationReplayPayload.cliSubcommandName,
        abstract: "Replay a recorded matrix annotation edit to an explicit annotation sidecar"
    )

    @Option(
        name: .customLong("provenance"),
        help: "GUI annotation provenance sidecar containing the embedded prior input and replay payload"
    )
    var provenance: String

    @Option(
        name: .customLong("output"),
        help: "Explicit path for the reconstructed annotations JSON"
    )
    var output: String

    @Option(
        name: .customLong("output-provenance"),
        help: "Path for replay output provenance; defaults to a replay-specific peer of --output"
    )
    var outputProvenance: String?

    @Flag(
        name: .customLong("force"),
        help: "Replace existing replay output and replay provenance files"
    )
    var force = false

    func validate() throws {
        if provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenotypeReplayMatrixAnnotationError.emptyOption("--provenance")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenotypeReplayMatrixAnnotationError.emptyOption("--output")
        }
        if let outputProvenance,
           outputProvenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenotypeReplayMatrixAnnotationError.emptyOption("--output-provenance")
        }
        try validateDistinctPaths()
    }

    func run() async throws {
        try validate()
        let startedAt = Date()
        let provenanceURL = URL(fileURLWithPath: provenance).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let defaultOutputProvenanceURL =
            GenotypeMatrixAnnotationReplayPayload.replayOutputProvenanceURL(for: outputURL)
                .standardizedFileURL
        let outputProvenanceURL = outputProvenance
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? defaultOutputProvenanceURL
        try validateOutputAvailability(outputURL, outputProvenanceURL)

        let provenanceData = try Data(contentsOf: provenanceURL)
        let sourceEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: provenanceData
        )
        let replayInputs = try decodeReplayInputs(
            from: sourceEnvelope,
            provenanceURL: provenanceURL
        )
        let priorSidecar = try GenotypeAnnotationSidecar.decode(replayInputs.priorData)
        let replayPayload = try GenotypeMatrixAnnotationReplayPayload.decode(
            replayInputs.payloadData
        )
        let reconstructed = try replayPayload.applying(to: priorSidecar)
        let outputData = try reconstructed.encoded()

        let publicationSnapshot = try ProvenancePublicationSnapshot(
            urls: [outputURL]
                + ProvenancePublicationArtifacts.sidecarArtifacts(for: outputProvenanceURL),
            backupNamePrefix: "lungfish-genotype-matrix-annotation-replay"
        )
        defer { publicationSnapshot.discard() }

        do {
            try outputData.write(to: outputURL, options: .atomic)
            let command = commandArgv(
                provenanceURL: provenanceURL,
                outputURL: outputURL,
                outputProvenanceURL: outputProvenanceURL
            )
            let inputDescriptor = ProvenanceFileDescriptor(
                path: provenanceURL.path,
                checksumSHA256: sha256Hex(provenanceData),
                fileSize: UInt64(provenanceData.count),
                format: .json,
                role: .input
            )
            let outputDescriptor = ProvenanceFileDescriptor(
                path: outputURL.path,
                checksumSHA256: sha256Hex(outputData),
                fileSize: UInt64(outputData.count),
                format: .json,
                role: .output
            )
            let completedAt = Date()
            let wallTime = max(0, completedAt.timeIntervalSince(startedAt))
            let reproducibleCommand = command.map(shellEscape).joined(separator: " ")
            let explicitOptions: [String: ParameterValue] = [
                "provenance": .file(provenanceURL),
                "output": .file(outputURL),
                "outputProvenance": .file(outputProvenanceURL),
                "force": .boolean(force),
            ]
            let defaultOptions: [String: ParameterValue] = [
                "force": .boolean(false),
                "outputProvenance": .file(defaultOutputProvenanceURL),
                "replayFormat": .string(GenotypeMatrixAnnotationReplayPayload.format),
            ]
            var resolvedOptions = explicitOptions
            resolvedOptions["replayFormat"] = .string(GenotypeMatrixAnnotationReplayPayload.format)
            resolvedOptions["replaySchemaVersion"] = .integer(replayPayload.schemaVersion)
            resolvedOptions["replayAction"] = .string(replayPayload.action.rawValue)
            resolvedOptions["replayAuthor"] = .string(replayPayload.author)
            resolvedOptions["replayTimestamp"] = .string(replayPayload.timestamp)
            resolvedOptions["embeddedPriorSHA256"] = .string(sha256Hex(replayInputs.priorData))
            resolvedOptions["replayPayloadSHA256"] = .string(sha256Hex(replayInputs.payloadData))
            let runtimeIdentity = ProvenanceRuntimeIdentity()
            let step = ProvenanceStep(
                toolName: CLICommandIdentity.executableName,
                toolVersion: WorkflowRun.currentAppVersion,
                argv: command,
                durableReplayArgv: command,
                reproducibleCommand: reproducibleCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: [inputDescriptor],
                outputs: [outputDescriptor],
                exitStatus: 0,
                wallTimeSeconds: wallTime,
                stderr: "",
                startedAt: startedAt,
                completedAt: completedAt
            )
            let envelope = ProvenanceEnvelope(
                createdAt: startedAt,
                workflowName: "lungfish genotype \(GenotypeMatrixAnnotationReplayPayload.cliSubcommandName)",
                workflowVersion: WorkflowRun.currentAppVersion,
                toolName: CLICommandIdentity.executableName,
                toolVersion: WorkflowRun.currentAppVersion,
                tool: ProvenanceToolIdentity(
                    name: CLICommandIdentity.executableName,
                    version: WorkflowRun.currentAppVersion,
                    kind: "cli"
                ),
                argv: command,
                durableReplayArgv: command,
                reproducibleCommand: reproducibleCommand,
                options: ProvenanceOptions(
                    explicit: explicitOptions,
                    defaults: defaultOptions,
                    resolvedDefaults: resolvedOptions
                ),
                runtimeIdentity: runtimeIdentity,
                files: [inputDescriptor, outputDescriptor],
                output: outputDescriptor,
                outputs: [outputDescriptor],
                steps: [step],
                wallTimeSeconds: wallTime,
                exitStatus: 0,
                stderr: ""
            )
            try ProvenanceWriter().write(envelope, toSidecar: outputProvenanceURL)
        } catch {
            try throwAfterProvenancePublicationFailure(error) {
                try publicationSnapshot.restore()
            }
        }
    }

    private func validateDistinctPaths() throws {
        let provenanceURL = URL(fileURLWithPath: provenance).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let outputProvenanceURL = outputProvenance
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? GenotypeMatrixAnnotationReplayPayload.replayOutputProvenanceURL(for: outputURL)
                .standardizedFileURL
        let protectedSourceArtifacts = ProvenancePublicationArtifacts
            .sidecarArtifacts(for: provenanceURL)
        let writableArtifacts = [outputURL]
            + ProvenancePublicationArtifacts.sidecarArtifacts(for: outputProvenanceURL)
        var seenPaths = Set<String>()
        for url in protectedSourceArtifacts + writableArtifacts {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else {
                throw GenotypeReplayMatrixAnnotationError.pathCollision(path, path)
            }
        }
    }

    private func validateOutputAvailability(
        _ outputURL: URL,
        _ outputProvenanceURL: URL
    ) throws {
        guard !force else { return }
        let writableArtifacts = [outputURL]
            + ProvenancePublicationArtifacts.sidecarArtifacts(for: outputProvenanceURL)
        for url in writableArtifacts
        where FileManager.default.fileExists(atPath: url.path) {
            throw GenotypeReplayMatrixAnnotationError.outputExists(url.path)
        }
    }

    private func decodeReplayInputs(
        from envelope: ProvenanceEnvelope,
        provenanceURL: URL
    ) throws -> (priorData: Data, payloadData: Data) {
        let explicit = envelope.options.explicit
        let recordedFormat = try requiredString("replayFormat", in: explicit)
        guard recordedFormat == GenotypeMatrixAnnotationReplayPayload.format else {
            throw GenotypeReplayMatrixAnnotationError.replayFormatMismatch(
                expected: GenotypeMatrixAnnotationReplayPayload.format,
                actual: recordedFormat
            )
        }
        let priorData = try requiredBase64("replayPriorSidecarBase64", in: explicit)
        let payloadData = try requiredBase64("replayPayloadBase64", in: explicit)
        let recordedPayloadChecksum = try requiredString("replayPayloadSHA256", in: explicit)
        try validateChecksum(
            name: "Replay payload",
            data: payloadData,
            expected: recordedPayloadChecksum
        )

        guard let priorDescriptor = envelope.files.first(where: {
            $0.role == .input
                && $0.path.hasSuffix("#/options/explicit/replayPriorSidecarBase64")
        }) else {
            throw GenotypeReplayMatrixAnnotationError.missingPriorInputDescriptor
        }
        guard let recordedPriorChecksum = priorDescriptor.checksumSHA256 else {
            throw GenotypeReplayMatrixAnnotationError.missingReplayValue(
                "priorInput.checksumSHA256"
            )
        }
        try validateChecksum(
            name: "Embedded prior sidecar",
            data: priorData,
            expected: recordedPriorChecksum
        )
        if let expectedSize = priorDescriptor.fileSize,
           expectedSize != UInt64(priorData.count) {
            throw GenotypeReplayMatrixAnnotationError.fileSizeMismatch(
                name: "Embedded prior sidecar",
                expected: expectedSize,
                actual: UInt64(priorData.count)
            )
        }
        guard priorDescriptor.path.hasPrefix(provenanceURL.path + "#")
                || priorDescriptor.originPath != nil else {
            throw GenotypeReplayMatrixAnnotationError.missingPriorInputDescriptor
        }
        return (priorData, payloadData)
    }

    private func requiredString(
        _ key: String,
        in values: [String: ParameterValue]
    ) throws -> String {
        guard let value = values[key]?.stringValue else {
            throw GenotypeReplayMatrixAnnotationError.missingReplayValue(key)
        }
        return value
    }

    private func requiredBase64(
        _ key: String,
        in values: [String: ParameterValue]
    ) throws -> Data {
        let encoded = try requiredString(key, in: values)
        guard let data = Data(base64Encoded: encoded) else {
            throw GenotypeReplayMatrixAnnotationError.invalidBase64(key)
        }
        return data
    }

    private func validateChecksum(
        name: String,
        data: Data,
        expected: String
    ) throws {
        let actual = sha256Hex(data)
        guard actual == expected else {
            throw GenotypeReplayMatrixAnnotationError.checksumMismatch(
                name: name,
                expected: expected,
                actual: actual
            )
        }
    }

    private func commandArgv(
        provenanceURL: URL,
        outputURL: URL,
        outputProvenanceURL: URL
    ) -> [String] {
        var argv = [
            CLICommandIdentity.executableName,
            "genotype",
            GenotypeMatrixAnnotationReplayPayload.cliSubcommandName,
            "--provenance", provenanceURL.path,
            "--output", outputURL.path,
        ]
        if outputProvenance != nil {
            argv += ["--output-provenance", outputProvenanceURL.path]
        }
        if force {
            argv.append("--force")
        }
        return argv
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
