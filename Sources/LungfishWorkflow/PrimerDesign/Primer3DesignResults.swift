import Foundation

public enum Primer3OligoOrientation: String, Codable, Sendable { case forward, reverse }

public struct Primer3CoordinateRange: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

public struct Primer3Oligo: Codable, Sendable, Equatable {
    public let id: UUID
    public let start: Int
    public let end: Int
    public let orientation: Primer3OligoOrientation
    public let sequence: String
    public let meltingTemperature: Double
    public let gcPercent: Double
    public init(id: UUID, start: Int, end: Int, orientation: Primer3OligoOrientation, sequence: String, meltingTemperature: Double, gcPercent: Double) {
        self.id = id; self.start = start; self.end = end; self.orientation = orientation
        self.sequence = sequence; self.meltingTemperature = meltingTemperature; self.gcPercent = gcPercent
    }
}

public struct Primer3Pair: Codable, Sendable, Equatable {
    public let id: UUID
    public let left: Primer3Oligo
    public let right: Primer3Oligo
    public let internalOligo: Primer3Oligo?
    public let productSize: Int
    public init(id: UUID, left: Primer3Oligo, right: Primer3Oligo, internalOligo: Primer3Oligo?, productSize: Int) {
        self.id = id; self.left = left; self.right = right; self.internalOligo = internalOligo; self.productSize = productSize
    }
}

public struct Primer3TemplateResult: Codable, Sendable, Equatable {
    public let resultID: UUID
    public let inputID: UUID
    public let title: String
    public let sourceKind: String
    public let sourceIndex: Int
    public let sourceRecordID: String
    public let templateSequence: String
    public let alignmentToTemplate: [Int?]?
    public let excludedRegions: [Primer3CoordinateRange]
    public let pairs: [Primer3Pair]
    public let error: String?
    public let explanation: String?
    public init(resultID: UUID, inputID: UUID, title: String, sourceKind: String, sourceIndex: Int, sourceRecordID: String, templateSequence: String, alignmentToTemplate: [Int?]?, excludedRegions: [Primer3CoordinateRange], pairs: [Primer3Pair], error: String?, explanation: String?) {
        self.resultID = resultID; self.inputID = inputID; self.title = title; self.sourceKind = sourceKind; self.sourceIndex = sourceIndex
        self.sourceRecordID = sourceRecordID
        self.templateSequence = templateSequence; self.alignmentToTemplate = alignmentToTemplate; self.excludedRegions = excludedRegions
        self.pairs = pairs; self.error = error; self.explanation = explanation
    }
}

public struct Primer3NormalizedResults: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let analysisID: UUID
    public let runID: UUID
    public let results: [Primer3TemplateResult]

    public init(analysisID: UUID, runID: UUID, results: [Primer3TemplateResult]) {
        schemaVersion = Self.schemaVersion
        self.analysisID = analysisID
        self.runID = runID
        self.results = results
    }
}
