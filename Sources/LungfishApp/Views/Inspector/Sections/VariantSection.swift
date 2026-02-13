// VariantSection.swift - Inspector section for variant detail display
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO

// MARK: - VariantSectionViewModel

/// View model for the variant detail inspector section.
///
/// Displays detailed information about a selected variant including
/// genotype summary, INFO fields, and allele frequency.
@Observable
@MainActor
public final class VariantSectionViewModel {

    // MARK: - Properties

    /// The currently selected variant search result, if any.
    var selectedVariant: AnnotationSearchIndex.SearchResult?

    /// Genotype summary counts (populated from VariantDatabase).
    var homRefCount: Int = 0
    var hetCount: Int = 0
    var homAltCount: Int = 0
    var noCallCount: Int = 0

    /// Parsed INFO fields as key-value pairs.
    var infoFields: [(key: String, value: String)] = []

    /// Whether genotype data is available for this variant.
    var hasGenotypes: Bool = false

    /// Variant databases keyed by track ID.
    var variantDatabasesByTrackId: [String: VariantDatabase] = [:]

    /// Backward-compatible single-database accessor.
    var variantDatabase: VariantDatabase? {
        get { variantDatabasesByTrackId.values.first }
        set {
            if let newValue {
                variantDatabasesByTrackId["default"] = newValue
            } else {
                variantDatabasesByTrackId.removeAll()
            }
        }
    }

    /// Whether the variant detail section is expanded.
    var isExpanded: Bool = true

    // MARK: - Callbacks

    /// Called when the user requests zooming to the variant position.
    var onZoomToVariant: ((AnnotationSearchIndex.SearchResult) -> Void)?

    /// Called when the user copies variant info to clipboard.
    var onCopyVariantInfo: ((String) -> Void)?

    // MARK: - Computed Properties

    /// Total genotyped samples.
    var totalSamples: Int {
        homRefCount + hetCount + homAltCount + noCallCount
    }

    /// Alternate allele frequency (het + 2*homAlt) / (2 * total non-missing).
    var alleleFrequency: Double? {
        let called = homRefCount + hetCount + homAltCount
        guard called > 0 else { return nil }
        return Double(hetCount + 2 * homAltCount) / Double(2 * called)
    }

    /// Whether a variant is currently selected.
    var hasVariant: Bool { selectedVariant != nil }

    // MARK: - Methods

    /// Selects a variant and populates genotype summary.
    func select(variant: AnnotationSearchIndex.SearchResult) {
        selectedVariant = variant
        loadGenotypeSummary(for: variant)
    }

    /// Clears the variant selection.
    func clear() {
        selectedVariant = nil
        homRefCount = 0
        hetCount = 0
        homAltCount = 0
        noCallCount = 0
        infoFields = []
        hasGenotypes = false
    }

    /// Loads genotype summary for a variant from the database.
    private func loadGenotypeSummary(for variant: AnnotationSearchIndex.SearchResult) {
        guard let rowId = variant.variantRowId else {
            hasGenotypes = false
            return
        }

        let db: VariantDatabase?
        if !variant.trackId.isEmpty {
            db = variantDatabasesByTrackId[variant.trackId]
        } else {
            db = variantDatabasesByTrackId.values.first
        }
        guard let db else {
            hasGenotypes = false
            return
        }

        let genotypes = db.genotypes(forVariantId: rowId)
        let totalSamples = db.sampleCount()
        let calledSamples = variant.sampleCount ?? 0

        // For v3 databases (omitHomref), genotype rows only contain non-hom-ref calls.
        // Hom-ref count is inferred from sample_count minus stored non-hom-ref calls.
        // No-call count is inferred from total samples minus called samples.
        let dbOmitHomref = db.omitHomref

        if genotypes.isEmpty && !dbOmitHomref {
            hasGenotypes = false
            return
        }

        hasGenotypes = true
        var hRef = 0, het = 0, hAlt = 0, noCall = 0

        for gt in genotypes {
            switch GenotypeDisplayCall.classify(genotype: gt.genotype, allele1: gt.allele1, allele2: gt.allele2) {
            case .homRef: hRef += 1
            case .het:    het += 1
            case .homAlt: hAlt += 1
            case .noCall: noCall += 1
            }
        }

        if dbOmitHomref {
            // Infer hom-ref from called samples minus stored non-hom-ref genotypes.
            hRef = max(0, calledSamples - (het + hAlt + noCall))
            // Infer no-call from total samples minus called samples.
            noCall += max(0, totalSamples - calledSamples)
        }

        homRefCount = hRef
        hetCount = het
        homAltCount = hAlt
        noCallCount = noCall

        // Fetch structured INFO from variant_info EAV table (or fallback to raw parsing)
        let infoDict = db.infoValues(variantId: rowId)
        if !infoDict.isEmpty {
            infoFields = infoDict.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) }
        } else {
            // Legacy fallback: parse raw INFO string from the variant record
            let records = db.query(chromosome: variant.chromosome, start: variant.start, end: variant.end, limit: 1)
            if let record = records.first(where: { $0.id == rowId }), let info = record.info {
                infoFields = parseINFO(info)
            } else {
                infoFields = []
            }
        }
    }

    /// Parses a VCF INFO string into key-value pairs (legacy fallback).
    private func parseINFO(_ info: String) -> [(key: String, value: String)] {
        info.split(separator: ";").compactMap { field in
            let parts = field.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                return (key: String(parts[0]), value: String(parts[1]))
            } else if parts.count == 1 {
                return (key: String(parts[0]), value: "true")
            }
            return nil
        }
    }
}

// MARK: - VariantSection View

/// SwiftUI section showing variant details when a variant is selected.
///
/// Displays variant identity (ID, type, position, alleles), quality/filter,
/// genotype summary with allele frequency, and INFO field details.
public struct VariantSection: View {
    @Bindable var viewModel: VariantSectionViewModel

    public var body: some View {
        if let variant = viewModel.selectedVariant {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    variantIdentity(variant)
                    Divider()
                    qualityAndFilter(variant)

                    if viewModel.hasGenotypes {
                        Divider()
                        genotypeSummary
                    }

                    if !viewModel.infoFields.isEmpty {
                        Divider()
                        infoSection
                    }

                    Divider()
                    actionButtons(variant)
                }
            } label: {
                Label("Variant Detail", systemImage: "diamond")
                    .font(.headline)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func variantIdentity(_ variant: AnnotationSearchIndex.SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ID")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text(variant.name)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                Text("Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                variantTypeBadge(variant.type)
            }
            HStack {
                Text("Position")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text("\(variant.chromosome):\(variant.start + 1)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let ref = variant.ref, let alt = variant.alt {
                HStack {
                    Text("Alleles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text("\(ref) \u{2192} \(alt)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func qualityAndFilter(_ variant: AnnotationSearchIndex.SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let quality = variant.quality {
                HStack {
                    Text("Quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.1f", quality))
                        .font(.system(.body, design: .monospaced))
                }
            }
            if let filter = variant.filter {
                HStack {
                    Text("Filter")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(filter)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(filter == "PASS" ? .green : .orange)
                }
            }
        }
    }

    @ViewBuilder
    private var genotypeSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Genotype Summary")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                genotypeCountBadge("Hom Ref", count: viewModel.homRefCount, color: .gray)
                genotypeCountBadge("Het", count: viewModel.hetCount, color: .blue)
                genotypeCountBadge("Hom Alt", count: viewModel.homAltCount, color: .cyan)
                genotypeCountBadge("No Call", count: viewModel.noCallCount, color: Color(.systemGray))
            }
            .font(.caption)

            if let af = viewModel.alleleFrequency {
                HStack {
                    Text("Alt Allele Freq")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)

                    // Simple frequency bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 8)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: geometry.size.width * CGFloat(af), height: 8)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.3f", af))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("INFO Fields")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(viewModel.infoFields.prefix(20)), id: \.key) { field in
                HStack(alignment: .top) {
                    Text(field.key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    Text(field.value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }

            if viewModel.infoFields.count > 20 {
                Text("... and \(viewModel.infoFields.count - 20) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ variant: AnnotationSearchIndex.SearchResult) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.onZoomToVariant?(variant)
            } label: {
                Label("Zoom to Variant", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                let info = formatVariantInfo(variant)
                viewModel.onCopyVariantInfo?(info)
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func variantTypeBadge(_ type: String) -> some View {
        Text(type)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(variantTypeColor(type).opacity(0.2))
            .foregroundStyle(variantTypeColor(type))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func variantTypeColor(_ type: String) -> Color {
        switch type {
        case "SNP": return .green
        case "INS": return .purple
        case "DEL": return .red
        case "MNP": return .orange
        default: return .gray
        }
    }

    @ViewBuilder
    private func genotypeCountBadge(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }

    private func formatVariantInfo(_ variant: AnnotationSearchIndex.SearchResult) -> String {
        var lines: [String] = []
        lines.append("ID: \(variant.name)")
        lines.append("Type: \(variant.type)")
        lines.append("Position: \(variant.chromosome):\(variant.start + 1)-\(variant.end)")
        if let ref = variant.ref, let alt = variant.alt {
            lines.append("Alleles: \(ref) > \(alt)")
        }
        if let q = variant.quality {
            lines.append("Quality: \(String(format: "%.1f", q))")
        }
        if let f = variant.filter {
            lines.append("Filter: \(f)")
        }
        if viewModel.hasGenotypes {
            lines.append("Genotypes: HomRef=\(viewModel.homRefCount), Het=\(viewModel.hetCount), HomAlt=\(viewModel.homAltCount), NoCall=\(viewModel.noCallCount)")
            if let af = viewModel.alleleFrequency {
                lines.append("Alt Allele Freq: \(String(format: "%.4f", af))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
