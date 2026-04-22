// AlignmentFilterCommandBuilder.swift - Pure BAM filtering command planning
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Builds deterministic samtools command plans for BAM filtering.
public enum AlignmentFilterCommandBuilder {

    /// Builds a pure command plan from the provided request.
    public static func build(from request: AlignmentFilterRequest) throws -> AlignmentFilterCommandPlan {
        if let minimumMAPQ = request.minimumMAPQ, minimumMAPQ < 0 {
            throw AlignmentFilterError.invalidMinimumMAPQ(minimumMAPQ)
        }

        let trailingArguments = try validatedTrailingArguments(request.region)
        let identityExpression = try validatedIdentityExpression(request.identityFilter)
        let requiredSAMTags = request.identityFilter?.requiredSAMTags ?? []
        let preprocessingSteps = preprocessingSteps(for: request.duplicateMode)

        var excludeFlags: UInt16 = 0
        if request.mappedOnly {
            excludeFlags |= 0x4
        }
        if request.primaryOnly {
            excludeFlags |= 0x900
        }
        if request.duplicateMode == .exclude {
            excludeFlags |= 0x400
        }

        var arguments: [String] = ["-b"]
        if excludeFlags != 0 {
            arguments += ["-F", String(format: "0x%X", excludeFlags)]
        }
        if let minimumMAPQ = request.minimumMAPQ {
            arguments += ["-q", String(minimumMAPQ)]
        }
        if let identityExpression {
            arguments += ["-e", identityExpression]
        }

        return AlignmentFilterCommandPlan(
            arguments: arguments,
            trailingArguments: trailingArguments,
            preprocessingSteps: preprocessingSteps,
            duplicateMode: request.duplicateMode,
            identityFilterExpression: identityExpression,
            requiredSAMTags: requiredSAMTags
        )
    }

    private static func preprocessingSteps(
        for duplicateMode: AlignmentFilterDuplicateMode?
    ) -> [AlignmentFilterPreprocessingStep] {
        guard duplicateMode == .remove else { return [] }
        return [.samtoolsMarkdup(removeDuplicates: true)]
    }

    private static func validatedTrailingArguments(_ region: String?) throws -> [String] {
        guard let region else { return [] }
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AlignmentFilterError.invalidRegion(region)
        }
        return [trimmed]
    }

    private static func validatedIdentityExpression(_ filter: AlignmentFilterIdentityFilter?) throws -> String? {
        guard let filter else { return nil }
        if case .minimumPercentIdentity(let threshold) = filter,
           !(0...100).contains(threshold) {
            throw AlignmentFilterError.invalidMinimumPercentIdentity(threshold)
        }
        return filter.samtoolsExpression
    }
}
