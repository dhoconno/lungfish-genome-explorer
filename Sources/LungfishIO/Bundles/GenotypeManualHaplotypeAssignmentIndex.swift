import Foundation
import LungfishCore

public struct GenotypeManualHaplotypeAssignmentKey: Hashable, Sendable {
    public let sample: String
    public let locus: GenotypeManualHaplotypeLocus
    public let slot: HaplotypeSlot

    public init(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        self.sample = sample
        self.locus = locus
        self.slot = slot
    }

    public static func == (
        lhs: GenotypeManualHaplotypeAssignmentKey,
        rhs: GenotypeManualHaplotypeAssignmentKey
    ) -> Bool {
        lhs.sample == rhs.sample
            && lhs.locus == rhs.locus
            && lhs.slot.rawValue == rhs.slot.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sample)
        hasher.combine(locus)
        hasher.combine(slot.rawValue)
    }
}

public struct GenotypeManualHaplotypeSlotAssignments: Equatable, Sendable {
    public let h1: ManualHaplotypeAssignment?
    public let h2: ManualHaplotypeAssignment?

    public init(
        h1: ManualHaplotypeAssignment?,
        h2: ManualHaplotypeAssignment?
    ) {
        self.h1 = h1
        self.h2 = h2
    }

    public subscript(slot: HaplotypeSlot) -> ManualHaplotypeAssignment? {
        switch slot {
        case .h1: h1
        case .h2: h2
        }
    }
}

public struct GenotypeManualHaplotypeLabelCatalogEntry: Equatable, Sendable {
    public let label: String
    public let colorTokenIndex: Int

    public init(label: String, colorTokenIndex: Int) {
        self.label = label
        self.colorTokenIndex = colorTokenIndex
    }
}

/// Immutable lookup state for rendering and editing manual haplotype assignments.
///
/// Construction makes one O(n) source pass to resolve semantic assignment keys
/// and label/color conflicts, then sorts the resolved key and catalog sets for
/// deterministic output (O(k log k), where k is the number of resolved keys
/// plus valid unique labels). Key and catalog lookups are dictionary-backed
/// and constant-time.
public struct GenotypeManualHaplotypeAssignmentIndex: Sendable {
    public typealias LabelCatalogEntry = GenotypeManualHaplotypeLabelCatalogEntry

    public let assignmentsByKey: [
        GenotypeManualHaplotypeAssignmentKey: ManualHaplotypeAssignment
    ]
    public let currentAssignments: [ManualHaplotypeAssignment]
    public let labelCatalog: [LabelCatalogEntry]

    private let catalogByNormalizedLabel: [String: LabelCatalogEntry]

    public init(assignments: [ManualHaplotypeAssignment]) {
        struct RankedAssignment {
            let assignment: ManualHaplotypeAssignment
            let updatedAt: Date?
            let position: Int
        }
        struct CatalogCandidate {
            let ranked: RankedAssignment
            let displayLabel: String
        }

        var assignmentsByKey: [
            GenotypeManualHaplotypeAssignmentKey: RankedAssignment
        ] = [:]
        var catalogByNormalizedLabel: [String: CatalogCandidate] = [:]
        assignmentsByKey.reserveCapacity(assignments.count)
        catalogByNormalizedLabel.reserveCapacity(assignments.count)

        let fractionalTimestampFormatter = ISO8601DateFormatter()
        fractionalTimestampFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]
        let canonicalColorIndices = Set(
            HaplotypeColorToken.canonicalPalette.map(\.canonicalIndex)
        )

        for (position, assignment) in assignments.enumerated() {
            let updatedAt = assignment.updatedAt.flatMap {
                fractionalTimestampFormatter.date(from: $0)
                    ?? timestampFormatter.date(from: $0)
            }
            let ranked = RankedAssignment(
                assignment: assignment,
                updatedAt: updatedAt,
                position: position
            )

            guard let locus = GenotypeManualHaplotypeLocus(
                normalizing: assignment.locus
            ) else {
                continue
            }
            let key = GenotypeManualHaplotypeAssignmentKey(
                sample: assignment.sample,
                locus: locus,
                slot: assignment.slot
            )
            if let existing = assignmentsByKey[key] {
                if Self.shouldReplace(
                    existingDate: existing.updatedAt,
                    existingPosition: existing.position,
                    candidateDate: updatedAt,
                    candidatePosition: position
                ) {
                    assignmentsByKey[key] = ranked
                }
            } else {
                assignmentsByKey[key] = ranked
            }

            guard let displayLabel = try? GenotypeManualHaplotypeAssignmentInputValidator
                .validatedLabel(assignment.label),
                  let normalizedLabel = try? GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: displayLabel) else {
                continue
            }
            let candidate = CatalogCandidate(
                ranked: ranked,
                displayLabel: displayLabel
            )
            if let existing = catalogByNormalizedLabel[normalizedLabel] {
                if Self.shouldReplace(
                    existingDate: existing.ranked.updatedAt,
                    existingPosition: existing.ranked.position,
                    candidateDate: updatedAt,
                    candidatePosition: position
                ) {
                    catalogByNormalizedLabel[normalizedLabel] = candidate
                }
            } else {
                catalogByNormalizedLabel[normalizedLabel] = candidate
            }
        }

        let resolvedAssignments = assignmentsByKey.mapValues(\.assignment)
        self.assignmentsByKey = resolvedAssignments
        self.currentAssignments = resolvedAssignments
            .sorted { Self.assignmentSortKey($0.key) < Self.assignmentSortKey($1.key) }
            .map(\.value)

        let orderedCatalog = catalogByNormalizedLabel
            .sorted { $0.key < $1.key }
            .map { normalizedLabel, candidate in
                let storedColorIndex = candidate.ranked.assignment.colorTokenIndex
                let resolvedColorIndex = canonicalColorIndices.contains(storedColorIndex)
                    ? storedColorIndex
                    : HaplotypeColorToken.assigned(
                        forName: normalizedLabel
                    ).canonicalIndex
                return (
                    normalizedLabel,
                    LabelCatalogEntry(
                        label: candidate.displayLabel,
                        colorTokenIndex: resolvedColorIndex
                    )
                )
            }
        self.labelCatalog = orderedCatalog.map(\.1)
        self.catalogByNormalizedLabel = Dictionary(
            uniqueKeysWithValues: orderedCatalog
        )
    }

    public var count: Int {
        assignmentsByKey.count
    }

    public func assignment(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) -> ManualHaplotypeAssignment? {
        assignmentsByKey[
            GenotypeManualHaplotypeAssignmentKey(
                sample: sample,
                locus: locus,
                slot: slot
            )
        ]
    }

    public func assignment(
        for key: GenotypeManualHaplotypeAssignmentKey
    ) -> ManualHaplotypeAssignment? {
        assignmentsByKey[key]
    }

    public subscript(
        sample sample: String,
        locus locus: GenotypeManualHaplotypeLocus,
        slot slot: HaplotypeSlot
    ) -> ManualHaplotypeAssignment? {
        assignment(sample: sample, locus: locus, slot: slot)
    }

    public func assignments(
        sample: String,
        locus: GenotypeManualHaplotypeLocus
    ) -> GenotypeManualHaplotypeSlotAssignments {
        GenotypeManualHaplotypeSlotAssignments(
            h1: assignment(sample: sample, locus: locus, slot: .h1),
            h2: assignment(sample: sample, locus: locus, slot: .h2)
        )
    }

    public func catalogEntry(for label: String) -> LabelCatalogEntry? {
        guard let key = try? GenotypeManualHaplotypeAssignmentInputValidator
            .normalizedLabelKey(for: label) else {
            return nil
        }
        return catalogByNormalizedLabel[key]
    }

    public var labels: [String] {
        labelCatalog.map(\.label)
    }

    private static func shouldReplace(
        existingDate: Date?,
        existingPosition: Int,
        candidateDate: Date?,
        candidatePosition: Int
    ) -> Bool {
        switch (existingDate, candidateDate) {
        case let (.some(existing), .some(candidate)):
            return candidate > existing
                || (candidate == existing && candidatePosition > existingPosition)
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        case (.none, .none):
            return candidatePosition > existingPosition
        }
    }

    private static func assignmentSortKey(
        _ key: GenotypeManualHaplotypeAssignmentKey
    ) -> String {
        let locusIndex = GenotypeManualHaplotypeLocus.allCases
            .firstIndex(of: key.locus) ?? 0
        let slotIndex = key.slot == .h1 ? 0 : 1
        return "\(key.sample)\u{0}\(locusIndex)\u{0}\(slotIndex)"
    }
}
