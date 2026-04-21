// AssemblyCompatibility.swift - Strict v1 assembly tool/read-type gating
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Compatibility decisions for the shared assembly surface.
public enum AssemblyCompatibility {
    /// Blocking message shown when multiple read classes are detected.
    public static let hybridAssemblyUnsupportedMessage =
        "Hybrid assembly is not supported in v1. Select one read class per run."

    /// Tools allowed for the given v1 read class.
    public static func supportedTools(for readType: AssemblyReadType) -> [AssemblyTool] {
        switch readType {
        case .illuminaShortReads:
            return [.spades, .megahit, .skesa]
        case .ontReads:
            return [.flye, .hifiasm]
        case .pacBioHiFi:
            return [.hifiasm]
        }
    }

    /// Whether the tool is allowed for the selected read class.
    public static func isSupported(tool: AssemblyTool, for readType: AssemblyReadType) -> Bool {
        supportedTools(for: readType).contains(tool)
    }

    /// Evaluates read-type detection before the user manually confirms a run.
    public static func evaluate(
        detectedReadTypes: some Sequence<AssemblyReadType>
    ) -> AssemblyCompatibilityEvaluation {
        let uniqueReadTypes = Array(Set(detectedReadTypes)).sorted { lhs, rhs in
            guard let lhsIndex = AssemblyReadType.allCases.firstIndex(of: lhs),
                  let rhsIndex = AssemblyReadType.allCases.firstIndex(of: rhs) else {
                return lhs.rawValue < rhs.rawValue
            }
            return lhsIndex < rhsIndex
        }

        guard uniqueReadTypes.count <= 1 else {
            return AssemblyCompatibilityEvaluation(
                detectedReadTypes: uniqueReadTypes,
                resolvedReadType: nil,
                supportedTools: [],
                blockingMessage: hybridAssemblyUnsupportedMessage
            )
        }

        guard let readType = uniqueReadTypes.first else {
            return AssemblyCompatibilityEvaluation(
                detectedReadTypes: [],
                resolvedReadType: nil,
                supportedTools: [],
                blockingMessage: nil
            )
        }

        return AssemblyCompatibilityEvaluation(
            detectedReadTypes: [readType],
            resolvedReadType: readType,
            supportedTools: supportedTools(for: readType),
            blockingMessage: nil
        )
    }
}

/// Result of evaluating read-type compatibility for a pending assembly run.
public struct AssemblyCompatibilityEvaluation: Sendable, Equatable {
    public let detectedReadTypes: [AssemblyReadType]
    public let resolvedReadType: AssemblyReadType?
    public let supportedTools: [AssemblyTool]
    public let blockingMessage: String?

    public init(
        detectedReadTypes: [AssemblyReadType],
        resolvedReadType: AssemblyReadType?,
        supportedTools: [AssemblyTool],
        blockingMessage: String?
    ) {
        self.detectedReadTypes = detectedReadTypes
        self.resolvedReadType = resolvedReadType
        self.supportedTools = supportedTools
        self.blockingMessage = blockingMessage
    }

    /// Whether the current combination should be blocked before launch.
    public var isBlocked: Bool {
        blockingMessage != nil
    }

    /// Whether the user still needs to confirm the read type manually.
    public var requiresReadTypeConfirmation: Bool {
        !isBlocked && resolvedReadType == nil
    }
}
