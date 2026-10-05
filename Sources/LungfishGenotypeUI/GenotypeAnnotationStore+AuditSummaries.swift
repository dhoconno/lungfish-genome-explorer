// GenotypeAnnotationStore+AuditSummaries.swift - Summary strings for genotype annotation audit entries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension GenotypeAnnotationStore {
    func settingsSummary(_ settings: GenotypeAnnotationSidecar.Settings) -> String {
        let overrides = settings.locusFractionOverrides?
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",") ?? "nil"
        return [
            "viewMode=\(settings.viewMode)",
            "panelLayout=\(settings.panelLayout)",
            "cardDensity=\(settings.cardDensity)",
            "cardDensityThreshold=\(settings.cardDensityThreshold)",
            "dropoutAbsolute=\(optional(settings.dropoutAbsolute))",
            "dropoutSampleFraction=\(optional(settings.dropoutSampleFraction))",
            "dropoutLocusFraction=\(optional(settings.dropoutLocusFraction))",
            "locusFractionOverrides=\(overrides)",
            "activeHaplotypeDefinitionSetID=\(optional(settings.activeHaplotypeDefinitionSetID))",
            "activeHaplotypeAssayID=\(optional(settings.activeHaplotypeAssayID))",
            "preferredSummaryViewMode=\(optional(settings.preferredSummaryViewMode))",
            "mhcCandidateDisplay=\(mhcCandidateDisplaySummary(settings.mhcCandidateDisplay))",
            "genotypeLocusDisplayOrder=\(settings.genotypeLocusDisplayOrder?.joined(separator: ",") ?? "bundle-default")",
        ].joined(separator: "; ")
    }

    func mhcCandidateDisplaySummary(_ display: ONTMHCCandidateDisplaySettings) -> String {
        let tintSummary = ONTMHCCandidateTintCategory.allCases.map { category in
            let color = display.tints[category]
                ?? ONTMHCCandidateDisplaySettings.defaultTints[category]!
            return "\(category.rawValue)=\(mhcCandidateTintSummary(color))"
        }.joined(separator: ",")
        return [
            "showKnown=\(display.showKnown)",
            "showSharedCandidates=\(display.showSharedCandidates)",
            "showSingletonCandidates=\(display.showSingletonCandidates)",
            tintSummary,
        ].joined(separator: "; ")
    }

    private func mhcCandidateTintSummary(_ color: AnnotationColor) -> String {
        "{red=\(color.red),green=\(color.green),blue=\(color.blue),alpha=\(color.alpha),hexRGB=\(color.hexString)}"
    }

    func smartCohortSummary(_ cohort: GenotypeCohortSmartFilter) -> String {
        [
            "name=\(cohort.name)",
            "scope=\(cohort.scope)",
            "starred=\(cohort.isStarred)",
            "predicate=\(cohort.predicate)",
            "searchProjectionText=\(cohort.searchProjectionText ?? "nil")",
        ].joined(separator: "; ")
    }

    private func optional<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? "nil"
    }

    func matrixStyleSummary(_ style: GenotypeAnnotationSidecar.MatrixStyle?) -> String? {
        guard let style else { return nil }
        var parts: [String] = []
        if let fill = style.fillColor {
            parts.append("fill=\(fill)")
        }
        if let text = style.textColor {
            parts.append("text=\(text)")
        }
        if let border = style.borderColor {
            parts.append("border=\(border)")
        }
        if style.isBold {
            parts.append("bold")
        }
        if style.isItalic {
            parts.append("italic")
        }
        return parts.isEmpty ? "none" : parts.joined(separator: "; ")
    }
}
