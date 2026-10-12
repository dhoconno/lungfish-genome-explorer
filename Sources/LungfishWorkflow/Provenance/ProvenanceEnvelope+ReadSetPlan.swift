// ProvenanceEnvelope+ReadSetPlan.swift - The one reader of the read set plan a record holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - RecordedReadSetPlan

/// The read set plan a provenance record holds, with the place it was read from.
///
/// A plan says how the reads of one sample reached a tool, with the capability used, the counts by
/// kind and the reason mates ran as single reads (``ReadSetPlan/provenanceParameters``). A plan that
/// records nothing new is never written, so a record without one says nothing about pairing.
public struct RecordedReadSetPlan: Sendable, Equatable {
    /// The key every place records the plan under.
    public static let key = "readSetPlan"
    /// The key of the explicit option under which TaxTriage keeps one plan for each sample, keyed by
    /// sample id.
    public static let keyedBySampleKey = "read_set_plans"

    /// Where in a record the plan sits. The first case is the one home a writer records it in. The
    /// others are places that released builds wrote, which a reader still accepts.
    public enum Place: Sendable, Equatable {
        /// `options.resolvedDefaults`, the one home.
        case resolvedDefaults
        /// `options.explicit`, where the recorder merges the run parameters of the Kraken2 and
        /// EsViritu pipelines and where `assemble` writes a second copy.
        case explicitOptions
        /// The `resolvedOptions` of a step, where `map` records the plan on each mapper step.
        case stepResolvedOptions(stepID: UUID)
        /// The parameters of the run nested in a record that an older build wrote.
        case nestedRunParameters
        /// `options.explicit["read_set_plans"]` under the sample's id, where every released TaxTriage
        /// record keeps its plans and where a pooled TaxTriage record of several samples still keeps
        /// them (decision T7 of Phase 2.8).
        case explicitOptionsKeyedBySample(sampleID: String)
    }

    /// The fields of the plan, as ``ReadSetPlan/provenanceParameters`` wrote them.
    public let fields: [String: ParameterValue]

    /// The place the plan was read from.
    public let place: Place
}

// MARK: - ProvenanceEnvelope

extension ProvenanceEnvelope {
    /// The read set plan of this record, or nil when it holds none.
    ///
    /// The one home is `options.resolvedDefaults` under `readSetPlan`. Released builds also wrote the
    /// plan to `options.explicit`, to the `resolvedOptions` of a step and to the parameters of a run
    /// nested in the record, so the reader looks in that order and returns the first plan it finds.
    /// A value that is not an object is no plan, and the reader goes on to the next place.
    ///
    /// Last come the plans a TaxTriage record keeps by sample (``readSetPlansBySample``). One of them
    /// is the record's plan only when the record says it ran one sample (`sample_count` 1) and keeps
    /// that sample's plan. A pooled record of several samples has no one plan, even when only one of
    /// its samples kept a plan, so it reads nil here and gives each sample's plan by its id.
    public var readSetPlan: RecordedReadSetPlan? {
        let key = RecordedReadSetPlan.key
        if let fields = options.resolvedDefaults[key]?.dictionaryValue {
            return RecordedReadSetPlan(fields: fields, place: .resolvedDefaults)
        }
        if let fields = options.explicit[key]?.dictionaryValue {
            return RecordedReadSetPlan(fields: fields, place: .explicitOptions)
        }
        for step in steps {
            if let fields = step.resolvedOptions[key]?.dictionaryValue {
                return RecordedReadSetPlan(fields: fields, place: .stepResolvedOptions(stepID: step.id))
            }
        }
        if let fields = legacyRun?.parameters[key]?.dictionaryValue {
            return RecordedReadSetPlan(fields: fields, place: .nestedRunParameters)
        }
        let bySample = readSetPlansBySample
        if bySample.count == 1, options.explicit["sample_count"]?.numberValue == 1 {
            return bySample.values.first
        }
        return nil
    }

    /// The plans this record keeps by sample id, from `options.explicit["read_set_plans"]`.
    ///
    /// Every released TaxTriage record keeps its plans in this form, and a pooled TaxTriage record of
    /// several samples still does (decision T7 of Phase 2.8). A record saved while records still
    /// nested their run holds the same plans in that run's parameters too, so the explicit options
    /// are the one place read. A value that is not an object is no plan. Empty when the record keeps
    /// no plan by sample, as a record that holds its plan in the one home does.
    public var readSetPlansBySample: [String: RecordedReadSetPlan] {
        guard let plans = options.explicit[RecordedReadSetPlan.keyedBySampleKey]?.dictionaryValue else {
            return [:]
        }
        var bySample: [String: RecordedReadSetPlan] = [:]
        for (sampleID, value) in plans {
            if let fields = value.dictionaryValue {
                bySample[sampleID] = RecordedReadSetPlan(
                    fields: fields,
                    place: .explicitOptionsKeyedBySample(sampleID: sampleID)
                )
            }
        }
        return bySample
    }
}
