import ArgumentParser
import CryptoKit
import Foundation
import LungfishIO
import LungfishWorkflow

enum GenotypeReplayManualHaplotypeAssignmentsError:
    Error,
    Equatable,
    LocalizedError
{
    case emptyOption(String)
    case outputExists(String)
    case pathCollision(String)
    case missingReplayValue(String)
    case invalidBase64(String)
    case missingPriorSidecar(String)
    case checksumMismatch(name: String, expected: String, actual: String)
    case replayFormatMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .emptyOption(let option):
            "\(option) must not be empty."
        case .outputExists(let path):
            "Replay provenance output already exists: \(path)."
        case .pathCollision(let path):
            "Replay input, scientific output, and provenance paths must be distinct: \(path)."
        case .missingReplayValue(let key):
            "Replay provenance is missing required value '\(key)'."
        case .invalidBase64(let key):
            "Replay provenance value '\(key)' is not valid base64."
        case .missingPriorSidecar(let path):
            "Replay requires the exact recorded prior annotation sidecar at \(path)."
        case .checksumMismatch(let name, let expected, let actual):
            "\(name) checksum mismatch: expected \(expected), found \(actual)."
        case .replayFormatMismatch(let expected, let actual):
            "Unsupported replay format '\(actual)'; expected '\(expected)'."
        }
    }
}

struct GenotypeReplayManualHaplotypeAssignmentsSubcommand:
    AsyncParsableCommand
{
    typealias ProvenancePublisher = @Sendable (
        _ envelope: ProvenanceEnvelope,
        _ outputURL: URL
    ) throws -> Void

    static let configuration = CommandConfiguration(
        commandName:
            GenotypeManualHaplotypeAssignmentReplayPayload.cliSubcommandName,
        abstract:
            "Replay a recorded manual haplotype assignment edit into its exact target bundle"
    )

    @Option(
        name: .customLong("provenance"),
        help: "GUI annotation provenance containing the replay payload"
    )
    var provenance: String

    @Option(
        name: .customLong("bundle"),
        help: "Exact genotype result bundle recorded by the replay payload"
    )
    var bundle: String

    @Option(
        name: .customLong("output-provenance"),
        help: "Replay provenance path; defaults to a replay-specific peer of annotations.json"
    )
    var outputProvenance: String?

    var publicationPreparationHook: (@Sendable () throws -> Void)? = nil
    var provenancePublisher: ProvenancePublisher? = nil

    private enum CodingKeys: String, CodingKey {
        case provenance
        case bundle
        case outputProvenance
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provenance = try container.decode(String.self, forKey: .provenance)
        bundle = try container.decode(String.self, forKey: .bundle)
        outputProvenance = try container.decodeIfPresent(
            String.self,
            forKey: .outputProvenance
        )
    }

    func validate() throws {
        if provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .emptyOption("--provenance")
        }
        if bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .emptyOption("--bundle")
        }
        if let outputProvenance,
           outputProvenance.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .emptyOption("--output-provenance")
        }
        try validateDistinctPaths()
    }

    func run() async throws {
        try validate()
        let startedAt = Date()
        let sourceProvenanceURL =
            URL(fileURLWithPath: provenance).standardizedFileURL
        let bundleURL = URL(fileURLWithPath: bundle).standardizedFileURL
        let annotationURL =
            ONTGenotypeResultBundleData.annotationSidecarURL(
                forBundleAt: bundleURL
            ).standardizedFileURL
        let manifestURL = bundleURL.appendingPathComponent(
            ONTGenotypeResultBundleManifest.filename
        ).standardizedFileURL
        let defaultOutputProvenanceURL =
            GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: bundleURL)
                .standardizedFileURL
        let outputProvenanceURL =
            outputProvenance.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            } ?? defaultOutputProvenanceURL
        try validateOutputAvailability(outputProvenanceURL)

        let sourceProvenanceData = try Data(contentsOf: sourceProvenanceURL)
        let sourceEnvelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: sourceProvenanceData
        )
        let payloadData = try decodeReplayPayload(from: sourceEnvelope)
        let payload =
            try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
                payloadData
            )

        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(
            for: bundleURL
        )
        defer { publicationLock.release() }

        try publicationPreparationHook?()
        try validateOutputAvailability(outputProvenanceURL)
        let manifestData = try ONTGenotypeResultBundle
            .readManifestDataNoFollow(from: bundleURL)
        let priorSnapshot =
            try ONTGenotypeResultBundleData.loadAnnotationSidecarSnapshot(
                forBundleAt: bundleURL
            )
        guard let priorData = priorSnapshot.data else {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .missingPriorSidecar(annotationURL.path)
        }
        let reconstructed = try payload.applying(
            to: priorData,
            targetBundleURL: bundleURL,
            targetManifestData: manifestData
        )
        let outputData = try reconstructed.encoded()

        let publicationSnapshot = try ProvenancePublicationSnapshot(
            urls: [annotationURL]
                + ProvenancePublicationArtifacts.sidecarArtifacts(
                    for: outputProvenanceURL
                ),
            backupNamePrefix:
                "lungfish-genotype-manual-haplotype-assignment-replay"
        )
        defer { publicationSnapshot.discard() }

        do {
            try ONTGenotypeResultBundleData.writeAnnotationSidecar(
                reconstructed,
                expectedRevision: priorSnapshot.revision,
                forBundleAt: bundleURL,
                assuming: publicationLock
            )
            let command = commandArgv(
                sourceProvenanceURL: sourceProvenanceURL,
                bundleURL: bundleURL,
                outputProvenanceURL: outputProvenanceURL
            )
            let reproducibleCommand = command.map(shellEscape)
                .joined(separator: " ")
            let sourceDescriptor = descriptor(
                data: sourceProvenanceData,
                url: sourceProvenanceURL,
                role: .input
            )
            let manifestDescriptor = descriptor(
                data: manifestData,
                url: manifestURL,
                role: .input
            )
            let priorDescriptor = descriptor(
                data: priorData,
                url: annotationURL,
                role: .input
            )
            let outputDescriptor = descriptor(
                data: outputData,
                url: annotationURL,
                role: .output
            )
            var explicitOptions: [String: ParameterValue] = [
                "provenance": .file(sourceProvenanceURL),
                "bundle": .file(bundleURL),
            ]
            if outputProvenance != nil {
                explicitOptions["outputProvenance"] = .file(
                    outputProvenanceURL
                )
            }
            let defaultOptions: [String: ParameterValue] = [
                "outputProvenance": .file(defaultOutputProvenanceURL),
                "replayFormat": .string(
                    GenotypeManualHaplotypeAssignmentReplayPayload.format
                ),
            ]
            let resolvedOptions: [String: ParameterValue] = [
                "provenance": .file(sourceProvenanceURL),
                "bundle": .file(bundleURL),
                "annotationSidecar": .file(annotationURL),
                "outputProvenance": .file(outputProvenanceURL),
                "replayFormat": .string(
                    GenotypeManualHaplotypeAssignmentReplayPayload.format
                ),
                "replaySchemaVersion": .integer(payload.schemaVersion),
                "operationID": .string(payload.operation.operationID),
                "sample": .string(payload.operation.sample),
                "author": .string(payload.operation.author),
                "timestamp": .string(payload.operation.timestamp),
                "copySourceSample": payload.operation.copySourceSample
                    .map(ParameterValue.string) ?? .null,
                "targetManifestSHA256": .string(
                    payload.targetBundle.manifest.checksumSHA256
                ),
                "priorSidecarSHA256": .string(
                    payload.priorSidecar.descriptor.checksumSHA256
                ),
                "priorSidecarRevisionSHA256": .string(
                    payload.priorSidecar.revisionSHA256
                ),
                "replayPayloadSHA256": .string(sha256Hex(payloadData)),
            ]
            let completedAt = Date()
            let wallTime = max(
                0,
                completedAt.timeIntervalSince(startedAt)
            )
            let runtimeIdentity = ProvenanceRuntimeIdentity()
            let step = ProvenanceStep(
                toolName: CLICommandIdentity.executableName,
                toolVersion: WorkflowRun.currentAppVersion,
                argv: command,
                durableReplayArgv: command,
                reproducibleCommand: reproducibleCommand,
                resolvedOptions: resolvedOptions,
                runtimeIdentity: runtimeIdentity,
                inputs: [
                    sourceDescriptor, manifestDescriptor, priorDescriptor,
                ],
                outputs: [outputDescriptor],
                exitStatus: 0,
                wallTimeSeconds: wallTime,
                stderr: "",
                startedAt: startedAt,
                completedAt: completedAt
            )
            let envelope = ProvenanceEnvelope(
                createdAt: startedAt,
                workflowName:
                    "lungfish genotype \(GenotypeManualHaplotypeAssignmentReplayPayload.cliSubcommandName)",
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
                files: [
                    sourceDescriptor, manifestDescriptor, priorDescriptor,
                    outputDescriptor,
                ],
                output: outputDescriptor,
                outputs: [outputDescriptor],
                steps: [step],
                wallTimeSeconds: wallTime,
                exitStatus: 0,
                stderr: ""
            )
            if let provenancePublisher {
                try provenancePublisher(envelope, outputProvenanceURL)
            } else {
                try ProvenanceWriter().write(
                    envelope,
                    toSidecar: outputProvenanceURL
                )
            }
        } catch {
            try throwAfterProvenancePublicationFailure(error) {
                try publicationSnapshot.restore()
            }
        }
    }

    private func validateDistinctPaths() throws {
        let sourceProvenanceURL =
            URL(fileURLWithPath: provenance).standardizedFileURL
        let bundleURL = URL(fileURLWithPath: bundle).standardizedFileURL
        let annotationURL =
            ONTGenotypeResultBundleData.annotationSidecarURL(
                forBundleAt: bundleURL
            ).standardizedFileURL
        let manifestURL = bundleURL.appendingPathComponent(
            ONTGenotypeResultBundleManifest.filename
        ).standardizedFileURL
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(
            for: bundleURL
        ).standardizedFileURL
        let outputProvenanceURL =
            outputProvenance.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            } ?? GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: bundleURL)
                .standardizedFileURL
        let protectedArtifacts = [
            lockURL,
            manifestURL,
        ]
            + ProvenancePublicationArtifacts.sidecarArtifacts(
                for: sourceProvenanceURL
            )
            + ProvenancePublicationArtifacts.fileSidecarArtifacts(
                for: manifestURL
            )
            + ProvenancePublicationArtifacts.fileSidecarArtifacts(
                for: annotationURL
            )
        var protectedPaths = Set<String>()
        for url in protectedArtifacts {
            let path = url.standardizedFileURL.path
            guard protectedPaths.insert(path).inserted else {
                throw GenotypeReplayManualHaplotypeAssignmentsError
                    .pathCollision(path)
            }
        }
        let writableArtifacts = [annotationURL]
            + ProvenancePublicationArtifacts.sidecarArtifacts(
                for: outputProvenanceURL
            )
        var seenWritablePaths = Set<String>()
        for url in writableArtifacts {
            let path = url.standardizedFileURL.path
            guard seenWritablePaths.insert(path).inserted,
                  !protectedPaths.contains(path) else {
                throw GenotypeReplayManualHaplotypeAssignmentsError
                    .pathCollision(path)
            }
        }
    }

    private func validateOutputAvailability(
        _ outputProvenanceURL: URL
    ) throws {
        for url in ProvenancePublicationArtifacts.sidecarArtifacts(
            for: outputProvenanceURL
        ) where FileManager.default.fileExists(atPath: url.path) {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .outputExists(url.path)
        }
    }

    private func decodeReplayPayload(
        from envelope: ProvenanceEnvelope
    ) throws -> Data {
        let explicit = envelope.options.explicit
        let format = try requiredString("replayFormat", in: explicit)
        guard format
            == GenotypeManualHaplotypeAssignmentReplayPayload.format else {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .replayFormatMismatch(
                    expected:
                        GenotypeManualHaplotypeAssignmentReplayPayload.format,
                    actual: format
                )
        }
        let payloadData = try requiredBase64(
            "replayPayloadBase64",
            in: explicit
        )
        let expectedChecksum = try requiredString(
            "replayPayloadSHA256",
            in: explicit
        )
        let actualChecksum = sha256Hex(payloadData)
        guard expectedChecksum == actualChecksum else {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .checksumMismatch(
                    name: "Replay payload",
                    expected: expectedChecksum,
                    actual: actualChecksum
                )
        }
        return payloadData
    }

    private func requiredString(
        _ key: String,
        in values: [String: ParameterValue]
    ) throws -> String {
        guard let value = values[key]?.stringValue else {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .missingReplayValue(key)
        }
        return value
    }

    private func requiredBase64(
        _ key: String,
        in values: [String: ParameterValue]
    ) throws -> Data {
        let encoded = try requiredString(key, in: values)
        guard let data = Data(base64Encoded: encoded) else {
            throw GenotypeReplayManualHaplotypeAssignmentsError
                .invalidBase64(key)
        }
        return data
    }

    private func commandArgv(
        sourceProvenanceURL: URL,
        bundleURL: URL,
        outputProvenanceURL: URL
    ) -> [String] {
        var argv = [
            CLICommandIdentity.executableName,
            "genotype",
            GenotypeManualHaplotypeAssignmentReplayPayload.cliSubcommandName,
            "--provenance", sourceProvenanceURL.path,
            "--bundle", bundleURL.path,
        ]
        if outputProvenance != nil {
            argv += ["--output-provenance", outputProvenanceURL.path]
        }
        return argv
    }

    private func descriptor(
        data: Data,
        url: URL,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: sha256Hex(data),
            fileSize: UInt64(data.count),
            format: .json,
            role: role
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
