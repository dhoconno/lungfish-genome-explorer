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

    /// Monotonic generation counter for genotype-summary loads.
    ///
    /// Bumped on every `select(variant:)` and `clear()`. The off-main DB load
    /// captures the generation before its detached work and re-checks it on the
    /// main actor before committing the computed genotype properties, so a
    /// slower load for an older selection cannot clobber a newer one.
    private var loadGeneration: Int = 0

    /// In-flight genotype-summary load task, cancelled when superseded.
    private var loadTask: Task<Void, Never>?

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
    ///
    /// Eagerly resets genotype-summary display fields to their empty/loading state
    /// before dispatching the off-main load, so the panel never shows the new
    /// variant's identity next to a previous variant's stale counts.
    func select(variant: AnnotationSearchIndex.SearchResult) {
        selectedVariant = variant
        // Eager reset: blank the counts immediately so the UI shows the new
        // variant's identity with empty badges while the DB load is in flight,
        // rather than retaining the previous variant's stale counts.
        homRefCount = 0
        hetCount = 0
        homAltCount = 0
        noCallCount = 0
        infoFields = []
        hasGenotypes = false
        loadGenotypeSummary(for: variant)
    }

    /// Clears the variant selection.
    func clear() {
        // Bump the generation so any in-flight genotype load is superseded and
        // cannot commit stale counts after this clear.
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        selectedVariant = nil
        homRefCount = 0
        hetCount = 0
        homAltCount = 0
        noCallCount = 0
        infoFields = []
        hasGenotypes = false
    }

    /// Computed genotype summary produced off the main actor.
    private struct GenotypeSummary {
        var hasGenotypes: Bool
        var homRefCount: Int
        var hetCount: Int
        var homAltCount: Int
        var noCallCount: Int
        var infoFields: [(key: String, value: String)]
    }

    /// Loads genotype summary for a variant from the database.
    ///
    /// The four read-only `VariantDatabase` queries (`genotypes`, `sampleCount`,
    /// `query`, `infoValues`) run off the main actor in a detached task —
    /// `VariantDatabase` opens SQLite with `SQLITE_OPEN_FULLMUTEX` and each query
    /// prepares/finalizes its own statement, so concurrent read access is safe.
    ///
    /// This is a selection path: a newer `select`/`clear` can supersede this
    /// load while the detached queries are in flight. The generation captured
    /// before the await is re-checked on the main actor with ZERO await between
    /// the guard and the property commit, so a stale load commits nothing.
    private func loadGenotypeSummary(for variant: AnnotationSearchIndex.SearchResult) {
        // Bump the generation and cancel any prior in-flight load.
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = nil

        guard let rowId = variant.variantRowId else {
            hasGenotypes = false
            return
        }

        let db: VariantDatabase?
        if !variant.trackId.isEmpty, let match = variantDatabasesByTrackId[variant.trackId] {
            db = match
        } else {
            // Fallback: single-database common case (e.g. set via legacy .variantDatabase setter)
            db = variantDatabasesByTrackId.values.first
        }
        guard let db else {
            hasGenotypes = false
            return
        }

        // Capture the values needed off-main. `db` is @unchecked Sendable and
        // safe for concurrent reads (FULLMUTEX + per-call statements).
        let chromosome = variant.chromosome
        let start = variant.start
        let end = variant.end
        let searchResultSampleCount = variant.sampleCount

        loadTask = Task { [weak self] in
            let summary = await Self.computeGenotypeSummary(
                db: db,
                rowId: rowId,
                chromosome: chromosome,
                start: start,
                end: end,
                searchResultSampleCount: searchResultSampleCount
            )
            // Re-check the generation on the main actor. There is NO await
            // between this guard and the property commit below, so the guard
            // dominates the commit and a superseded load writes nothing.
            guard let self, self.loadGeneration == generation else { return }
            self.hasGenotypes = summary.hasGenotypes
            self.homRefCount = summary.homRefCount
            self.hetCount = summary.hetCount
            self.homAltCount = summary.homAltCount
            self.noCallCount = summary.noCallCount
            self.infoFields = summary.infoFields
        }
    }

    /// Awaits the in-flight genotype-summary load, if any.
    ///
    /// Test-only seam: the genotype load runs off the main actor, so tests must
    /// await it before asserting on the computed counts. Returns immediately
    /// when no load is in flight.
    func awaitGenotypeSummaryLoadForTesting() async {
        await loadTask?.value
    }

    /// Runs the read-only genotype/INFO queries off the main actor and folds
    /// them into a `GenotypeSummary`. Pure function of its inputs (identical
    /// output to the former synchronous computation).
    private nonisolated static func computeGenotypeSummary(
        db: VariantDatabase,
        rowId: Int64,
        chromosome: String,
        start: Int,
        end: Int,
        searchResultSampleCount: Int?
    ) async -> GenotypeSummary {
        await Task.detached {
            let genotypes = db.genotypes(forVariantId: rowId)
            let totalSamples = db.sampleCount()

            // Determine called sample count (hom-ref genotypes are omitted from the DB).
            // Prefer the SearchResult value; fall back to the DB variant record.
            let calledSamples: Int
            if let sc = searchResultSampleCount {
                calledSamples = sc
            } else {
                let records = db.query(chromosome: chromosome, start: start, end: end, limit: 1)
                calledSamples = records.first(where: { $0.id == rowId })?.sampleCount ?? 0
            }

            var het = 0, hAlt = 0
            for gt in genotypes {
                switch GenotypeDisplayCall.classify(genotype: gt.genotype, allele1: gt.allele1, allele2: gt.allele2) {
                case .homRef: break  // should not appear in DB (omitted)
                case .het:    het += 1
                case .homAlt: hAlt += 1
                case .noCall: break  // counted from calledSamples below
                }
            }

            // Fetch structured INFO from variant_info EAV table
            let infoDict = db.infoValues(variantId: rowId)
            let infoFields: [(key: String, value: String)] = infoDict.isEmpty
                ? []
                : infoDict.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) }

            return GenotypeSummary(
                hasGenotypes: true,
                // Infer hom-ref: called minus non-hom-ref called genotypes (het + homAlt).
                homRefCount: max(0, calledSamples - (het + hAlt)),
                hetCount: het,
                homAltCount: hAlt,
                // No-call = total samples minus called samples.
                noCallCount: max(0, totalSamples - calledSamples),
                infoFields: infoFields
            )
        }.value
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
        case "DEL": return .lungfishDangerFallback
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
