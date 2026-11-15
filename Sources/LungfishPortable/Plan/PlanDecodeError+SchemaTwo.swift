// PlanDecodeError+SchemaTwo.swift - The checks of a schema 2 plan, and the refusal of schema 2 content in a version 1
// plan (Phase 5.3 lane EX-TOOL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ExecutionPlan {
    /// The words of each role with an identity key of its own, for an entry that lacks it or another that holds it.
    static let identitySentence: [PlanEntryRole: String] = [
        .database: "A database entry carries its id, version and format, and no other entry does.",
        .reference: "A reference entry carries its set id and its path in the set, and no other entry does.",
        .barcodeList: "A barcodeList entry carries its list's name and source, and no other entry does.",
    ]

    /// The table of role to identity key, with whether `entry` holds each key.
    static func identityKeys(of entry: PlanEntry) -> [(role: PlanEntryRole, key: String, holds: Bool)] {
        [
            (.database, "database", entry.database != nil),
            (.reference, "reference", entry.reference != nil),
            (.barcodeList, "barcodeList", entry.barcodeList != nil),
        ]
    }

    /// A version 1 plan is read by schema 1's rules, so a key, role or kind that schema 2 added is refused, in the order
    /// the keys decode. A plan built in code is held to schema 1's required keys here too.
    func refuseSchemaTwoContent() throws {
        for (index, entry) in entries.enumerated() {
            let field = "entries[\(index)]"
            if PlanEntryRole.schemaTwoRoles.contains(entry.role) {
                throw PlanDecodeError.schemaTwoContent(field: "\(field).role", holding: entry.role.rawValue)
            }
            if entry.reference != nil { throw PlanDecodeError.schemaTwoContent(field: "\(field).reference") }
            if entry.barcodeList != nil { throw PlanDecodeError.schemaTwoContent(field: "\(field).barcodeList") }
        }
        if pipeline != nil { throw PlanDecodeError.schemaTwoContent(field: "pipeline") }
        guard let sample = sampleValues else { throw PlanDecodeError(field: "sample", reason: "This plan has no sample.") }
        if sample.instrument != nil { throw PlanDecodeError.schemaTwoContent(field: "sample.instrument") }
        guard storageSettings != nil else { throw PlanDecodeError(field: "storage", reason: "This plan has no storage.") }
        guard clumpingChoice != nil else { throw PlanDecodeError(field: "clumping", reason: "This plan has no clumping.") }
        for (index, step) in steps.enumerated() {
            if step.kind == .tool {
                throw PlanDecodeError.schemaTwoContent(field: "steps[\(index)].kind", holding: step.kind.rawValue)
            }
            if step.outputPolicy != nil { throw PlanDecodeError.schemaTwoContent(field: "steps[\(index)].outputPolicy") }
        }
    }

    /// The keys of a schema 2 plan, checked before its entries: no `recipe`, `storage` or `clumping`, and a `pipeline`.
    func validateSchemaTwoKeys() throws {
        if recipe != nil { throw PlanDecodeError.schemaOneKey("recipe") }
        if storageSettings != nil { throw PlanDecodeError.schemaOneKey("storage") }
        if clumpingChoice != nil { throw PlanDecodeError.schemaOneKey("clumping") }
        guard pipeline != nil else { throw PlanDecodeError(field: "pipeline", reason: "This plan has no pipeline.") }
    }

    /// A step of a schema 2 plan is a `tool` step that gives a policy for each of its outputs and for nothing else.
    static func validateSchemaTwoStep(_ step: PlanStep, field: String) throws {
        guard step.kind == .tool else {
            throw PlanDecodeError(
                field: "\(field).kind",
                reason: "This plan has schema version 2 and its step \(step.id) has kind \(step.kind.rawValue), which a schema 2 plan does not hold."
            )
        }
        let policyField = "\(field).outputPolicy"
        guard let policy = step.outputPolicy else {
            throw PlanDecodeError(field: policyField, reason: "Step \(step.id) gives no outputPolicy. Each step of a schema 2 plan gives home, staged or stays for every output.")
        }
        for output in step.outputs where policy[output] == nil {
            throw PlanDecodeError(field: policyField, reason: "Step \(step.id) gives no policy for its output \(output).")
        }
        let outputs = Set(step.outputs)
        for path in policy.keys.sorted() where !outputs.contains(path) {
            throw PlanDecodeError(field: policyField, reason: "Step \(step.id) gives a policy for \(path), which is not one of its outputs.")
        }
    }

    /// The rules of a schema 2 plan that read more than one key, after its steps passed.
    func validateSchemaTwoRules() throws {
        guard let pipeline else { return }
        try validateSchemaTwoEntries(pipeline)
        try validatePipeline(pipeline)
        try validateSchemaTwoSample()
    }

    /// The `sample` goes with the `input` entries, each `reference` entry names the plan's set at the path its identity
    /// gives, each `barcodeList` entry sits under `barcodes/`, and both roles come last in the entries, `reference`
    /// first, each in the order of `relativePath`, so every plan writer writes the same bytes.
    private func validateSchemaTwoEntries(_ pipeline: PlanPipeline) throws {
        let hasInput = entries.contains { $0.role == .input }
        if hasInput, sampleValues == nil { throw PlanDecodeError(field: "sample", reason: "This plan has no sample.") }
        if !hasInput, sampleValues != nil {
            throw PlanDecodeError(field: "sample", reason: "This plan pins no input entry and holds a sample. A schema 2 plan with no input, such as an index build, has no sample.")
        }
        if !hasInput, !entries.contains(where: { $0.role == .reference }) {
            throw PlanDecodeError(field: "entries", reason: "This plan pins no input entry and no reference entry. A schema 2 plan with no input pins at least one reference entry.")
        }
        let rank: [PlanEntryRole: Int] = [.reference: 1, .barcodeList: 2]
        var last: (rank: Int, path: String) = (0, "")
        for (index, entry) in entries.enumerated() {
            let field = "entries[\(index)]"
            if let identity = entry.reference {
                guard identity.setID == pipeline.referenceSet.id else {
                    throw PlanDecodeError(field: "\(field).reference.setID", reason: "The reference entry \(entry.relativePath) names the set \(identity.setID), and the plan's pipeline names \(pipeline.referenceSet.id). A plan reads one reference set.")
                }
                guard entry.relativePath == identity.relativePath else {
                    throw PlanDecodeError(field: "\(field).reference", reason: "The reference entry \(entry.relativePath) names its file as \(identity.relativePath). A reference file sits at references/<set id>/<path>, and an index file at references/<set id>/indexes/<key>/<path>.")
                }
            }
            if let identity = entry.barcodeList {
                let parts = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0] == "barcodes", !identity.name.isEmpty else {
                    throw PlanDecodeError(field: "\(field).barcodeList", reason: "The barcode list entry \(entry.relativePath) does not sit at barcodes/<file> or names no list.")
                }
            }
            let entryRank = rank[entry.role] ?? 0
            guard entryRank > last.rank || (entryRank == last.rank && (entryRank == 0 || entry.relativePath > last.path)) else {
                throw PlanDecodeError(field: "entries", reason: "This plan lists \(entry.relativePath) out of order. A schema 2 plan lists its reference entries after every entry of another role, then its barcodeList entries, each in the order of relativePath.")
            }
            last = (entryRank, entry.relativePath)
        }
    }

    /// The pipeline's identity agrees with itself and with the steps: a route goes with a modality, each route setting
    /// is a setting of the chain, the route names a pin a step runs, and that counting step returns a report.
    private func validatePipeline(_ pipeline: PlanPipeline) throws {
        guard (pipeline.route == nil) == (pipeline.modality == nil) else {
            throw PlanDecodeError(field: "pipeline.modality", reason: "This plan's pipeline names a route without a modality or a modality without a route. A plan that makes counts names both, and one that makes none names neither.")
        }
        for (index, setting) in pipeline.settings.enumerated() where setting.source == .host || setting.source == .plan {
            let field = "pipeline.settings[\(index)].source"
            throw PlanDecodeError(field: field, reason: "This plan gives \(field) as \(setting.source.rawValue). A plan stores option, default or recipe for a setting of its chain.")
        }
        guard let route = pipeline.route else { return }
        for key in ["trimming", "duplicates"] where route.settings[key] == nil {
            throw PlanDecodeError(field: "pipeline.route.settings", reason: "This plan makes counts and its route states no \(key). The route of a plan that makes counts states trimming and duplicates.")
        }
        for key in route.settings.keys.sorted() {
            let value = route.settings[key] ?? ""
            guard pipeline.settings.contains(where: { $0.id == key && $0.value == value }) else {
                throw PlanDecodeError(field: "pipeline.route.settings", reason: "This plan's route states \(key) as \(value), and its pipeline settings hold no entry \(key) with that value.")
            }
        }
        let counting = steps.enumerated().filter { $0.element.tool?.id == route.tool && $0.element.tool?.version == route.toolVersion }
        guard let first = counting.first else {
            throw PlanDecodeError(field: "pipeline.route.tool", reason: "This plan's route names \(route.tool) \(route.toolVersion), and no step runs a pin of that id and version.")
        }
        // The page lists each counting tool's reports by name (executor-plan.md, The tool step), and the plan states
        // no report as such, so the check asks that a counting step returns at least one file.
        guard counting.contains(where: { $0.element.outputPolicy?.values.contains(.home) == true }) else {
            throw PlanDecodeError(field: "steps[\(first.offset)].outputPolicy", reason: "Step \(first.element.id) runs \(route.tool), the counting tool the route names, and returns none of its reports. A counting step names its tool's reports as home outputs.")
        }
    }

    /// An instrument names a model as a person reads it, with no padding and no control character.
    private func validateSchemaTwoSample() throws {
        guard let model = sampleValues?.instrument?.model else { return }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == model, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PlanDecodeError(field: "sample.instrument", reason: "This plan's sample.instrument names the model \"\(model)\", which is empty, padded or holds a control character. A plan leaves instrument out when no instrument is known.")
        }
    }
}
