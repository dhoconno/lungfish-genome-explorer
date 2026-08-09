import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

internal struct FullLengthONTMHCStagedRunResult: Sendable {
    let result: FullLengthONTMHCGenotypingResult
    let cohortWorkDirectory: URL
    let cohortTemporaryWorkDirectory: URL
    let candidateWorkDirectory: URL
}

internal struct GenotypingWorkDirectoryDisposition: Codable, Sendable {
    let path: String
    let disposition: String
    let error: String?
}

internal struct GenotypingWorkDirectoryDispositionEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let entries: [GenotypingWorkDirectoryDisposition]
}

internal struct FullLengthWorkDirectoryCleanupResult: Sendable {
    var warnings: [FullLengthONTMHCGenotypingCleanupWarning]
    var dispositions: [GenotypingWorkDirectoryDisposition]
}

internal struct FullLengthFailureProvenancePreparationError: Error, LocalizedError {
    let inputPath: String
    let operation: String
    let underlyingDescription: String
    let initiatingFailureDescription: String?

    init(
        inputURL: URL,
        operation: String,
        underlyingError: Error,
        initiatingError: Error? = nil
    ) {
        self.inputPath = inputURL.standardizedFileURL.path
        self.operation = operation
        self.underlyingDescription = underlyingError.localizedDescription
        self.initiatingFailureDescription = initiatingError?.localizedDescription
    }

    var errorDescription: String? {
        let initiating = initiatingFailureDescription.map {
            " after initiating failure (\($0))"
        } ?? ""
        return "failure-provenance input preparation failed for \(inputPath) while \(operation)\(initiating): \(underlyingDescription)"
    }
}

internal struct FullLengthFailureProvenancePreparationReceipt: Codable {
    let schemaVersion: Int
    let kind: String
    let runID: UUID
    let workflowName: String
    let workflowVersion: String
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let durableReplayArgv: [String]
    let reproducibleCommand: String
    let options: ProvenanceOptions
    let runtimeIdentity: ProvenanceRuntimeIdentity
    let inputPath: String
    let preparationError: String
    let originalError: String
    let startedAt: Date
    let completedAt: Date
    let wallTimeSeconds: TimeInterval
    let exitStatus: Int
    let stderr: String
}

enum FullLengthONTMHCMetadataPublicationEvent: Sendable, Equatable {
    case runLockAcquired(lockURL: URL)
    case candidateArtifactsStaged(outputDirectoryURL: URL)
    case provenanceWrittenBeforeManifestPublication(
        stagedManifestURL: URL,
        finalManifestURL: URL,
        provenanceURL: URL
    )
    case resultBundlePublishedBeforeReceipt(
        stagedDirectoryURL: URL,
        finalDirectoryURL: URL
    )
    case provenanceFinalizedBeforeManifestPublication(
        finalManifestURL: URL,
        provenanceURL: URL
    )
    case successManifestPublished(
        finalManifestURL: URL,
        provenanceURL: URL
    )
}

enum FullLengthONTMHCExclusivePublicationTarget: Sendable, Equatable {
    case resultBundle
    case successManifest
}

internal struct FullLengthONTMHCSuccessManifestPublicationPlan: Sendable {
    let stagedURL: URL
    let finalURL: URL
    let stagedDescriptor: ProvenanceFileDescriptor
    let finalDescriptor: ProvenanceFileDescriptor
}

internal struct FullLengthONTMHCReferenceVisualizationPublication: Sendable {
    let descriptor: ONTMHCReferenceVisualizationArtifacts
    let recordsJSONURL: URL
    let genBankURL: URL
    let fastaURL: URL

    var outputURLs: [URL] {
        [recordsJSONURL, genBankURL, fastaURL]
    }
}

internal struct FullLengthONTMHCReferenceVisualizationPublicationError: Error, LocalizedError {
    let step: ProvenanceStep
    let underlyingLocalizedDescription: String

    var errorDescription: String? {
        "MHC reference visualization extraction failed: \(underlyingLocalizedDescription)"
    }
}

internal struct FullLengthONTMHCResultBundlePublicationRecord: Sendable {
    let stagedDirectoryURL: URL
    let finalDirectoryURL: URL
    let payloadMappings: [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)]
    let replacingExisting: Bool
    let publicationMechanism: String
    let successManifestMechanism: String
    let fallbackReason: String?
    let startedAt: Date
    let completedAt: Date

    let exitStatus: Int32
    let errorMessage: String?

    private var receiptStartedAt: Date {
        Self.receiptDate(startedAt)
    }

    private var receiptCompletedAt: Date {
        Self.receiptDate(completedAt)
    }

    private static func receiptDate(_ date: Date) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: formatter.string(from: date)) ?? date
    }

    var provenanceStep: ProvenanceStep {
        let mode = replacingExisting ? "replace" : "create"
        let argv = [
            "lungfish-internal", "publish-result-bundle",
            "--mode", mode,
            "--atomic-mechanism", publicationMechanism,
            "--success-manifest-mechanism", successManifestMechanism,
            stagedDirectoryURL.path,
            finalDirectoryURL.path,
        ]
        var resolvedOptions: [String: ParameterValue] = [
            "publicationMode": .string(mode),
            "atomicMechanism": .string(publicationMechanism),
            "successManifestMechanism": .string(successManifestMechanism),
        ]
        if let fallbackReason {
            resolvedOptions["fallbackReason"] = .string(fallbackReason)
        }
        return ProvenanceStep(
            toolName: "lungfish-internal publish-result-bundle",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: resolvedOptions,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: payloadMappings.map(\.staged),
            outputs: payloadMappings.map(\.final),
            exitStatus: Int(exitStatus),
            wallTimeSeconds: receiptCompletedAt.timeIntervalSince(receiptStartedAt),
            stderr: errorMessage,
            startedAt: receiptStartedAt,
            completedAt: receiptCompletedAt
        )
    }

    func recordingSuccessManifestFallback(reason: String) -> Self {
        .init(
            stagedDirectoryURL: stagedDirectoryURL,
            finalDirectoryURL: finalDirectoryURL,
            payloadMappings: payloadMappings,
            replacingExisting: replacingExisting,
            publicationMechanism: publicationMechanism,
            successManifestMechanism: "exclusive-file-reservation-then-rename",
            fallbackReason: [fallbackReason, reason].compactMap { $0 }.joined(separator: "; "),
            startedAt: startedAt,
            completedAt: completedAt,
            exitStatus: exitStatus,
            errorMessage: errorMessage
        )
    }
}

internal struct FullLengthONTMHCResultBundlePublicationError: Error, LocalizedError, Sendable {
    let record: FullLengthONTMHCResultBundlePublicationRecord

    var errorDescription: String? {
        "Could not atomically publish the complete MHC result bundle: \(record.errorMessage ?? "unknown error")"
    }
}

internal struct FullLengthONTMHCExclusiveRenameUnsupportedError: Error, LocalizedError, Sendable {
    let targetDescription: String
    let code: POSIXErrorCode

    var errorDescription: String? {
        "renameatx_np(RENAME_EXCL) is unavailable for \(targetDescription): \(POSIXError(code).localizedDescription)"
    }
}

internal struct FullLengthONTMHCRollbackFailureRecovery: Sendable {
    let retainedPriorGenerationURL: URL?
    let retainedFailedPublishedGenerationURL: URL?
    let quarantineError: String?

    var retainedRoots: [URL] {
        [retainedPriorGenerationURL, retainedFailedPublishedGenerationURL].compactMap { $0 }
    }
}
