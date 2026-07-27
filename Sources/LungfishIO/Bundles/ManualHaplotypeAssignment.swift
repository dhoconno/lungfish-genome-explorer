import Foundation
import LungfishCore

public struct ManualHaplotypeAssignment: Codable, Equatable, Sendable {
    public var sample: String
    public var locus: String
    public var slot: HaplotypeSlot
    public var label: String
    public var colorTokenIndex: Int
    public var diagnosticAlleles: [String]
    public var notes: String
    public var assignmentID: String?
    public var updatedAt: String?
    public var author: String?

    public init(sample: String, locus: String, slot: HaplotypeSlot, label: String,
                colorTokenIndex: Int, diagnosticAlleles: [String], notes: String) {
        self.init(
            sample: sample,
            locus: locus,
            slot: slot,
            label: label,
            colorTokenIndex: colorTokenIndex,
            diagnosticAlleles: diagnosticAlleles,
            notes: notes,
            assignmentID: nil,
            updatedAt: nil,
            author: nil
        )
    }

    public init(sample: String, locus: String, slot: HaplotypeSlot, label: String,
                colorTokenIndex: Int, diagnosticAlleles: [String], notes: String,
                assignmentID: String?, updatedAt: String?, author: String?) {
        self.sample = sample
        self.locus = locus
        self.slot = slot
        self.label = label
        self.colorTokenIndex = colorTokenIndex
        self.diagnosticAlleles = diagnosticAlleles
        self.notes = notes
        self.assignmentID = assignmentID
        self.updatedAt = updatedAt
        self.author = author
    }
}

public extension ManualHaplotypeAssignment {
    static func groupedByLabel(_ assignments: [ManualHaplotypeAssignment]) -> [String: [ManualHaplotypeAssignment]] {
        Dictionary(grouping: assignments, by: \.label)
    }

    static func groupedByLocusAndLabel(_ assignments: [ManualHaplotypeAssignment]) -> [String: [String: [ManualHaplotypeAssignment]]] {
        let byLocus = Dictionary(grouping: assignments, by: \.locus)
        return byLocus.mapValues { Dictionary(grouping: $0, by: \.label) }
    }
}
