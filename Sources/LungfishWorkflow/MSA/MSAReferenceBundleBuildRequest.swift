import Foundation
import LungfishCore
import LungfishIO

public struct MSAReferenceBundleBuildRequest: Sendable, Equatable {
    public let sourceBundleURL: URL
    public let sourceBundleName: String
    public let sourceBundleChecksumSHA256: String
    public let sourceBundleFileSize: Int64
    public let inputAlignmentFileURL: URL
    public let outputBundleURL: URL
    public let name: String
    public let rowsOption: String?
    public let columnsOption: String?
    public let selectedColumnIntervals: [MSAReferenceColumnInterval]
    public let sequences: [MSAReferenceSequenceInput]
    public let sourceAnnotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord]
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
        rowsOption: String?,
        columnsOption: String?,
        selectedColumnIntervals: [MSAReferenceColumnInterval],
        sequences: [MSAReferenceSequenceInput],
        sourceAnnotations: [MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord] = [],
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
        self.rowsOption = rowsOption
        self.columnsOption = columnsOption
        self.selectedColumnIntervals = selectedColumnIntervals
        self.sequences = sequences
        self.sourceAnnotations = sourceAnnotations
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.workflowName = workflowName
        self.actionID = actionID
        self.toolName = toolName
        self.startedAt = startedAt
        self.force = force
    }
}
