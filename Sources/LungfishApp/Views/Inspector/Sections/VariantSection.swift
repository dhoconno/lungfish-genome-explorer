// VariantSection.swift - Inspector section for variant detail display
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO

/// A fixed variant-table value carried with selection notifications so the
/// Inspector presents the same resolved text as the table.
public struct VariantInspectorField: Sendable, Equatable {
    public let key: String
    public let label: String
    public let value: String

    public init(key: String, label: String, value: String) {
        self.key = key
        self.label = label
        self.value = value
    }
}

/// Immutable table-resolved payload for one selected Calls or Genotypes row.
public struct VariantSelectionEntry: Sendable, Identifiable {
    public let result: AnnotationSearchIndex.SearchResult
    public let fields: [VariantInspectorField]
    public let sampleName: String?

    public init(
        result: AnnotationSearchIndex.SearchResult,
        fields: [VariantInspectorField],
        sampleName: String? = nil
    ) {
        self.result = result
        self.fields = fields
        self.sampleName = sampleName
    }

    /// Variant identity intentionally excludes sample so genotype rows for the
    /// same call count as one unique variant.
    public var stableVariantIdentity: String {
        if let rowID = result.variantRowId {
            return "row:\(result.trackId):\(rowID)"
        }
        return [
            "coordinate", result.trackId, result.chromosome,
            String(result.start), String(result.end), result.ref ?? "", result.alt ?? "", result.name,
        ].joined(separator: "\u{1f}")
    }

    public var id: String {
        "\(stableVariantIdentity)\u{1f}sample:\(sampleName ?? "")"
    }
}

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

    /// Fixed fields resolved by the variant table for the selected row.
    var tableFields: [VariantInspectorField] = []

    /// Rich row payloads for an explicit multi-row (or genotype-row) selection.
    var selectionEntries: [VariantSelectionEntry] = []

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

    var hasVariantSelection: Bool { !selectionEntries.isEmpty }

    var uniqueVariantCount: Int {
        Set(selectionEntries.map(\.stableVariantIdentity)).count
    }

    var trackBreakdown: [String: Int] { breakdown { $0.result.trackId } }
    var chromosomeBreakdown: [String: Int] { breakdown { $0.result.chromosome } }
    var typeBreakdown: [String: Int] { breakdown { $0.result.type } }

    // MARK: - Methods

    /// Selects a variant and populates genotype summary.
    ///
    /// Eagerly resets genotype-summary display fields to their empty/loading state
    /// before dispatching the off-main load, so the panel never shows the new
    /// variant's identity next to a previous variant's stale counts.
    func select(
        variant: AnnotationSearchIndex.SearchResult,
        tableFields: [VariantInspectorField] = []
    ) {
        selectionEntries = []
        selectedVariant = variant
        self.tableFields = tableFields.isEmpty ? Self.fallbackTableFields(for: variant) : tableFields
        // Eager reset: blank the counts immediately so the UI shows the new
        // variant's identity with empty badges while the DB load is in flight,
        // rather than retaining the previous variant's stale counts.
        homRefCount = 0
        hetCount = 0
        homAltCount = 0
        noCallCount = 0
        infoFields = Self.sortedInfoFields(variant.infoDict ?? [:])
        hasGenotypes = false
        loadGenotypeSummary(for: variant)
    }

    /// Selects resolved table rows without issuing per-row database work.
    func select(entries: [VariantSelectionEntry]) {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        selectedVariant = nil
        tableFields = []
        homRefCount = 0
        hetCount = 0
        homAltCount = 0
        noCallCount = 0
        infoFields = []
        hasGenotypes = false
        selectionEntries = entries
    }

    /// Clears the variant selection.
    func clear() {
        // Bump the generation so any in-flight genotype load is superseded and
        // cannot commit stale counts after this clear.
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        selectedVariant = nil
        selectionEntries = []
        tableFields = []
        homRefCount = 0
        hetCount = 0
        homAltCount = 0
        noCallCount = 0
        infoFields = []
        hasGenotypes = false
    }

    func copySelectionText() -> String {
        selectionEntries.enumerated().map { index, entry in
            var lines = ["Variant \(index + 1): \(entry.result.name)"]
            if let sampleName = entry.sampleName { lines.append("Sample: \(sampleName)") }
            lines.append(contentsOf: entry.fields.filter { !$0.value.isEmpty }.map { "\($0.label): \($0.value)" })
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func breakdown(_ key: (VariantSelectionEntry) -> String) -> [String: Int] {
        Dictionary(grouping: selectionEntries, by: key).mapValues(\.count)
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
        if let match = variantDatabasesByTrackId[variant.trackId] {
            db = match
        } else if variantDatabasesByTrackId.count == 1,
                  let legacy = variantDatabasesByTrackId["default"] {
            // Preserve the legacy single-database accessor without choosing an
            // arbitrary real track for an unmatched explicit track ID.
            db = legacy
        } else if variant.trackId.isEmpty, variantDatabasesByTrackId.count == 1 {
            db = variantDatabasesByTrackId.values.first
        } else {
            db = nil
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
        let projectedInfo = variant.infoDict ?? [:]

        loadTask = Task { [weak self] in
            let summary = await Self.computeGenotypeSummary(
                db: db,
                rowId: rowId,
                chromosome: chromosome,
                start: start,
                end: end,
                searchResultSampleCount: searchResultSampleCount,
                projectedInfo: projectedInfo
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
        searchResultSampleCount: Int?,
        projectedInfo: [String: String]
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
            var infoDict = db.infoValues(variantId: rowId)
            // The current table row may contain runtime-recovered FORMAT aliases
            // (for example iVar AF). Its visible value is authoritative.
            infoDict.merge(projectedInfo) { _, projected in projected }
            let infoFields = sortedInfoFields(infoDict)

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

    nonisolated private static func sortedInfoFields(
        _ info: [String: String]
    ) -> [(key: String, value: String)] {
        info.sorted(by: { $0.key < $1.key }).map { (key: $0.key, value: $0.value) }
    }

    private static func fallbackTableFields(
        for variant: AnnotationSearchIndex.SearchResult
    ) -> [VariantInspectorField] {
        var fields: [VariantInspectorField] = []
        let track = variant.trackName ?? (variant.trackId.isEmpty ? nil : variant.trackId)
        if let track, !track.isEmpty {
            fields.append(.init(key: "track_name", label: "Variant Track", value: track))
        }
        if let count = variant.sampleCount {
            fields.append(.init(key: "samples", label: "Samples", value: String(count)))
        }
        if let source = variant.sourceFile, !source.isEmpty {
            fields.append(.init(key: "source", label: "Source", value: source))
        }
        let info = variant.infoDict ?? [:]
        let derived: [(String, String, [String])] = [
            ("coding_feature", "Gene / Protein", ["CSQ_SYMBOL", "ANN_Gene_Name", "GENE", "SYMBOL"]),
            ("consequence", "Consequence", ["CSQ_Consequence", "ANN_Consequence", "Consequence", "consequence", "ANN_Annotation", "EFFECT", "effect"]),
            ("aa_change", "AA Change", ["CSQ_HGVSp", "HGVSp", "ANN_HGVS_p", "AA_CHANGE", "CSQ_Amino_acids", "Amino_acids", "ANN_AA_pos_len"]),
        ]
        for (key, label, candidates) in derived {
            if let value = candidates.compactMap({ info[$0] }).first(where: { !$0.isEmpty && $0 != "." }) {
                fields.append(.init(key: key, label: label, value: value))
            }
        }
        return fields
    }

    func copyText(for variant: AnnotationSearchIndex.SearchResult) -> String {
        var lines = [
            "ID: \(variant.name)",
            "Type: \(variant.type)",
            "Position: \(variant.chromosome):\(variant.start + 1)-\(variant.end)",
        ]
        if let ref = variant.ref, let alt = variant.alt { lines.append("Alleles: \(ref) > \(alt)") }
        if let quality = variant.quality { lines.append("Quality: \(String(format: "%.1f", quality))") }
        if let filter = variant.filter { lines.append("Filter: \(filter)") }

        let identityKeys: Set<String> = [
            "variant_id", "variant_type", "chromosome", "position", "ref", "alt", "quality", "filter",
        ]
        lines.append(contentsOf: tableFields.compactMap { field in
            guard !identityKeys.contains(field.key), !field.value.isEmpty else { return nil }
            return "\(field.label): \(field.value)"
        })
        lines.append(contentsOf: infoFields.map { "\($0.key): \($0.value)" })
        if hasGenotypes {
            lines.append("Genotypes: HomRef=\(homRefCount), Het=\(hetCount), HomAlt=\(homAltCount), NoCall=\(noCallCount)")
            if let frequency = alleleFrequency {
                lines.append("Genotype-derived alt allele frequency: \(String(format: "%.4f", frequency))")
            }
        }
        return lines.joined(separator: "\n")
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
        if viewModel.hasVariantSelection {
            variantSelection
        } else if let variant = viewModel.selectedVariant {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    variantIdentity(variant)
                    Divider()
                    qualityAndFilter(variant)

                    if !detailTableFields.isEmpty {
                        Divider()
                        fixedFieldSection
                    }

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
                    .font(LungfishInspectorStyle.sectionTitleFont)
            }
        }
    }

    private var variantSelection: some View {
        DisclosureGroup(isExpanded: $viewModel.isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    summaryMetric("Selected Rows", value: viewModel.selectionEntries.count)
                    summaryMetric("Unique Variants", value: viewModel.uniqueVariantCount)
                }
                selectionBreakdown("Tracks", values: viewModel.trackBreakdown)
                selectionBreakdown("Chromosomes", values: viewModel.chromosomeBreakdown)
                selectionBreakdown("Types", values: viewModel.typeBreakdown)
                Divider()
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.selectionEntries) { entry in
                        variantSelectionEntry(entry)
                    }
                }
                Button {
                    viewModel.onCopyVariantInfo?(viewModel.copySelectionText())
                } label: {
                    Label("Copy Selection", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } label: {
            Label("Variant Selection", systemImage: "diamond.on.square")
                .font(LungfishInspectorStyle.sectionTitleFont)
        }
    }

    private func summaryMetric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.headline.monospacedDigit())
            Text(label).font(LungfishInspectorStyle.controlFont).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func selectionBreakdown(_ label: String, values: [String: Int]) -> some View {
        if !values.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .trailing)
                Text(values.keys.sorted().map { "\($0): \(values[$0] ?? 0)" }.joined(separator: ", "))
                    .font(LungfishInspectorStyle.controlFont.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func variantSelectionEntry(_ entry: VariantSelectionEntry) -> some View {
        DisclosureGroup {
            LazyVStack(alignment: .leading, spacing: 4) {
                if let sampleName = entry.sampleName {
                    selectionField(label: "Sample", value: sampleName)
                }
                ForEach(Array(entry.fields.enumerated()), id: \.offset) { _, field in
                    if !field.value.isEmpty {
                        selectionField(label: field.label, value: field.value)
                    }
                }
            }
            .padding(.leading, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.result.name).font(.body.monospaced()).textSelection(.enabled)
                Text("\(entry.result.chromosome):\(entry.result.start + 1)\(entry.sampleName.map { " · \($0)" } ?? "")")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectionField(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(LungfishInspectorStyle.controlFont.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func variantIdentity(_ variant: AnnotationSearchIndex.SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ID")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text(variant.name)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            HStack {
                Text("Type")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                variantTypeBadge(variant.type)
            }
            HStack {
                Text("Position")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                Text("\(variant.chromosome):\(variant.start + 1)")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let ref = variant.ref, let alt = variant.alt {
                HStack {
                    Text("Alleles")
                        .font(LungfishInspectorStyle.controlFont)
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
                        .font(LungfishInspectorStyle.controlFont)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.1f", quality))
                        .font(.system(.body, design: .monospaced))
                }
            }
            if let filter = variant.filter {
                HStack {
                    Text("Filter")
                        .font(LungfishInspectorStyle.controlFont)
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
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                genotypeCountBadge("Hom Ref", count: viewModel.homRefCount, color: .gray)
                genotypeCountBadge("Het", count: viewModel.hetCount, color: .blue)
                genotypeCountBadge("Hom Alt", count: viewModel.homAltCount, color: .cyan)
                genotypeCountBadge("No Call", count: viewModel.noCallCount, color: Color(.systemGray))
            }
            .font(LungfishInspectorStyle.controlFont)

            if let af = viewModel.alleleFrequency {
                HStack {
                    Text("Genotype-derived AF")
                        .font(LungfishInspectorStyle.controlFont)
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
                        .font(LungfishInspectorStyle.controlFont.monospaced())
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Variant Fields")
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)

            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.infoFields, id: \.key) { field in
                    HStack(alignment: .top) {
                        Text(field.key)
                            .font(LungfishInspectorStyle.controlFont.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        Text(field.value)
                            .font(LungfishInspectorStyle.controlFont.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var detailTableFields: [VariantInspectorField] {
        let keys: Set<String> = [
            "track_name", "caller_settings", "samples", "source",
            "coding_feature", "consequence", "aa_change",
        ]
        return viewModel.tableFields.filter { keys.contains($0.key) && !$0.value.isEmpty }
    }

    @ViewBuilder
    private var fixedFieldSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(detailTableFields, id: \.key) { field in
                HStack(alignment: .top) {
                    Text(field.label)
                        .font(LungfishInspectorStyle.controlFont)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(field.value)
                        .font(LungfishInspectorStyle.controlFont.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                let info = viewModel.copyText(for: variant)
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
            .font(LungfishInspectorStyle.controlFont)
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

}
