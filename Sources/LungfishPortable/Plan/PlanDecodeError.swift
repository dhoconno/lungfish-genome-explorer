// PlanDecodeError.swift - The named refusals of a plan and the checks that raise them (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why a plan cannot run, naming the field. The executor writes `field` and `reason` into its refused run record, and
/// the Mac's plan writer shows `reason`, so both refuse a plan with the same words (tally-r2 K4-13).
package struct PlanDecodeError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// The field's path in the plan, such as `storage.compressor` or `steps[2].deadlineSeconds`.
    package var field: String
    package var reason: String

    package init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    package var errorDescription: String? { reason }
    package var description: String { "\(field): \(reason)" }

    // MARK: - Sentences of tally K4.5 and UX's N3-1

    package static func autoClumpingTool(field: String) -> PlanDecodeError {
        PlanDecodeError(field: field, reason: "This plan leaves the clumping tool as auto. A plan must name bbtools, trim-galore or none.")
    }

    package static func autoCompressor(field: String) -> PlanDecodeError {
        PlanDecodeError(field: field, reason: "This plan leaves the compressor as auto. A plan must name pigz or bgzip.")
    }

    /// UX's N3-1 words, for a BBTools storage step under a plan that names pigz.
    package static func bbtoolsStepWithoutBgzip(stepID: String, program: String) -> PlanDecodeError {
        PlanDecodeError(
            field: "storage.compressor",
            reason: "This plan names pigz as the compressor for step \(stepID), which runs \(program). BBTools compresses its output with bgzip, so the plan must name bgzip."
        )
    }

    /// The programs that write their output through BBTools' BGZF branch (BIO N3).
    package static let bbtoolsStoragePrograms: Set<String> = ["clumpify.sh", "reformat.sh"]

    /// A coding path as a field name, `storage.threads` or `steps[0].tool.id`.
    package static func fieldName(_ path: [any CodingKey]) -> String {
        var name = ""
        for key in path {
            if let index = key.intValue {
                name += "[\(index)]"
            } else {
                name += name.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return name.isEmpty ? "plan" : name
    }

    /// The named error for a decoder failure. A missing or null value refuses as an absent one, with the K4.5 words
    /// where the field is one the plan must name.
    package init(decodingError: DecodingError) {
        switch decodingError {
        case .keyNotFound(let key, let context):
            self = Self.missing(field: Self.fieldName(context.codingPath + [key]))
        case .valueNotFound(_, let context):
            self = Self.missing(field: Self.fieldName(context.codingPath))
        case .typeMismatch(_, let context):
            let field = Self.fieldName(context.codingPath)
            self.init(field: field, reason: "This plan's \(field) has the wrong type.")
        case .dataCorrupted(let context):
            let field = Self.fieldName(context.codingPath)
            self.init(field: field, reason: context.codingPath.isEmpty
                ? "The plan file is not a JSON plan this executor reads."
                : "This plan's \(field) holds a value this executor does not read.")
        @unknown default:
            self.init(field: "plan", reason: "The plan file is not a JSON plan this executor reads.")
        }
    }

    private static func missing(field: String) -> PlanDecodeError {
        switch field {
        case "storage.clumpingTool", "clumping.resolved":
            return PlanDecodeError(field: field, reason: "This plan names no clumping tool. A plan must name bbtools, trim-galore or none.")
        case "storage.compressor":
            return PlanDecodeError(field: field, reason: "This plan names no compressor. A plan must name pigz or bgzip.")
        default:
            return PlanDecodeError(field: field, reason: "This plan has no \(field).")
        }
    }
}

extension ExecutionPlan {
    /// The checks every decoded plan passes before the executor reads any input past it.
    package func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PlanDecodeError(field: "schemaVersion", reason: "This plan has schema version \(schemaVersion), and this executor reads version \(Self.currentSchemaVersion).")
        }
        try validateEntries()
        try Self.checkDigest(imageManifest.sha256, field: "imageManifest.sha256")
        guard imageManifest.size > 0 else {
            throw PlanDecodeError(field: "imageManifest.size", reason: "This plan pins an empty tool manifest.")
        }
        var toolIDs = Set<String>()
        for (index, tool) in tools.enumerated() where tool.id.isEmpty || !toolIDs.insert(tool.id).inserted {
            throw PlanDecodeError(field: "tools[\(index)].id", reason: "This plan pins the tool \(tool.id) twice or with no id.")
        }
        try validateStorage()
        try validateClumping()
        guard graceSeconds.isFinite, graceSeconds > 0, graceSeconds <= Self.maximumGraceSeconds else {
            throw PlanDecodeError(field: "graceSeconds", reason: "This plan gives a grace of \(graceSeconds) seconds. A plan's grace is above 0 and at most \(Int(Self.maximumGraceSeconds)) seconds.")
        }
        try validateSteps()
    }

    private func validateEntries() throws {
        var paths = Set<String>()
        var counts: [PlanEntryRole: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let field = "entries[\(index)]"
            if let refusal = PlanResourceResolver.refusal(forRelativePath: entry.relativePath) {
                throw PlanDecodeError(field: "\(field).relativePath", reason: refusal.reason)
            }
            guard paths.insert(entry.relativePath).inserted else {
                throw PlanDecodeError(field: "\(field).relativePath", reason: "This plan pins \(entry.relativePath) twice.")
            }
            try Self.checkDigest(entry.sha256, field: "\(field).sha256")
            guard entry.size >= 0 else {
                throw PlanDecodeError(field: "\(field).size", reason: "This plan gives \(entry.relativePath) a negative size.")
            }
            guard (entry.role == .database) == (entry.database != nil) else {
                throw PlanDecodeError(field: "\(field).database", reason: "A database entry carries its id, version and format, and no other entry does.")
            }
            counts[entry.role, default: 0] += 1
        }
        guard counts[.executor, default: 0] == 1 else {
            throw PlanDecodeError(field: "entries", reason: "A plan pins exactly one executor entry.")
        }
        guard counts[.input, default: 0] >= 1 else {
            throw PlanDecodeError(field: "entries", reason: "A plan pins at least one input entry.")
        }
        guard counts[.recipe, default: 0] == (recipe == nil ? 0 : 1) else {
            throw PlanDecodeError(field: "entries", reason: "A plan with a recipe pins exactly one recipe entry, and a plan with none pins no recipe entry.")
        }
        if let recipe, let entry = entries.first(where: { $0.role == .recipe }), entry.sha256 != recipe.sourceSHA256 {
            throw PlanDecodeError(field: "recipe.sourceSHA256", reason: "The recipe entry's SHA-256 differs from the recipe's sourceSHA256.")
        }
    }

    private func validateStorage() throws {
        guard storage.threads > 0 else {
            throw PlanDecodeError(field: "storage.threads", reason: "This plan names \(storage.threads) storage threads. A plan must name a positive thread count, since no value may mean every core.")
        }
        guard storage.clumpifyHeapGB > 0 else {
            throw PlanDecodeError(field: "storage.clumpifyHeapGB", reason: "This plan names a clumpify heap of \(storage.clumpifyHeapGB) GB. A plan must name a positive heap, since no value may mean the host's memory.")
        }
        guard (1...9).contains(storage.compressionLevel) else {
            throw PlanDecodeError(field: "storage.compressionLevel", reason: "This plan names compression level \(storage.compressionLevel). A plan names a level from 1 to 9.")
        }
        let fixed: [(String, ImportSettingSource)] = [
            ("storage.threadsSource", storage.threadsSource),
            ("storage.clumpifyHeapSource", storage.clumpifyHeapSource),
            ("storage.clumpingToolSource", storage.clumpingToolSource),
            ("storage.compressorSource", storage.compressorSource),
        ]
        for (field, source) in fixed where source != .option && source != .default {
            throw PlanDecodeError(field: field, reason: "This plan gives \(field) as \(source.rawValue). A plan stores option or default for a value it fixes.")
        }
        if storage.qualityBinningSource == .host || storage.qualityBinningSource == .plan {
            throw PlanDecodeError(field: "storage.qualityBinningSource", reason: "This plan gives storage.qualityBinningSource as \(storage.qualityBinningSource.rawValue). A plan stores option, default or recipe for the binning.")
        }
    }

    private func validateClumping() throws {
        guard clumping.resolved == storage.clumpingTool else {
            throw PlanDecodeError(field: "clumping.resolved", reason: "This plan's clumping choice resolves to \(clumping.resolved.rawValue), and its storage names \(storage.clumpingTool.rawValue).")
        }
        guard clumping.heapBytes == Int64(storage.clumpifyHeapGB) * 1_073_741_824 else {
            throw PlanDecodeError(field: "clumping.heapBytes", reason: "This plan's clumping choice used a heap of \(clumping.heapBytes) bytes, and its storage pins \(storage.clumpifyHeapGB) GB.")
        }
        if clumping.requested != .auto, clumping.requested.rawValue != clumping.resolved.rawValue {
            throw PlanDecodeError(field: "clumping.resolved", reason: "This plan's user named \(clumping.requested.rawValue), and its clumping choice resolves to \(clumping.resolved.rawValue).")
        }
        guard clumping.resolvedSource == .option || clumping.resolvedSource == .default else {
            throw PlanDecodeError(field: "clumping.resolvedSource", reason: "This plan gives clumping.resolvedSource as \(clumping.resolvedSource.rawValue). A plan stores option or default for a value it fixes.")
        }
        if clumping.requested == .auto, clumping.resolvedSource == .option {
            throw PlanDecodeError(field: "clumping.resolvedSource", reason: "This plan gives clumping.resolvedSource as option for an automatic request. The plan writer's rule chose the tool, so the source is default.")
        }
        guard !clumping.reason.isEmpty else {
            throw PlanDecodeError(field: "clumping.reason", reason: "This plan's clumping choice gives no reason.")
        }
    }

    private func validateSteps() throws {
        guard !steps.isEmpty else { throw PlanDecodeError(field: "steps", reason: "This plan has no steps.") }
        let pinned = Set(tools)
        var ids = Set<String>()
        for (index, step) in steps.enumerated() {
            let field = "steps[\(index)]"
            guard Self.isStepID(step.id), ids.insert(step.id).inserted else {
                throw PlanDecodeError(field: "\(field).id", reason: "Step id \(step.id) is repeated or not 1 to 64 letters, digits, dots, underscores or hyphens starting with a letter or digit.")
            }
            guard step.deadlineSeconds.isFinite, step.deadlineSeconds > 0 else {
                throw PlanDecodeError(field: "\(field).deadlineSeconds", reason: "Step \(step.id) has no positive deadline.")
            }
            switch (step.kind, step.tool) {
            case (.qualityCount, nil):
                break
            case (.qualityCount, .some), (_, nil):
                throw PlanDecodeError(field: "\(field).tool", reason: "Step \(step.id) names a tool only when the step runs one.")
            case (_, .some(let tool)):
                guard pinned.contains(tool) else {
                    throw PlanDecodeError(field: "\(field).tool", reason: "Step \(step.id) runs \(tool.id) \(tool.version) build \(tool.build), which the plan's tools do not pin.")
                }
                if step.kind == .storage, storage.compressor == .pigz, PlanDecodeError.bbtoolsStoragePrograms.contains(tool.id) {
                    throw PlanDecodeError.bbtoolsStepWithoutBgzip(stepID: step.id, program: tool.id)
                }
            }
            try Self.validateEnvironment(step.environment, field: "\(field).environment", stepID: step.id)
            let paths = step.inputs.map { ("inputs", $0) } + step.outputs.map { ("outputs", $0) }
                + (step.standardOutput.map { [("standardOutput", $0)] } ?? [])
            for (name, path) in paths {
                if let refusal = PlanResourceResolver.refusal(forRelativePath: path) {
                    throw PlanDecodeError(field: "\(field).\(name)", reason: refusal.reason)
                }
            }
        }
    }

    /// The executor sets `PATH` from the image's manifest and `TMPDIR` and `HOME` inside the work root, so a plan
    /// names none of them, and no relative `PATH` entry can reach a tool (K2 review O-9).
    private static func validateEnvironment(_ variables: [PlanEnvironmentVariable], field: String, stepID: String) throws {
        var names = Set<String>()
        for (index, variable) in variables.enumerated() {
            let name = variable.name
            let first = name.unicodeScalars.first
            let isName = first.map { $0 == "_" || ("A"..."Z").contains($0) || ("a"..."z").contains($0) } ?? false
                && name.unicodeScalars.allSatisfy { $0 == "_" || ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            guard isName, names.insert(name).inserted, !["PATH", "TMPDIR", "HOME"].contains(name),
                  !variable.value.unicodeScalars.contains("\0") else {
                throw PlanDecodeError(field: "\(field)[\(index)]", reason: "Step \(stepID) sets the variable \(name), which is repeated, not a variable name, holds a NUL, or is one the executor sets itself (PATH, TMPDIR, HOME).")
            }
        }
    }

    private static func isStepID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (1...64).contains(scalars.count) else { return false }
        func alphanumeric(_ s: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(s) || ("a"..."z").contains(s) || ("0"..."9").contains(s)
        }
        return alphanumeric(scalars[0]) && scalars.allSatisfy { alphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    package static func checkDigest(_ digest: String, field: String) throws {
        let hex = digest.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        guard digest.unicodeScalars.count == 64, hex else {
            throw PlanDecodeError(field: field, reason: "This plan's \(field) is not a lowercase hexadecimal SHA-256.")
        }
    }
}
