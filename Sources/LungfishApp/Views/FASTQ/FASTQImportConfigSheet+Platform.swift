// FASTQImportConfigSheet+Platform.swift - The Platform popup of the Import FASTQ sheet and its evidence line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow

extension FASTQImportConfigSheet {

    /// The popup items, in order. The last item is added only when the
    /// selected samples look like different platforms.
    nonisolated static let platformChoices: [(platform: LungfishIO.SequencingPlatform, title: String)] = [
        (.illumina, "Illumina"),
        (.oxfordNanopore, "Oxford Nanopore"),
        (.pacbio, "PacBio"),
        (.element, "Element Biosciences"),
        (.ultima, "Ultima Genomics"),
        (.mgi, "MGI / DNBSEQ"),
        (.unknown, "Unknown / Other"),
    ]

    nonisolated static let perSamplePlatformTitle = "Detected per sample"

    /// What the sheet detected and the one line it shows about it.
    struct PlatformDetectionSummary: Equatable, Sendable {
        /// The platform to preselect. Ignored when `perSample` is true.
        let platform: LungfishIO.SequencingPlatform
        /// The samples look like different platforms, so the import infers each one.
        let perSample: Bool
        /// The evidence line shown under the summary.
        let line: String
    }

    /// Infers the platform of up to `sampleLimit` samples with the detector
    /// `lungfish-cli import fastq --platform auto` uses. Samples whose files
    /// are not on disk yet (an ENA or SRA run before download) keep
    /// `fallback`, the platform the archive record names.
    nonisolated static func platformDetectionSummary(
        pairs: [FASTQFilePair],
        fallback: LungfishIO.SequencingPlatform,
        sampleLimit: Int = 8
    ) -> PlatformDetectionSummary {
        let local = pairs.prefix(sampleLimit).filter { FileManager.default.fileExists(atPath: $0.r1.path) }
        guard !local.isEmpty else {
            let line = fallback == .unknown
                ? "Platform not known yet. It is inferred from the reads after download unless you choose one."
                : "Platform from the archive record: \(fallback.displayName)."
            return PlatformDetectionSummary(platform: fallback, perSample: false, line: line)
        }
        let inferences = local.map { pair in
            SequencingReadImportSource.isBAM(pair.r1)
                ? PlatformInference.infer(fromBAM: pair.r1)
                : PlatformInference.infer(fromFASTQ: pair.r1)
        }
        let platforms = inferences.map { $0.isActionable ? $0.platform : .unknown }
        let distinct = Set(platforms)
        if distinct.count > 1 {
            let counts = platformChoices.compactMap { choice -> String? in
                let count = platforms.filter { $0 == choice.platform }.count
                return count > 0 ? "\(count) \(choice.platform.displayName)" : nil
            }
            return PlatformDetectionSummary(
                platform: fallback,
                perSample: true,
                line: "Detected per sample: \(counts.joined(separator: ", ")). Each sample is imported as its own platform."
            )
        }
        let inference = inferences[0]
        if inference.isActionable {
            return PlatformDetectionSummary(
                platform: inference.platform,
                perSample: false,
                line: "Detected from read headers: \((inference.evidence.first ?? inference.summary).trimmingCharacters(in: CharacterSet(charactersIn: "."))) (\(inference.confidence.rawValue) confidence)."
            )
        }
        return PlatformDetectionSummary(
            platform: .unknown,
            perSample: false,
            line: "Not detected. \(inference.evidence.first ?? "") Choose the platform the reads came from, or keep Unknown."
        )
    }

    /// Fills the Platform popup, preselects the detection and returns it.
    func populatePlatformPopup(
        _ popup: NSPopUpButton,
        pairs: [FASTQFilePair],
        detectedPlatform: LungfishIO.SequencingPlatform
    ) -> PlatformDetectionSummary {
        let summary = Self.platformDetectionSummary(pairs: pairs, fallback: detectedPlatform)
        popup.removeAllItems()
        for choice in Self.platformChoices {
            popup.addItem(withTitle: choice.title)
        }
        if summary.perSample {
            popup.addItem(withTitle: Self.perSamplePlatformTitle)
            popup.selectItem(at: Self.platformChoices.count)
        } else {
            popup.selectItem(at: Self.platformChoices.firstIndex { $0.platform == summary.platform } ?? Self.platformChoices.count - 1)
        }
        popup.toolTip = summary.line
        popup.setAccessibilityHelp(summary.line)
        return summary
    }

    /// The platform the popup shows, or nil for "Detected per sample".
    static func platformChoice(in popup: NSPopUpButton) -> LungfishIO.SequencingPlatform? {
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < platformChoices.count else { return nil }
        return platformChoices[index].platform
    }
}
