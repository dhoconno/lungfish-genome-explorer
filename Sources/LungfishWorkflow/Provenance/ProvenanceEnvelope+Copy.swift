// ProvenanceEnvelope+Copy.swift - One copy helper that keeps every field a site leaves alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceEnvelope {
    /// A copy of this envelope with `change` applied. Every field the change leaves alone comes through,
    /// the status among them, and so does every field added later. A site that copies a recorded envelope
    /// calls this and sets only what it changes, never the initializer field by field, which drops each
    /// field it does not name. A status derived from the exit status cannot tell a cancelled run from a
    /// completed one, and `ProvenanceStep.with` is the same helper for a step.
    ///
    /// Three things always happen to the copy.
    ///
    /// - `signatures` is cleared, because changed bytes need a new signature.
    /// - The parameters of the nested run, which a record written before 2.4 holds and the encoder never
    ///   writes, merge into `options.resolvedDefaults` after `change` ran, so a `readSetPlan` that sat only
    ///   in the nested run survives (plan decisions P5 and E13). `ProvenanceOptions.mergingRunParameters` holds the rule.
    /// - The nested run is dropped.
    ///
    /// `schemaVersion`, `id`, `toolName`, `toolVersion` and `tool` name the record and stay `let`, because no
    /// copy site changes them.
    public func with(_ change: (inout ProvenanceEnvelope) throws -> Void) rethrows -> ProvenanceEnvelope {
        var copy = self
        try change(&copy)
        copy.options = copy.options.mergingRunParameters(copy.legacyRun?.parameters ?? [:])
        copy.signatures = []
        copy.legacyRun = nil
        return copy
    }
}

extension ProvenanceOptions {
    /// These options with the parameters of a nested run added to the run-level resolved defaults, which is
    /// the one home of `readSetPlan` (plan decision E13). It is the merge rule of `ProvenanceRecorder.save`
    /// with one difference, the target. The recorder still merges into the explicit options until the
    /// classifier producers converge on the resolved defaults.
    ///
    /// A parameter is added only when the options hold nothing for it. The explicit options win a clash,
    /// because explicit options are what was asked for, so a key they hold is never copied. A parameter that
    /// the options already record as a default or as a resolved default with the same value is not copied
    /// either, and a resolved default with another value stays as it is.
    func mergingRunParameters(_ parameters: [String: ParameterValue]) -> ProvenanceOptions {
        let onlyInRun = parameters.filter { key, value in
            explicit[key] == nil && defaults[key] != value && resolvedDefaults[key] != value
        }
        guard !onlyInRun.isEmpty else { return self }
        return ProvenanceOptions(
            explicit: explicit,
            defaults: defaults,
            resolvedDefaults: resolvedDefaults.merging(onlyInRun) { given, _ in given }
        )
    }
}
