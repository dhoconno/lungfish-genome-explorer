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

/// Primer3's per-oligo and per-pair EXPLAIN lines.
///
/// A zero-pair run is the case that needs these. PRIMER_PAIR_EXPLAIN counts
/// only the pair-level tests, and it is reached only by primers that already
/// passed every single-oligo rule, so when a run returns nothing because a
/// primer was too hot or a probe too cold the pair line reports "considered 0"
/// and says nothing about the cause. The single-oligo lines carry the real
/// reason, which is why LGE surfaces all four rather than the pair line alone.
public struct Primer3Explanations: Codable, Sendable, Equatable {
    public let left: String?
    public let right: String?
    public let internalOligo: String?
    public let pair: String?

    public var isEmpty: Bool {
        [left, right, internalOligo, pair].allSatisfy { ($0 ?? "").isEmpty }
    }

    public init(left: String?, right: String?, internalOligo: String?, pair: String?) {
        self.left = left
        self.right = right
        self.internalOligo = internalOligo
        self.pair = pair
    }

    /// Labelled lines for display, skipping the ones Primer3 did not emit.
    public var labelledLines: [(label: String, text: String)] {
        [("Left primer", left), ("Right primer", right), ("Probe", internalOligo), ("Pair", pair)]
            .compactMap { label, text in
                guard let text, !text.isEmpty else { return nil }
                return (label, text)
            }
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
    /// PRIMER_PAIR_EXPLAIN, kept so records written before the per-oligo lines
    /// existed still decode and display unchanged.
    public let explanation: String?
    /// The per-oligo and per-pair EXPLAIN lines. `nil` in records written
    /// before LGE parsed them.
    public let explanations: Primer3Explanations?
    public init(resultID: UUID, inputID: UUID, title: String, sourceKind: String, sourceIndex: Int, sourceRecordID: String, templateSequence: String, alignmentToTemplate: [Int?]?, excludedRegions: [Primer3CoordinateRange], pairs: [Primer3Pair], error: String?, explanation: String?, explanations: Primer3Explanations? = nil) {
        self.resultID = resultID; self.inputID = inputID; self.title = title; self.sourceKind = sourceKind; self.sourceIndex = sourceIndex
        self.sourceRecordID = sourceRecordID
        self.templateSequence = templateSequence; self.alignmentToTemplate = alignmentToTemplate; self.excludedRegions = excludedRegions
        self.pairs = pairs; self.error = error; self.explanation = explanation
        self.explanations = explanations
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
