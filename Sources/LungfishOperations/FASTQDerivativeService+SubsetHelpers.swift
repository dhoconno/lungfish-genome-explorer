// FASTQDerivativeService+SubsetHelpers.swift - PE-aware subset helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

extension FASTQDerivativeService {
    // MARK: - PE-Aware Subset Helpers

    /// Runs a length filter rendered by ``FASTQLengthFilterPlan``, the plan
    /// `lungfish-cli fastq length-filter` runs too: bbduk `interleaved=t`
    /// removes or keeps both mates as a pair, seqkit judges single reads.
    func runLengthFilterPlan(
        _ plan: FASTQLengthFilterPlan,
        provenanceCollector: FASTQDerivativeNativeProvenanceCollector?
    ) async throws {
        let env = plan.isPairAware ? await bbToolsEnvironment() : nil
        let result = try await runNativeTool(
            plan.tool,
            arguments: plan.arguments,
            environment: env,
            timeout: plan.timeout,
            provenanceCollector: provenanceCollector
        )
        guard result.isSuccess else {
            throw FASTQDerivativeError.invalidOperation("\(plan.tool.executableName) length filter failed: \(result.stderr)")
        }
    }

    struct SelectedReadIDLookup {
        let rawIDs: Set<String>
        let normalizedIDs: Set<String>
        let baseReadIDs: Set<String>

        func contains(_ identifier: String) -> Bool {
            let normalized = identifier.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? identifier
            let positionalBase = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? normalized
            let mateBase: String
            if positionalBase.hasSuffix("/1") || positionalBase.hasSuffix("/2") {
                mateBase = String(positionalBase.dropLast(2))
            } else {
                mateBase = positionalBase
            }

            return rawIDs.contains(identifier)
                || rawIDs.contains(normalized)
                || rawIDs.contains(positionalBase)
                || normalizedIDs.contains(identifier)
                || normalizedIDs.contains(normalized)
                || normalizedIDs.contains(positionalBase)
                || baseReadIDs.contains(identifier)
                || baseReadIDs.contains(positionalBase)
                || baseReadIDs.contains(mateBase)
        }
    }

    func loadSelectedReadIDLookup(from url: URL) throws -> SelectedReadIDLookup {
        let content = try String(contentsOf: url, encoding: .utf8)
        var rawIDs: Set<String> = []
        var normalizedIDs: Set<String> = []
        var baseReadIDs: Set<String> = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let rawID = String(line)
            let normalizedID = normalizedIdentifier(rawID)
            let baseReadID = detectMateFromHeader(identifier: normalizedID, description: nil).readID
            rawIDs.insert(rawID)
            normalizedIDs.insert(normalizedID)
            baseReadIDs.insert(baseReadID)
        }

        return SelectedReadIDLookup(
            rawIDs: rawIDs,
            normalizedIDs: normalizedIDs,
            baseReadIDs: baseReadIDs
        )
    }

    func filteredTrimPositions(
        from trimPositionsURL: URL,
        selectedReadIDsFile: URL
    ) throws -> [String: (start: Int, end: Int)] {
        let selectedReadIDs = try loadSelectedReadIDLookup(from: selectedReadIDsFile)
        let positions = try FASTQTrimPositionFile.load(from: trimPositionsURL)
        return positions.reduce(into: [String: (start: Int, end: Int)]()) { result, entry in
            if selectedReadIDs.contains(entry.key) {
                result[entry.key] = entry.value
            }
        }
    }
}
