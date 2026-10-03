import Foundation
import LungfishCore
import LungfishIO

public struct MSAConsensusReferenceBundleBuildRequest: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let sourceBundleName: String
    public let sourceBundleChecksumSHA256: String
    public let sourceBundleFileSize: Int64
    public let inputAlignmentFileURL: URL
    public let outputBundleURL: URL
    public let name: String
    public let consensusSequence: String
    public let alignmentColumns: [Int]
    public let rowsOption: String?
    public let threshold: Double
    public let gapPolicy: String
    public let argv: [String]
    public let reproducibleCommand: String
    public let workflowName: String
    public let actionID: String
    public let toolName: String
    public let startedAt: Date
    public let force: Bool

    public init(
        sourceBundleURL: URL,
        sourceBundleName: String,
        sourceBundleChecksumSHA256: String,
        sourceBundleFileSize: Int64,
        inputAlignmentFileURL: URL,
        outputBundleURL: URL,
        name: String,
        consensusSequence: String,
        alignmentColumns: [Int],
        rowsOption: String?,
        threshold: Double,
        gapPolicy: String,
        argv: [String],
        reproducibleCommand: String,
        workflowName: String,
        actionID: String,
        toolName: String,
        startedAt: Date,
        force: Bool
    ) {
        self.sourceBundleURL = sourceBundleURL
        self.sourceBundleName = sourceBundleName
        self.sourceBundleChecksumSHA256 = sourceBundleChecksumSHA256
        self.sourceBundleFileSize = sourceBundleFileSize
        self.inputAlignmentFileURL = inputAlignmentFileURL
        self.outputBundleURL = outputBundleURL
        self.name = name
        self.consensusSequence = consensusSequence
        self.alignmentColumns = alignmentColumns
        self.rowsOption = rowsOption
        self.threshold = threshold
        self.gapPolicy = gapPolicy
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.workflowName = workflowName
        self.actionID = actionID
        self.toolName = toolName
        self.startedAt = startedAt
        self.force = force
    }
}
