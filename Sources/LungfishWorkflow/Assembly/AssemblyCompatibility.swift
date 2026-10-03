// AssemblyCompatibility.swift - Strict v1 assembly tool/read-type gating
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Compatibility decisions for the shared assembly surface.
public enum AssemblyCompatibility {
    /// Warning shown when multiple read classes are detected. The user picks
    /// the read class the run uses.
    public static let hybridAssemblyUnsupportedMessage =
        "The inputs mix read classes. Hybrid assembly is not supported in v1, so choose the read class to assemble every input as."

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
        detectedReadTypes: some Swift.Sequence<AssemblyReadType>
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
                supportedTools: AssemblyTool.allCases,
                blockingMessage: nil,
                warningMessage: hybridAssemblyUnsupportedMessage
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
    /// A warning to show. The run is still allowed.
    public let warningMessage: String?

    public init(
        detectedReadTypes: [AssemblyReadType],
        resolvedReadType: AssemblyReadType?,
        supportedTools: [AssemblyTool],
        blockingMessage: String?,
        warningMessage: String? = nil
    ) {
        self.detectedReadTypes = detectedReadTypes
        self.resolvedReadType = resolvedReadType
        self.supportedTools = supportedTools
        self.blockingMessage = blockingMessage
        self.warningMessage = warningMessage
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

// MARK: - Read-type defaults

/// The read type an assembly runs with, and the warnings to show.
///
/// Read class and platform only choose defaults. A tool that does not suit the
/// detected read class, mixed read classes, and inputs with no known read type
/// are warnings, and the run goes ahead with what the user chose.
public struct AssemblyReadTypeDecision: Sendable, Equatable {
    public let readType: AssemblyReadType?
    public let warnings: [String]

    public init(readType: AssemblyReadType?, warnings: [String]) {
        self.readType = readType
        self.warnings = warnings
    }
}

extension AssemblyCompatibility {

    /// The read type an assembler runs its inputs as when nothing else decides.
    public static func defaultReadType(for tool: AssemblyTool) -> AssemblyReadType {
        switch tool {
        case .spades, .megahit, .skesa: return .illuminaShortReads
        case .flye: return .ontReads
        case .hifiasm: return .pacBioHiFi
        }
    }

    /// The assembler chosen for a read type when the user names none. SPAdes
    /// for short reads and for reads of no known type, Flye for ONT reads and
    /// hifiasm for PacBio HiFi reads.
    public static func defaultTool(for readType: AssemblyReadType?) -> AssemblyTool {
        switch readType {
        case .ontReads?: return .flye
        case .pacBioHiFi?: return .hifiasm
        case .illuminaShortReads?, nil: return .spades
        }
    }

    /// Decides the read type of a run.
    ///
    /// - Parameters:
    ///   - detections: one entry per input, nil when its read type is not known.
    ///   - tool: the assembler the user chose, when one was chosen.
    ///   - explicitReadType: `--read-type` or the window's read-type choice, which wins.
    ///   - lengthDefault: the read type the read lengths suggest for unknown inputs.
    public static func decideReadType(
        detections: [AssemblyReadType?],
        tool: AssemblyTool?,
        explicitReadType: AssemblyReadType?,
        lengthDefault: AssemblyReadType?
    ) -> AssemblyReadTypeDecision {
        if let explicitReadType {
            return AssemblyReadTypeDecision(readType: explicitReadType, warnings: [])
        }
        var warnings: [String] = []
        let known = AssemblyReadType.allCases.filter { detections.contains($0) }
        var readType: AssemblyReadType?
        if known.count > 1 {
            readType = tool.map(defaultReadType(for:)) ?? known.first
            warnings.append(
                "The inputs mix read classes (\(known.map(\.displayName).joined(separator: " and "))). Hybrid assembly is not supported in v1, so every input is assembled as \(readType?.displayName ?? "one read class")."
            )
        } else if let only = known.first {
            readType = only
            if detections.contains(where: { $0 == nil }) {
                warnings.append("Some inputs have no known read type and are assembled as \(only.displayName).")
            }
        } else {
            readType = lengthDefault ?? tool.map(defaultReadType(for:))
            if !detections.isEmpty {
                warnings.append(PlatformInference.untunedDefaultsNote)
            }
        }
        if let tool, let current = readType, !isSupported(tool: tool, for: current) {
            let toolReadType = defaultReadType(for: tool)
            warnings.append(
                "\(tool.displayName) is designed for \(supportedReadTypes(for: tool)), and the reads look like \(current.displayName). The run uses \(tool.displayName) as chosen, with its \(toolReadType.displayName) settings."
            )
            readType = toolReadType
        }
        return AssemblyReadTypeDecision(readType: readType, warnings: warnings)
    }

    /// The read type a run of `tool` uses when the inputs suggest
    /// `readType`: that read type when the tool takes it, otherwise the
    /// tool's own read type.
    public static func effectiveReadType(tool: AssemblyTool, readType: AssemblyReadType) -> AssemblyReadType {
        isSupported(tool: tool, for: readType) ? readType : defaultReadType(for: tool)
    }

    /// The warning the assembly window shows, or nil. It never blocks a run.
    /// `detected` holds one entry per input, nil when its read type is unknown.
    public static func windowWarning(
        tool: AssemblyTool,
        detected: [AssemblyReadType?],
        chosenReadType: AssemblyReadType
    ) -> String? {
        decideReadType(
            detections: detected.isEmpty ? [nil] : detected,
            tool: tool,
            explicitReadType: detected.contains(where: { $0 != nil }) ? nil : chosenReadType,
            lengthDefault: chosenReadType
        ).warnings.first ?? (detected.allSatisfy { $0 == nil } ? PlatformInference.untunedDefaultsNote : nil)
    }

    static func supportedReadTypes(for tool: AssemblyTool) -> String {
        AssemblyReadType.allCases.filter { isSupported(tool: tool, for: $0) }.map(\.displayName).joined(separator: " or ")
    }
}
