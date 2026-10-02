import AppKit
import SwiftUI
import LungfishIO
import LungfishKit

/// Sortable pairwise identity (or p-distance) table backed by `MSADistanceMatrix`, the same
/// service `lungfish-cli msa distance` uses. Copy hands over the CLI's TSV layout; Export runs
/// the CLI through the Operation Center so the file gets a provenance sidecar.
struct MSAPairwiseIdentitySection: View {
    @Bindable var model: MSAPairwiseIdentityInspectorModel
    @Binding var isExpanded: Bool

    /// Extra width for the header's sort indicator beside the widest text.
    static let numericColumnPadding: CGFloat = 14

    /// Space between the table's columns.
    static let columnSpacing: CGFloat = 6

    /// The narrowest a sequence-name column gets before the names truncate
    /// to nothing; the full name stays in the tooltip.
    static let minimumNameColumnWidth: CGFloat = 24

    /// The narrowest content width the whole table needs: both name columns
    /// at their minimum plus the fixed numeric columns. Below this nothing
    /// fits; at the Inspector's minimum width the table always fits.
    static func minimumTableWidth(pointSize: CGFloat, largestSiteCount: Int) -> CGFloat {
        2 * minimumNameColumnWidth
            + valueColumnWidth(pointSize: pointSize)
            + sitesColumnWidth(pointSize: pointSize, largestSiteCount: largestSiteCount)
            + 3 * columnSpacing
    }

    /// The width a numeric column needs to show its widest sample text (the
    /// header or a value) whole, measured at the Inspector's content font so
    /// a larger text size widens the column instead of cutting the values.
    static func numericColumnWidth(fitting samples: [String], pointSize: CGFloat) -> CGFloat {
        let digits = NSFont.monospacedDigitSystemFont(ofSize: pointSize, weight: .regular)
        let header = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let widest = samples.map { sample in
            max(
                (sample as NSString).size(withAttributes: [.font: digits]).width,
                (sample as NSString).size(withAttributes: [.font: header]).width
            )
        }.max() ?? 0
        return ceil(widest) + numericColumnPadding
    }

    /// Values are written with six decimals, as lungfish-cli msa distance does.
    static func valueColumnWidth(pointSize: CGFloat) -> CGFloat {
        numericColumnWidth(
            fitting: MSADistanceModel.allCases.map(\.displayName) + [MSADistanceMatrix.formatValue(0.888888)],
            pointSize: pointSize
        )
    }

    static func sitesColumnWidth(pointSize: CGFloat, largestSiteCount: Int) -> CGFloat {
        numericColumnWidth(fitting: ["Sites", "\(max(largestSiteCount, 99_999))"], pointSize: pointSize)
    }

    private var contentPointSize: CGFloat {
        ContentTypographyModel.shared.resolvedNSFont(for: .body).pointSize
    }

    var body: some View {
        DisclosureGroup("Pairwise Identity", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                controls
                content
            }
            .padding(.top, 4)
            .task(id: isExpanded) {
                guard isExpanded, model.status == .idle else { return }
                await model.compute()
            }
            .onChange(of: model.model) { _, _ in
                guard isExpanded else { return }
                Task { await model.compute() }
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
        .accessibilityIdentifier("msa-pairwise-identity-section")
    }

    /// The model picker and the two buttons share a row when the Inspector is
    /// wide enough; otherwise the buttons move under the picker instead of
    /// being clipped at the Inspector's edge.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                modelPicker
                Spacer(minLength: 0)
                copyButton
                exportButton
            }
            VStack(alignment: .leading, spacing: 6) {
                modelPicker
                HStack(spacing: 8) {
                    copyButton
                    exportButton
                }
            }
        }
    }

    private var modelPicker: some View {
        Picker("Model", selection: $model.model) {
            ForEach(MSADistanceModel.allCases) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
        .labelsHidden()
        .font(LungfishInspectorStyle.controlFont)
        .fixedSize()
        .accessibilityIdentifier("msa-pairwise-identity-model")
    }

    private var copyButton: some View {
        Button("Copy TSV") { model.copyTSV() }
            .font(LungfishInspectorStyle.controlFont)
            .fixedSize()
            .disabled(model.tsv == nil)
            .help("Copy the full matrix as tab-separated text, in the same layout lungfish-cli msa distance writes")
            .accessibilityIdentifier("msa-pairwise-identity-copy")
    }

    private var exportButton: some View {
        Button("Export TSV…") { model.requestExport() }
            .font(LungfishInspectorStyle.controlFont)
            .fixedSize()
            .disabled(model.onExportRequested == nil)
            .help("Write the matrix with a provenance sidecar using lungfish-cli msa distance")
            .accessibilityIdentifier("msa-pairwise-identity-export")
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .idle, .computing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Computing pairwise \(model.model.displayName.lowercased())…")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
        case .tooManyRows(let count):
            Text("This alignment has \(count) sequences, more than the \(MSAPairwiseIdentityInspectorModel.maxRowsForInlineTable) shown inline. Use Export TSV… to compute the full matrix as an operation.")
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(Color.lungfishDangerFallback)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            if model.pairs.isEmpty {
                Text("The alignment has fewer than two sequences, so there are no pairs to compare.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            } else {
                // A native Table: its rows are AX rows, its headers sort on
                // click or Space, and the arrow keys walk it. The numeric
                // columns are fixed to their widest text and the two name
                // columns share the rest, so it fits the Inspector's width.
                pairTable
                .accessibilityIdentifier("msa-pairwise-identity-table")
                Text("\(model.pairs.count) pairs, gaps skipped pairwise. Values match lungfish-cli msa distance --model \(model.model.rawValue).")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension MSAPairwiseIdentitySection {
    private var numericWidths: (value: CGFloat, sites: CGFloat) {
        (
            Self.valueColumnWidth(pointSize: contentPointSize),
            Self.sitesColumnWidth(
                pointSize: contentPointSize,
                largestSiteCount: model.pairs.map(\.comparableSites).max() ?? 0
            )
        )
    }

    var pairTable: some View {
        let widths = numericWidths
        return Table(model.sortedPairs, sortOrder: $model.sortOrder) {
            TableColumn("Sequence A", value: \.rowName) { pair in
                nameCell(pair.rowName)
            }
            .width(min: Self.minimumNameColumnWidth)
            TableColumn("Sequence B", value: \.columnName) { pair in
                nameCell(pair.columnName)
            }
            .width(min: Self.minimumNameColumnWidth)
            TableColumn(model.model.displayName, sortUsing: KeyPathComparator(\.sortableValue, order: .reverse)) { pair in
                numericCell(pair.formattedValue)
            }
            .width(widths.value)
            TableColumn("Sites", sortUsing: KeyPathComparator(\.comparableSites, order: .reverse)) { pair in
                numericCell("\(pair.comparableSites)")
            }
            .width(widths.sites)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .font(LungfishInspectorStyle.controlFont.weight(.regular))
        .frame(
            minHeight: 120,
            idealHeight: min(320, CGFloat(model.pairs.count + 1) * 24 + 8),
            maxHeight: 320
        )
    }

    private func nameCell(_ name: String) -> some View {
        Text(name)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(name)
    }

    private func numericCell(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
