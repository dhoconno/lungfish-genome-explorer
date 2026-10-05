import Foundation

/// How a tree was inferred, recorded in the tree manifest so the Inspector can show it.
///
/// The model fields come from the IQ-TREE report (`IQTreeReportParser`). The run fields come
/// from the options and alignment scope the inference ran with.
public struct PhylogeneticTreeInferenceSummary: Codable, Sendable, Equatable {
    public let program: String
    public let programVersion: String
    public let requestedModel: String
    public let bestFitModel: String?
    /// The criterion ModelFinder used, for example "BIC". Nil when a fixed model was requested.
    public let modelSelectionCriterion: String?
    public let substitutionModel: String?
    public let logLikelihood: Double?
    public let logLikelihoodStandardError: Double?
    public let freeParameters: Int?
    public let sequenceType: String
    public let seed: Int?
    public let threads: Int?
    public let outgroup: [String]?
    public let outgroupWarning: String?
    public let sourceAlignmentName: String?
    public let sourceAlignmentPath: String?
    public let selectedRowCount: Int
    public let totalRowCount: Int
    public let selectedColumns: String?
    public let alignedLength: Int

    public init(
        program: String,
        programVersion: String,
        requestedModel: String,
        bestFitModel: String? = nil,
        modelSelectionCriterion: String? = nil,
        substitutionModel: String? = nil,
        logLikelihood: Double? = nil,
        logLikelihoodStandardError: Double? = nil,
        freeParameters: Int? = nil,
        sequenceType: String,
        seed: Int? = nil,
        threads: Int? = nil,
        outgroup: [String]? = nil,
        outgroupWarning: String? = nil,
        sourceAlignmentName: String? = nil,
        sourceAlignmentPath: String? = nil,
        selectedRowCount: Int,
        totalRowCount: Int,
        selectedColumns: String? = nil,
        alignedLength: Int
    ) {
        self.program = program
        self.programVersion = programVersion
        self.requestedModel = requestedModel
        self.bestFitModel = bestFitModel
        self.modelSelectionCriterion = modelSelectionCriterion
        self.substitutionModel = substitutionModel
        self.logLikelihood = logLikelihood
        self.logLikelihoodStandardError = logLikelihoodStandardError
        self.freeParameters = freeParameters
        self.sequenceType = sequenceType
        self.seed = seed
        self.threads = threads
        self.outgroup = outgroup
        self.outgroupWarning = outgroupWarning
        self.sourceAlignmentName = sourceAlignmentName
        self.sourceAlignmentPath = sourceAlignmentPath
        self.selectedRowCount = selectedRowCount
        self.totalRowCount = totalRowCount
        self.selectedColumns = selectedColumns
        self.alignedLength = alignedLength
    }
}
