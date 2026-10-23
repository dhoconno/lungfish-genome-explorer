// PlanClumpingChoice.swift - The clumping and compressor values a plan fixes, with no automatic value (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The clumping tool a plan's storage step runs. It has no `auto` case, so a plan always names the tool and the node
/// never chooses (tally K4.5). The raw values are `ClumpingTool`'s in LungfishWorkflow.
package enum PlanClumpingTool: String, Codable, Sendable, CaseIterable {
    case bbtools
    case trimGalore = "trim-galore"
    case none

    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let field = PlanDecodeError.fieldName(decoder.codingPath)
        if raw == "auto" { throw PlanDecodeError.autoClumpingTool(field: field) }
        guard let value = Self(rawValue: raw) else {
            throw PlanDecodeError(field: field, reason: "This plan names the clumping tool \(raw). A plan must name bbtools, trim-galore or none.")
        }
        self = value
    }
}

/// What the user asked for, which may be `auto`. Kept so the user's own request stays traceable through the plan.
package enum PlanClumpingRequest: String, Codable, Sendable, CaseIterable {
    case auto
    case bbtools
    case trimGalore = "trim-galore"
    case none
}

/// The compressor a plan's storage route names. It has no `auto` case (tally K4.5).
package enum PlanCompressor: String, Codable, Sendable, CaseIterable {
    case bgzip
    case pigz

    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let field = PlanDecodeError.fieldName(decoder.codingPath)
        if raw == "auto" { throw PlanDecodeError.autoCompressor(field: field) }
        guard let value = Self(rawValue: raw) else {
            throw PlanDecodeError(field: field, reason: "This plan names the compressor \(raw). A plan must name pigz or bgzip.")
        }
        self = value
    }
}

/// How the plan writer settled the clumping tool. It holds no input estimate, physical memory or threshold, since the
/// plan's rule reads none of them, and never a 0 that reads as a measured size (tally-r2 K4-02, ARCH round 3 ruling 1).
package struct PlanClumpingChoice: Codable, Sendable, Equatable {
    /// `auto` or the tool the user named.
    package var requested: PlanClumpingRequest
    /// The tool the storage step runs. Equal to the plan's `storage.clumpingTool`.
    package var resolved: PlanClumpingTool
    /// `default` when `requested` is `auto` (the plan writer's rule decided), `option` when the user named the tool.
    package var resolvedSource: ImportSettingSource
    /// The clumpify heap the plan pins, in bytes. Equal to `storage.clumpifyHeapGB` GiB.
    package var heapBytes: Int64
    /// The sentence that says why the resolved tool runs.
    package var reason: String
    /// `ClumpingTool.operationNotice` for Trim Galore, which the adopt logs as the local import does (ARCH A5).
    package var operationNotice: String?

    package init(
        requested: PlanClumpingRequest,
        resolved: PlanClumpingTool,
        resolvedSource: ImportSettingSource,
        heapBytes: Int64,
        reason: String,
        operationNotice: String? = nil
    ) {
        self.requested = requested
        self.resolved = resolved
        self.resolvedSource = resolvedSource
        self.heapBytes = heapBytes
        self.reason = reason
        self.operationNotice = operationNotice
    }
}
