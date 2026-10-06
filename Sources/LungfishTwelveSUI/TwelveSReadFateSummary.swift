// TwelveSReadFateSummary.swift - The result's read fate as the viewport states it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import SwiftUI

/// The one-line read fate of a 12S result, and the pairs it left out.
enum TwelveSReadFateSummary {

    /// `2 discordant pairs left out (1 different targets, 1 one mate
    /// unresolved)`, or nil when the run left nothing out.
    static func leftOutText(for readFate: TwelveSAmpliconReadFate) -> String? {
        guard readFate.discordantPairs > 0 else { return nil }
        let noun = readFate.discordantPairs == 1 ? "pair" : "pairs"
        var text = "\(readFate.discordantPairs) discordant \(noun) left out"
        let reasons = reasonList(readFate.discordantPairsByReason)
        if !reasons.isEmpty {
            text += " (\(reasons))"
        }
        return text
    }

    /// The reasons in their fixed order, `1 different targets, 1 one mate unresolved`.
    static func reasonList(_ counts: [String: Int]) -> String {
        let known = TwelveSPairDiscordance.allCases.compactMap { reason -> String? in
            guard let count = counts[reason.rawValue], count > 0 else { return nil }
            return "\(count) \(reason.displayName)"
        }
        let unknown = counts.keys
            .filter { TwelveSPairDiscordance(rawValue: $0) == nil && counts[$0, default: 0] > 0 }
            .sorted()
            .map { "\(counts[$0, default: 0]) \($0.replacingOccurrences(of: "_", with: " "))" }
        return (known + unknown).joined(separator: ", ")
    }

    /// The viewport's status line.
    static func statusText(for result: TwelveSAmpliconResultBundleData) -> String {
        let chimeraText = result.chimeraCandidateCount == 1
            ? "1 chimera candidate"
            : "\(result.chimeraCandidateCount) chimera candidates"
        var parts = [
            "\(result.samples.count) samples",
            "\(result.readFate.exactMatchReads) exact reads",
            "\(formatPercent(result.readFate.unresolvedPercent)) unresolved",
            chimeraText,
        ]
        if let leftOut = leftOutText(for: result.readFate) {
            parts.append(leftOut)
        }
        return parts.joined(separator: " | ")
    }

    static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

struct TwelveSProvenanceSummaryView: View {
    let result: TwelveSAmpliconResultBundleData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("12S Result Provenance", systemImage: "info.circle")
                .font(.headline)
            Divider()
            LabeledContent("Analysis", value: result.manifest.analysisName)
            LabeledContent("Samples", value: "\(result.samples.count)")
            LabeledContent("Exact Reads", value: "\(result.readFate.exactMatchReads)")
            LabeledContent("Unmatched", value: TwelveSReadFateSummary.formatPercent(result.readFate.unresolvedPercent))
            if let leftOut = TwelveSReadFateSummary.leftOutText(for: result.readFate) {
                LabeledContent("Left Out", value: leftOut)
            }
            LabeledContent("Created", value: result.manifest.createdAt ?? "Unknown")
            Divider()
            Text(result.artifacts.provenanceURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(minWidth: 320, alignment: .leading)
    }
}
