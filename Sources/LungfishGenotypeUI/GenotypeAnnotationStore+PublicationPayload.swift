import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension GenotypeAnnotationStore {
    struct ProvenanceEditContext: Sendable {
        var explicitOptions: [String: ParameterValue]
        var resolvedDefaults: [String: ParameterValue]
        var resolvedAuthor: String?
        var replayPayload: GenotypeMatrixAnnotationReplayPayload?
        var manualHaplotypeReplayPayload:
            GenotypeManualHaplotypeAssignmentReplayPayload?
        var callOverrideReplayPayload:
            GenotypeCallOverrideReplayPayload?

        init(
            explicitOptions: [String: ParameterValue],
            resolvedDefaults: [String: ParameterValue] = [:],
            resolvedAuthor: String? = nil,
            replayPayload: GenotypeMatrixAnnotationReplayPayload? = nil,
            manualHaplotypeReplayPayload:
                GenotypeManualHaplotypeAssignmentReplayPayload? = nil,
            callOverrideReplayPayload:
                GenotypeCallOverrideReplayPayload? = nil
        ) {
            self.explicitOptions = explicitOptions
            self.resolvedDefaults = resolvedDefaults
            self.resolvedAuthor = resolvedAuthor
            self.replayPayload = replayPayload
            self.manualHaplotypeReplayPayload =
                manualHaplotypeReplayPayload
            self.callOverrideReplayPayload = callOverrideReplayPayload
        }
    }

    func decodedLatestSidecar(from data: Data?) throws -> GenotypeAnnotationSidecar {
        guard let data else {
            return GenotypeAnnotationSidecar.empty(generatedAt: lastPersistedSidecar.generatedAt)
        }
        return try GenotypeAnnotationSidecar.decode(data)
    }

    /// Builds the pair a publication writes. It reads no state of the store, so it runs on the
    /// thread that publishes (2.11 S35).
    nonisolated func annotationPublicationPayload(
        sidecar: GenotypeAnnotationSidecar,
        action: String,
        editContext: ProvenanceEditContext?,
        snapshot: GenotypeAnnotationPublicationSnapshot,
        unsavedBuiltInSmartCohorts: [GenotypeCohortSmartFilter],
        startedAt: Date,
        endedAt: Date
    ) throws -> GenotypeAnnotationPublicationPayload {
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        reportPublicationStage(.encode)
        let annotationData = try sidecar.encoded()
        let output = provenanceDescriptor(data: annotationData, url: annotationURL, role: .output)
        let envelope = try makeAnnotationProvenance(
            sidecar: sidecar,
            action: action,
            annotationURL: annotationURL,
            priorData: snapshot.annotationData,
            output: output,
            editContext: editContext,
            unsavedBuiltInSmartCohorts: unsavedBuiltInSmartCohorts,
            startedAt: startedAt,
            endedAt: endedAt
        )
        var encoded = try JSONSerialization.jsonObject(with: ProvenanceWriter.package(envelope)) as! [String: Any]
        if let previousData = snapshot.provenanceData,
           let previous = try JSONSerialization.jsonObject(with: previousData) as? [String: Any],
           let previousOptions = previous["options"] as? [String: Any],
           let previousExplicit = previousOptions["explicit"] as? [String: Any],
           let accepted = previousExplicit["acceptedEditableWorkbook"] {
            var options = encoded["options"] as? [String: Any] ?? [:]
            var explicit = options["explicit"] as? [String: Any] ?? [:]
            explicit["acceptedEditableWorkbook"] = accepted
            options["explicit"] = explicit
            encoded["options"] = options
        }
        return try GenotypeAnnotationPublicationPayload(annotationData: annotationData, provenanceData: JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]))
    }

    private nonisolated func provenanceDescriptor(
        data: Data,
        url: URL,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        reportPublicationStage(.digest)
        return ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            fileSize: UInt64(data.count),
            format: .json,
            role: role
        )
    }

    private nonisolated func makeAnnotationProvenance(
        sidecar: GenotypeAnnotationSidecar,
        action: String,
        annotationURL: URL,
        priorData: Data?,
        output: ProvenanceFileDescriptor,
        editContext: ProvenanceEditContext?,
        unsavedBuiltInSmartCohorts: [GenotypeCohortSmartFilter],
        startedAt: Date,
        endedAt: Date
    ) throws -> ProvenanceEnvelope {
        let executionArgv = CommandLine.arguments
        var explicitOptions: [String: ParameterValue] = [
            "bundle": .file(bundleURL),
            "annotationSidecar": .file(annotationURL),
            "action": .string(action),
            "executionMode": .string("gui-edit"),
        ]
        if let editContext {
            explicitOptions.merge(editContext.explicitOptions) { _, payload in payload }
        }
        explicitOptions.merge(Self.seededBuiltInSmartCohortOptions(unsavedBuiltInSmartCohorts, publishing: sidecar)) {
            current, _ in current
        }
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let durableReplayArgv: [String]?
        if editContext?.callOverrideReplayPayload != nil {
            let replayOutputProvenanceURL =
                GenotypeCallOverrideReplayPayload
                    .replayOutputProvenanceURL(
                        forBundleAt: bundleURL
                    )
            durableReplayArgv = [
                CLICommandIdentity.executableName,
                "genotype",
                GenotypeCallOverrideReplayPayload.cliSubcommandName,
                "--provenance", provenanceURL.path,
                "--bundle", bundleURL.standardizedFileURL.path,
            ]
            explicitOptions["replayOutputProvenance"] =
                .file(replayOutputProvenanceURL)
        } else if editContext?.manualHaplotypeReplayPayload != nil {
            let replayOutputProvenanceURL =
                GenotypeManualHaplotypeAssignmentReplayPayload
                    .replayOutputProvenanceURL(
                        forBundleAt: bundleURL
                    )
            durableReplayArgv = [
                CLICommandIdentity.executableName,
                "genotype",
                GenotypeManualHaplotypeAssignmentReplayPayload
                    .cliSubcommandName,
                "--provenance", provenanceURL.path,
                "--bundle", bundleURL.standardizedFileURL.path,
            ]
            explicitOptions["replayOutputProvenance"] =
                .file(replayOutputProvenanceURL)
        } else if editContext?.replayPayload != nil {
            let replayOutputProvenanceURL =
                GenotypeMatrixAnnotationReplayPayload
                    .replayOutputProvenanceURL(for: annotationURL)
            durableReplayArgv = [
                CLICommandIdentity.executableName,
                "genotype",
                GenotypeMatrixAnnotationReplayPayload.cliSubcommandName,
                "--provenance", provenanceURL.path,
                "--output", annotationURL.path,
                "--output-provenance", replayOutputProvenanceURL.path,
                "--force",
            ]
            explicitOptions["replayOutputProvenance"] = .file(replayOutputProvenanceURL)
        } else {
            durableReplayArgv = nil
        }
        let reproducibleCommand = (durableReplayArgv ?? executionArgv)
            .map(shellEscape)
            .joined(separator: " ")
        var inputs: [ProvenanceFileDescriptor] = []
        if let priorData {
            let checksum = sha256Hex(priorData)
            explicitOptions["replayPriorSidecarBase64"] = .string(priorData.base64EncodedString())
            inputs.append(ProvenanceFileDescriptor(
                path: provenanceURL.path + "#/options/explicit/replayPriorSidecarBase64",
                checksumSHA256: checksum,
                fileSize: UInt64(priorData.count),
                format: .json,
                role: .input,
                originPath: annotationURL.path
            ))
        }
        if let replayPayload = editContext?.callOverrideReplayPayload {
            let replayData = try replayPayload.encoded()
            explicitOptions["replayFormat"] = .string(
                GenotypeCallOverrideReplayPayload.format
            )
            explicitOptions["replayPayloadBase64"] = .string(
                replayData.base64EncodedString()
            )
            explicitOptions["replayPayloadSHA256"] = .string(
                sha256Hex(replayData)
            )
        } else if let replayPayload = editContext?.replayPayload {
            let replayData = try replayPayload.encoded()
            explicitOptions["replayFormat"] = .string(GenotypeMatrixAnnotationReplayPayload.format)
            explicitOptions["replayPayloadBase64"] = .string(replayData.base64EncodedString())
            explicitOptions["replayPayloadSHA256"] = .string(sha256Hex(replayData))
        } else if let replayPayload =
            editContext?.manualHaplotypeReplayPayload {
            let replayData = try replayPayload.encoded()
            explicitOptions["replayFormat"] = .string(
                GenotypeManualHaplotypeAssignmentReplayPayload.format
            )
            explicitOptions["replayPayloadBase64"] = .string(
                replayData.base64EncodedString()
            )
            explicitOptions["replayPayloadSHA256"] = .string(
                sha256Hex(replayData)
            )
        }
        if let replayPayload = editContext?.callOverrideReplayPayload {
            inputs.append(ProvenanceFileDescriptor(
                path: bundleURL.appendingPathComponent(
                    replayPayload.targetBundle.manifest.path
                ).path,
                checksumSHA256:
                    replayPayload.targetBundle.manifest.checksumSHA256,
                fileSize: replayPayload.targetBundle.manifest.fileSize,
                format: .json,
                role: .input
            ))
        } else if let replayPayload =
            editContext?.manualHaplotypeReplayPayload {
            inputs.append(ProvenanceFileDescriptor(
                path: bundleURL.appendingPathComponent(
                    replayPayload.targetBundle.manifest.path
                ).path,
                checksumSHA256:
                    replayPayload.targetBundle.manifest.checksumSHA256,
                fileSize:
                    replayPayload.targetBundle.manifest.fileSize,
                format: .json,
                role: .input
            ))
        }
        let wallTime = max(0, endedAt.timeIntervalSince(startedAt))
        let resolvedAuthor = editContext?.resolvedAuthor
            ?? sidecar.auditLog.last?.author
            ?? author
        var resolvedDefaults: [String: ParameterValue] = [
            "author": .string(resolvedAuthor),
            "auditEntryCount": .integer(sidecar.auditLog.count),
            "callOverrideCount": .integer(sidecar.callOverrides.count),
            "matrixStyleCount": .integer(sidecar.matrixStyles.count),
            "matrixCommentCount": .integer(sidecar.matrixComments.count),
            "matrixReviewCount": .integer(sidecar.matrixReviews.count),
            "manualHaplotypeAssignmentCount": .integer(sidecar.manualHaplotypeAssignments.count),
            "smartCohortCount": .integer(sidecar.smartCohorts.count),
        ]
        if let editContext {
            resolvedDefaults.merge(editContext.resolvedDefaults) {
                _, mutationValue in mutationValue
            }
        }
        if action == "setMatrixReview" {
            resolvedDefaults["absentEvidence"] = .string("unknown")
            resolvedDefaults["reviewEligibilityPolicyVersion"] = .integer(GenotypeMatrixReviewEligibility.version)
            resolvedDefaults["supportThreshold"] = .string("passedUniqueReads > 0")
        }
        let step = ProvenanceStep(
            toolName: LungfishAppIdentity.recordedToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: executionArgv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            resolvedOptions: resolvedDefaults,
            runtimeIdentity: ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser),
            inputs: inputs,
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: wallTime,
            startedAt: startedAt,
            completedAt: endedAt
        )
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "Genotype annotation sidecar edit",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: LungfishAppIdentity.recordedToolName,
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(
                name: LungfishAppIdentity.recordedToolName,
                version: WorkflowRun.currentAppVersion,
                kind: LungfishAppIdentity.recordedToolKind
            ),
            argv: executionArgv,
            durableReplayArgv: durableReplayArgv,
            reproducibleCommand: reproducibleCommand,
            options: ProvenanceOptions(
                explicit: explicitOptions,
                defaults: [
                    "format": .string("json"),
                    "sidecarFilename": .string(GenotypeAnnotationSidecar.filename),
                ],
                resolvedDefaults: resolvedDefaults
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser),
            files: inputs + [output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: wallTime,
            exitStatus: 0,
            stderr: ""
        )
    }

    nonisolated func sha256Hex(_ data: Data) -> String {
        reportPublicationStage(.digest)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
