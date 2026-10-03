// AssembleCommand+ReadType.swift - How `lungfish-cli assemble` chooses its assembler and read type
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

extension AssembleCommand {

    /// The assembler to run. An explicit `--assembler` wins. Without one, the
    /// assembler follows the read type (explicit, recorded or detected, then
    /// read length for reads of unknown platform), and SPAdes runs when
    /// nothing is known. Nil for an unknown assembler name.
    static func resolveTool(
        _ assembler: String?,
        readType: String?,
        inputURLs: [URL],
        quiet: Bool
    ) -> AssemblyTool? {
        if let assembler {
            return AssemblyTool(rawValue: assembler.lowercased())
        }
        let explicitReadType = readType.flatMap(AssemblyReadType.init(cliArgument:))
        let detections = inputURLs.map(detectPreMaterializationReadType)
        let lengthDefault = inputURLs.first.flatMap(AssemblyReadType.lengthDefault(forInputURL:))
        let decision = AssemblyCompatibility.decideReadType(
            detections: detections,
            tool: nil,
            explicitReadType: explicitReadType,
            lengthDefault: lengthDefault
        )
        let tool = AssemblyCompatibility.defaultTool(for: decision.readType)
        if !quiet {
            let basis = decision.readType.map { "follows the read type, \($0.displayName)" } ?? "is the default"
            FileHandle.standardError.write(Data("note: Assembler \(tool.rawValue) \(basis). Pass --assembler to choose another.\n".utf8))
        }
        return tool
    }

    /// The read type known before any derived bundle is materialized: the
    /// explicit read type, or the recorded or detected type of every input
    /// (a derived bundle answers from its root). Nil when an input's type is
    /// not known yet, so the materialized reads decide.
    static func preMaterializationReadTypeDecision(
        for tool: AssemblyTool,
        explicitReadType: AssemblyReadType?,
        inputURLs: [URL]
    ) -> AssemblyReadTypeDecision? {
        if let explicitReadType {
            return AssemblyReadTypeDecision(readType: explicitReadType, warnings: [])
        }
        let detections = inputURLs.map(detectPreMaterializationReadType)
        guard !detections.isEmpty, !detections.contains(where: { $0 == nil }) else { return nil }
        return AssemblyCompatibility.decideReadType(
            detections: detections, tool: tool, explicitReadType: nil, lengthDefault: nil
        )
    }

    /// The read type decided from the materialized execution inputs, with
    /// each original input's recorded type as a fallback and the read lengths
    /// for inputs of unknown platform.
    static func readTypeDecision(
        for tool: AssemblyTool,
        explicitReadType: String?,
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) throws -> AssemblyReadTypeDecision {
        let explicit = try parseExplicitReadType(explicitReadType)
        let pairs = CLISequenceInputMaterialization.originalAndExecutionInputs(
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        )
        let detections = pairs.map { originalURL, executionURL in
            AssemblyReadType.detect(fromFASTQ: executionURL)
                ?? AssemblyReadType.detect(fromInputURL: originalURL)
        }
        let lengthDefault = pairs.first.flatMap { _, executionURL in
            PlatformInference.defaultReadType(forLengthProfile: PlatformInference.lengthProfile(forFASTQ: executionURL))
                .flatMap(AssemblyReadType.init(persistedReadType:))
        }
        return AssemblyCompatibility.decideReadType(
            detections: detections, tool: tool, explicitReadType: explicit, lengthDefault: lengthDefault
        )
    }

    /// The read type before materialization, nil when it waits for the reads.
    static func resolvePreMaterializationReadType(
        for tool: AssemblyTool,
        explicitReadType: AssemblyReadType?,
        inputURLs: [URL]
    ) throws -> AssemblyReadType? {
        preMaterializationReadTypeDecision(for: tool, explicitReadType: explicitReadType, inputURLs: inputURLs)?.readType
    }

    /// The read type a run uses. Never nil: the assembler's own read type is
    /// the last default.
    static func resolveReadType(
        for tool: AssemblyTool,
        explicitReadType: String?,
        originalInputURLs: [URL],
        executionInputURLs: [URL]
    ) throws -> AssemblyReadType {
        try readTypeDecision(
            for: tool,
            explicitReadType: explicitReadType,
            originalInputURLs: originalInputURLs,
            executionInputURLs: executionInputURLs
        ).readType ?? AssemblyCompatibility.defaultReadType(for: tool)
    }
}
