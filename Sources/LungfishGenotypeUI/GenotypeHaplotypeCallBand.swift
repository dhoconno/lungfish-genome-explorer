import Foundation
import LungfishCore
import LungfishIO

enum GenotypeHaplotypeBandMode: Equatable, Sendable {
    case none
    case manualAssignments
    case effectiveMiSeqCalls
}

struct GenotypeHaplotypeBandTarget: Hashable, Sendable {
    let sample: String
    let locus: String
    let slot: HaplotypeSlot
}

struct GenotypeHaplotypeCallBandSlotValue: Equatable, Sendable {
    let value: String
    let status: GenotypeHaplotypeCallStatus
    let source: GenotypeEffectiveHaplotypeValue.Source
    let isEditable: Bool
}

struct GenotypeHaplotypeCallBandLocusCall: Equatable, Sendable {
    let sample: String
    let locus: String
    let h1: GenotypeHaplotypeCallBandSlotValue
    let h2: GenotypeHaplotypeCallBandSlotValue

    func value(for slot: HaplotypeSlot) -> GenotypeHaplotypeCallBandSlotValue {
        switch slot {
        case .h1: return h1
        case .h2: return h2
        }
    }
}

/// Neutral presentation snapshot for effective miSeq calls in a genotype
/// matrix. It deliberately contains no manual-assignment records or editor
/// state; both call surfaces can build it from the same effective projection.
struct GenotypeHaplotypeCallBandSnapshot: Equatable, Sendable {
    static let empty = GenotypeHaplotypeCallBandSnapshot(
        orderedLoci: [],
        calls: []
    )

    let orderedLoci: [String]
    let calls: [GenotypeHaplotypeCallBandLocusCall]

    private let valuesByTarget:
        [GenotypeHaplotypeBandTarget: GenotypeHaplotypeCallBandSlotValue]
    private let valuesBySample:
        [String: [GenotypeHaplotypeBandTarget: GenotypeHaplotypeCallBandSlotValue]]

    init(
        orderedLoci: [String],
        calls: [GenotypeHaplotypeCallBandLocusCall]
    ) {
        var seenLoci = Set<String>()
        self.orderedLoci = orderedLoci.filter {
            !$0.isEmpty && seenLoci.insert($0).inserted
        }
        self.calls = calls

        var valuesByTarget:
            [GenotypeHaplotypeBandTarget: GenotypeHaplotypeCallBandSlotValue] = [:]
        var valuesBySample:
            [String: [GenotypeHaplotypeBandTarget: GenotypeHaplotypeCallBandSlotValue]] = [:]
        for call in calls {
            for slot in HaplotypeSlot.allCases {
                let target = GenotypeHaplotypeBandTarget(
                    sample: call.sample,
                    locus: call.locus,
                    slot: slot
                )
                let value = call.value(for: slot)
                valuesByTarget[target] = value
                valuesBySample[call.sample, default: [:]][target] = value
            }
        }
        self.valuesByTarget = valuesByTarget
        self.valuesBySample = valuesBySample
    }

    init(
        projection: GenotypeEffectiveHaplotypeProjection,
        orderedLoci: [String]? = nil,
        isEditable: Bool
    ) {
        let orderedLoci = orderedLoci ?? projection.orderedLoci
        var calls: [GenotypeHaplotypeCallBandLocusCall] = []
        calls.reserveCapacity(
            projection.orderedSamples.count * orderedLoci.count
        )
        for sample in projection.orderedSamples {
            for locus in orderedLoci {
                guard let snapshot = projection.snapshot(
                    sample: sample,
                    locus: locus
                ) else {
                    continue
                }
                calls.append(
                    .init(
                        sample: sample,
                        locus: locus,
                        h1: Self.bandValue(
                            snapshot.h1,
                            isEditable: isEditable
                        ),
                        h2: Self.bandValue(
                            snapshot.h2,
                            isEditable: isEditable
                        )
                    )
                )
            }
        }
        self.init(orderedLoci: orderedLoci, calls: calls)
    }

    var disclosureTitle: String {
        "Haplotype Calls (\(orderedLoci.count) loci)"
    }

    var sampleNames: Set<String> {
        Set(valuesBySample.keys)
    }

    func value(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> GenotypeHaplotypeCallBandSlotValue? {
        value(for: .init(sample: sample, locus: locus, slot: slot))
    }

    func value(
        for target: GenotypeHaplotypeBandTarget
    ) -> GenotypeHaplotypeCallBandSlotValue? {
        valuesByTarget[target]
    }

    func changedSamples(comparedTo previous: Self) -> Set<String> {
        let samples = Set(valuesBySample.keys).union(previous.valuesBySample.keys)
        return Set(samples.filter {
            valuesBySample[$0] != previous.valuesBySample[$0]
        })
    }

    func renderedValue(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> String? {
        renderedValue(for: .init(sample: sample, locus: locus, slot: slot))
    }

    func renderedValue(for target: GenotypeHaplotypeBandTarget) -> String? {
        guard let value = value(for: target) else { return nil }
        return "\(target.slot.displayName) \(value.value) · "
            + "\(Self.statusLabel(value.status)) · "
            + Self.sourceLabel(value.source)
    }

    func renderedLocusValue(sample: String, locus: String) -> String {
        let h1 = value(sample: sample, locus: locus, slot: .h1)
        let h2 = value(sample: sample, locus: locus, slot: .h2)
        let statuses = [h1?.status, h2?.status]
        if statuses.contains(.tooManyGenotypes) {
            return "Too many genotypes"
        }
        if statuses.contains(.tooManyHaplotypes) {
            return "Too many haplotypes"
        }
        let h1Label = Self.compactLabel(h1)
        let h2Label = Self.compactLabel(h2)
        guard h1Label != "—" || h2Label != "—" else {
            return "—"
        }
        return "\(h1Label) • \(h2Label)"
    }

    func tooltip(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> String? {
        tooltip(for: .init(sample: sample, locus: locus, slot: slot))
    }

    func tooltip(for target: GenotypeHaplotypeBandTarget) -> String? {
        guard let value = value(for: target) else { return nil }
        return "\(target.locus) \(target.slot.displayName) — \(value.value); "
            + "status: \(Self.statusLabel(value.status)); "
            + "source: \(Self.sourceLabel(value.source))"
            + (value.isEditable ? "; editable" : "; read only")
    }

    func accessibilityLabel(
        sample: String,
        locus: String,
        slot: HaplotypeSlot
    ) -> String? {
        accessibilityLabel(
            for: .init(sample: sample, locus: locus, slot: slot)
        )
    }

    func accessibilityLabel(for target: GenotypeHaplotypeBandTarget) -> String? {
        guard let value = value(for: target) else { return nil }
        return "Sample \(target.sample), \(target.locus) "
            + "\(target.slot.displayName), \(value.value), status "
            + "\(Self.statusLabel(value.status)), source "
            + "\(Self.sourceLabel(value.source)), "
            + (value.isEditable ? "editable" : "read only")
    }

    func accessibilitySummary(sample: String) -> String {
        let parts = orderedLoci.flatMap { locus in
            HaplotypeSlot.allCases.compactMap { slot -> String? in
                let target = GenotypeHaplotypeBandTarget(
                    sample: sample,
                    locus: locus,
                    slot: slot
                )
                guard let value = value(for: target) else { return nil }
                return "\(locus) \(slot.displayName) \(value.value), "
                    + "\(Self.statusLabel(value.status)), "
                    + Self.sourceLabel(value.source)
            }
        }
        return parts.isEmpty
            ? "No haplotype calls"
            : "Haplotype calls: " + parts.joined(separator: "; ")
    }

    func renderedValues(sample: String) -> [String] {
        orderedLoci.map { locus in
            renderedLocusValue(sample: sample, locus: locus)
        }
    }

    private static func compactLabel(
        _ value: GenotypeHaplotypeCallBandSlotValue?
    ) -> String {
        guard let value else { return "—" }
        switch value.status {
        case .notAssayed, .noHaplotype, .tooManyHaplotypes,
             .tooManyGenotypes:
            return "—"
        case .called, .specialCase:
            let label = value.value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !label.isEmpty,
                  label != "-",
                  !label.hasPrefix("ERR:") else {
                return "—"
            }
            return label
        }
    }

    private static func bandValue(
        _ value: GenotypeEffectiveHaplotypeValue,
        isEditable: Bool
    ) -> GenotypeHaplotypeCallBandSlotValue {
        .init(
            value: value.effective,
            status: value.status,
            source: value.source,
            isEditable: isEditable
        )
    }

    static func statusLabel(_ status: GenotypeHaplotypeCallStatus) -> String {
        switch status {
        case .called: return "called"
        case .notAssayed: return "not assayed"
        case .specialCase: return "special case"
        case .noHaplotype: return "no haplotype"
        case .tooManyHaplotypes: return "too many haplotypes"
        case .tooManyGenotypes: return "too many genotypes"
        }
    }

    static func sourceLabel(
        _ source: GenotypeEffectiveHaplotypeValue.Source
    ) -> String {
        switch source {
        case .pipeline: return "pipeline"
        case .analystOverride: return "analyst override"
        case .staleOverride: return "pipeline; stale override ignored"
        }
    }
}
