// AlignmentReadExtractionModels.swift - Staged alignment extraction contracts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// A scientific stage performed while extracting reads from immutable
/// alignment evidence.
public enum AlignmentReadExtractionExecutionStage: String, Codable, Sendable, Equatable {
    case inputValidation
    case payloadStaging
    case publication
}

/// A complete, serializable record of one attempted scientific execution.
///
/// Records intentionally retain the exact argv that ran, including transaction
/// paths. The publisher rewrites durable payload descriptors to final paths
/// before it writes canonical provenance.
public struct AlignmentReadExtractionExecutionRecord: Codable, Sendable, Equatable {
    public let stage: AlignmentReadExtractionExecutionStage
    public let workflowName: String
    public let workflowVersion: String
    public let toolName: String
    public let toolVersion: String
    public let executablePath: String?
    public let executableChecksumSHA256: String?
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let reproducibleCommand: String
    public let visibleOptions: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity
    public let inputs: [ProvenanceFileDescriptor]
    public let outputs: [ProvenanceFileDescriptor]
    public let exitStatus: Int?
    public let startedAt: Date
    public let completedAt: Date
    public let stderr: String?

    public init(
        stage: AlignmentReadExtractionExecutionStage,
        workflowName: String = "lungfish alignment read extraction",
        workflowVersion: String = WorkflowRun.currentAppVersion,
        toolName: String,
        toolVersion: String,
        executablePath: String? = nil,
        executableChecksumSHA256: String? = nil,
        argv: [String],
        durableReplayArgv: [String]? = nil,
        reproducibleCommand: String? = nil,
        visibleOptions: [String: ParameterValue] = [:],
        resolvedDefaults: [String: ParameterValue] = [:],
        runtimeIdentity: ProvenanceRuntimeIdentity = .init(),
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        exitStatus: Int?,
        startedAt: Date,
        completedAt: Date,
        stderr: String? = nil
    ) {
        self.stage = stage
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.executablePath = executablePath
        self.executableChecksumSHA256 = executableChecksumSHA256
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.reproducibleCommand = reproducibleCommand ?? argv.map(shellEscape).joined(separator: " ")
        self.visibleOptions = visibleOptions
        self.resolvedDefaults = resolvedDefaults
        self.runtimeIdentity = runtimeIdentity
        self.inputs = inputs
        self.outputs = outputs
        self.exitStatus = exitStatus
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.stderr = ProvenanceStderr.normalized(stderr)
    }

    public var wallTimeSeconds: TimeInterval {
        max(0, completedAt.timeIntervalSince(startedAt))
    }
}

/// A payload owned by an extraction transaction. It is never a caller-owned
/// final URL, and must be promoted only by ``AlignmentReadExtractionPublisher``.
public struct AlignmentReadExtractionStagedFile: Sendable, Equatable {
    public let stagedURL: URL
    public let relativeFinalPath: String
    public let format: FileFormat?

    public init(stagedURL: URL, relativeFinalPath: String, format: FileFormat? = nil) {
        self.stagedURL = stagedURL.standardizedFileURL
        self.relativeFinalPath = relativeFinalPath
        self.format = format
    }
}

/// The final output form selected by the App after it captures immutable
/// evidence context. Workflow owns how this destination is published.
public enum AlignmentReadExtractionPublicationDestination: Sendable, Equatable {
    case bundle(URL)
    case file(URL)

    public var finalURL: URL {
        switch self {
        case .bundle(let url), .file(let url):
            return url.standardizedFileURL
        }
    }
}

/// Context used to construct canonical final-output provenance.
public struct AlignmentReadExtractionProvenance: Sendable, Equatable {
    public let workflowName: String
    public let workflowVersion: String
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let explicitOptions: [String: ParameterValue]
    public let defaults: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]
    public let inputURLs: [URL]
    public let runtimeIdentity: ProvenanceRuntimeIdentity

    public init(
        workflowName: String,
        workflowVersion: String = WorkflowRun.currentAppVersion,
        toolName: String = "Lungfish.app",
        toolVersion: String = WorkflowRun.currentAppVersion,
        argv: [String],
        durableReplayArgv: [String]? = nil,
        explicitOptions: [String: ParameterValue] = [:],
        defaults: [String: ParameterValue] = [:],
        resolvedDefaults: [String: ParameterValue] = [:],
        inputURLs: [URL],
        runtimeIdentity: ProvenanceRuntimeIdentity = .init()
    ) {
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.explicitOptions = explicitOptions
        self.defaults = defaults
        self.resolvedDefaults = resolvedDefaults
        self.inputURLs = inputURLs.map(\.standardizedFileURL)
        self.runtimeIdentity = runtimeIdentity
    }
}

/// A request to atomically turn a staged transaction into a durable scientific
/// artifact.
public struct AlignmentReadExtractionPublicationRequest: Sendable {
    public let transaction: AlignmentReadExtractionTransaction
    public let destination: AlignmentReadExtractionPublicationDestination
    public let provenance: AlignmentReadExtractionProvenance

    public init(
        transaction: AlignmentReadExtractionTransaction,
        destination: AlignmentReadExtractionPublicationDestination,
        provenance: AlignmentReadExtractionProvenance
    ) {
        self.transaction = transaction
        self.destination = destination
        self.provenance = provenance
    }
}

/// The only successful result that callers of the shared alignment action may
/// receive. Every URL is final and provenance-bearing.
public struct AlignmentReadExtractionPublicationResult: Sendable, Equatable {
    public let finalURL: URL
    public let outputURLs: [URL]
    public let provenanceURL: URL
    public let readCount: Int
    public let pairedEnd: Bool
    public let recordsWithoutSequence: Int
    public let missingSequenceMessage: String?
    public let executionRecords: [AlignmentReadExtractionExecutionRecord]

    public init(
        finalURL: URL,
        outputURLs: [URL],
        provenanceURL: URL,
        readCount: Int,
        pairedEnd: Bool,
        recordsWithoutSequence: Int = 0,
        missingSequenceMessage: String? = nil,
        executionRecords: [AlignmentReadExtractionExecutionRecord]
    ) {
        self.finalURL = finalURL.standardizedFileURL
        self.outputURLs = outputURLs.map(\.standardizedFileURL)
        self.provenanceURL = provenanceURL.standardizedFileURL
        self.readCount = readCount
        self.pairedEnd = pairedEnd
        self.recordsWithoutSequence = recordsWithoutSequence
        self.missingSequenceMessage = missingSequenceMessage
        self.executionRecords = executionRecords
    }
}

/// Typed state of an alignment extraction failure. Every failure after a
/// scientific launch carries the records accumulated before it occurred.
public enum AlignmentReadExtractionFailureKind: String, Sendable, Equatable {
    case missingInput
    case staleInput
    case emptyExtraction
    case cancelled
    case launchFailed
    case subprocessFailed
    case publicationFailed
}

public struct AlignmentReadExtractionFailure: Error, LocalizedError, Sendable, Equatable {
    public let kind: AlignmentReadExtractionFailureKind
    public let message: String
    public let executionRecords: [AlignmentReadExtractionExecutionRecord]

    public init(
        kind: AlignmentReadExtractionFailureKind,
        message: String,
        executionRecords: [AlignmentReadExtractionExecutionRecord]
    ) {
        self.kind = kind
        self.message = message
        self.executionRecords = executionRecords
    }

    public var errorDescription: String? { message }
}
