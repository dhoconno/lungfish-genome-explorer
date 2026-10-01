import AppKit
import SwiftUI
import LungfishIO
import LungfishKit

enum MultipleSequenceAlignmentDocumentSectionKind: Equatable {
    case header
    case alignmentSummary
    case warnings
    case sourceArtifacts
}

struct MultipleSequenceAlignmentDocumentArtifactRow: Equatable {
    let label: String
    let fileURL: URL?
}

struct MultipleSequenceAlignmentDocumentState: Equatable {
    let title: String
    let subtitle: String?
    let summary: String?
    let contextRows: [(String, String)]
    let warningRows: [String]
    let artifactRows: [MultipleSequenceAlignmentDocumentArtifactRow]
    let consensusPreview: String

    var visibleSectionOrder: [MultipleSequenceAlignmentDocumentSectionKind] {
        [.header, .alignmentSummary, .warnings, .sourceArtifacts]
    }

    static func == (
        lhs: MultipleSequenceAlignmentDocumentState,
        rhs: MultipleSequenceAlignmentDocumentState
    ) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.summary == rhs.summary &&
            lhs.contextRows.elementsEqual(rhs.contextRows, by: { $0.0 == $1.0 && $0.1 == $1.1 }) &&
            lhs.warningRows == rhs.warningRows &&
            lhs.artifactRows == rhs.artifactRows &&
            lhs.consensusPreview == rhs.consensusPreview
    }
}

struct MultipleSequenceAlignmentDocumentSection: View {
    let state: MultipleSequenceAlignmentDocumentState
    /// Pairwise identity table state; nil hides the section (read-only alignments, tests).
    var pairwiseIdentity: MSAPairwiseIdentityInspectorModel?
    /// Discriminating-sites state; nil hides the section (read-only alignments, tests).
    var discriminatingSites: MSADiscriminatingSitesInspectorModel?

    @State private var isSummaryExpanded = true
    @State private var isWarningsExpanded = true
    @State private var isArtifactsExpanded = true
    @State private var isPairwiseIdentityExpanded = false
    @State private var isDiscriminatingSitesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            summarySection

            if let pairwiseIdentity {
                Divider()

                MSAPairwiseIdentitySection(model: pairwiseIdentity, isExpanded: $isPairwiseIdentityExpanded)
            }

            if let discriminatingSites {
                Divider()

                MSADiscriminatingSitesSection(model: discriminatingSites, isExpanded: $isDiscriminatingSitesExpanded)
            }

            Divider()

            warningsSection

            Divider()

            artifactSection
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.title)
                .font(LungfishInspectorStyle.sectionTitleFont)
                .lineLimit(2)
            if let subtitle = state.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
            if let summary = state.summary, !summary.isEmpty {
                Text(summary)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarySection: some View {
        DisclosureGroup("Alignment Summary", isExpanded: $isSummaryExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(state.contextRows.enumerated()), id: \.offset) { _, row in
                    contextRow(label: row.0, value: row.1)
                }
                if !state.consensusPreview.isEmpty {
                    contextRow(label: "Consensus", value: state.consensusPreview)
                }
            }
            .padding(.top, 4)
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private var warningsSection: some View {
        DisclosureGroup("Warnings", isExpanded: $isWarningsExpanded) {
            if state.warningRows.isEmpty {
                emptyMessage("No warnings were recorded for this alignment.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.warningRows.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(LungfishInspectorStyle.controlFont)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private var artifactSection: some View {
        DisclosureGroup("Source Artifacts", isExpanded: $isArtifactsExpanded) {
            if state.artifactRows.isEmpty {
                emptyMessage("No alignment artifacts are available.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.artifactRows.enumerated()), id: \.offset) { _, row in
                        artifactRow(row)
                    }
                }
                .padding(.top, 4)
            }
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private func contextRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            Text(value)
                .font(LungfishInspectorStyle.controlFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func artifactRow(_ row: MultipleSequenceAlignmentDocumentArtifactRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fileURL = row.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                Button(row.label) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.link)
                .font(LungfishInspectorStyle.controlFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Reveal in Finder")
                pathCaption(fileURL.path)
            } else {
                Text(row.label)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let fileURL = row.fileURL {
                    pathCaption(fileURL.path)
                } else {
                    pathCaption("Missing")
                }
            }
        }
    }

    private func pathCaption(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

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
            TableColumn(model.model.displayName, value: \.sortableValue) { pair in
                numericCell(pair.formattedValue)
            }
            .width(widths.value)
            TableColumn("Sites", value: \.comparableSites) { pair in
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

/// Target / exclusion picker, tolerance and window settings, and the sortable
/// site and candidate-window tables of `lungfish-cli msa discriminating-sites`.
/// "Find Discriminating Sites" runs the CLI through the Operation Center; the
/// tables are read back from the JSON report it wrote, and "Export TSV…" /
/// "Export JSON…" run the same command into a destination the user picks.
struct MSADiscriminatingSitesSection: View {
    @Bindable var model: MSADiscriminatingSitesInspectorModel
    @Binding var isExpanded: Bool

    private static let noTemplateTag = ""
    private static let noExclusionFileTag = ""

    var body: some View {
        DisclosureGroup("Discriminating Sites", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Columns where every target row carries one base that the exclusion sequences do not. Anchor a primer 3′ end or a probe on one to make the assay specific.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                exclusionSourceControls
                rowRoleList
                settingsControls
                runControls
                resultContent
            }
            .padding(.top, 4)
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
        .accessibilityIdentifier("msa-discriminating-sites-section")
    }

    // MARK: - Inputs

    private var exclusionSourceControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Exclusions")
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
            Picker("Exclusions", selection: $model.exclusionSource) {
                ForEach(MSADiscriminatingSitesInspectorModel.ExclusionSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .font(LungfishInspectorStyle.controlFont)
            .accessibilityIdentifier("msa-discriminating-sites-exclusion-source")

            if model.exclusionSource == .file {
                HStack(spacing: 8) {
                    Picker("Exclusion sequences", selection: exclusionFileSelection) {
                        Text("Choose…").tag(Self.noExclusionFileTag)
                        ForEach(model.projectExclusionOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                        if let chosen = model.exclusionFileURL,
                           !model.projectExclusionOptions.contains(where: { $0.url == chosen }) {
                            Text(chosen.lastPathComponent).tag(chosen.path)
                        }
                    }
                    .labelsHidden()
                    .font(LungfishInspectorStyle.controlFont)
                    .accessibilityIdentifier("msa-discriminating-sites-exclusion-file")

                    Button("Choose File…") { model.requestChooseExclusionFile() }
                        .font(LungfishInspectorStyle.controlFont)
                        .disabled(model.onChooseExclusionFileRequested == nil)
                        .help("Pick a FASTA file or .lungfishref bundle. Its sequences are aligned onto the target alignment with the managed MAFFT, as lungfish-cli msa discriminating-sites --exclusion-sequences does.")
                        .accessibilityIdentifier("msa-discriminating-sites-choose-file")
                }
                Text("The sequences are aligned onto this alignment with MAFFT --add --keeplength, so target coordinates are unchanged.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var exclusionFileSelection: Binding<String> {
        Binding(
            get: { model.exclusionFileURL?.path ?? Self.noExclusionFileTag },
            set: { newValue in
                if newValue == Self.noExclusionFileTag {
                    model.exclusionFileURL = nil
                } else if let option = model.projectExclusionOptions.first(where: { $0.id == newValue }) {
                    model.exclusionFileURL = option.url
                } else {
                    model.exclusionFileURL = URL(fileURLWithPath: newValue)
                }
            }
        )
    }

    private var rowRoleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.exclusionSource == .rows ? "Rows" : "Target rows")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("All Targets") { model.setAllRoles(.target) }
                    .font(LungfishInspectorStyle.controlFont)
                    .controlSize(.small)
                    .help("Mark every row as a target")
                    .accessibilityIdentifier("msa-discriminating-sites-all-targets")
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.rows) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .font(LungfishInspectorStyle.controlFont)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Role of \(row.name)", selection: roleSelection(for: row)) {
                            ForEach(availableRoles) { role in
                                Text(role.rawValue).tag(role)
                            }
                        }
                        .labelsHidden()
                        .font(LungfishInspectorStyle.controlFont)
                        .frame(width: 104)
                        .accessibilityIdentifier("msa-discriminating-sites-role-\(row.id)")
                    }
                }
            }
            Text(roleSummary)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// With exclusions from a file, a row is either a target or skipped.
    private var availableRoles: [MSADiscriminatingSitesInspectorModel.RowRole] {
        model.exclusionSource == .rows ? [.target, .exclusion, .skip] : [.target, .skip]
    }

    private func roleSelection(
        for row: MSADiscriminatingSitesInspectorModel.RowOption
    ) -> Binding<MSADiscriminatingSitesInspectorModel.RowRole> {
        Binding(
            get: {
                let role = model.role(of: row)
                return role == .exclusion && model.exclusionSource == .file ? .skip : role
            },
            set: { model.setRole($0, for: row) }
        )
    }

    private var roleSummary: String {
        var parts = ["\(model.targetRows.count) target\(model.targetRows.count == 1 ? "" : "s")"]
        if model.exclusionSource == .rows {
            parts.append("\(model.exclusionRows.count) exclusion\(model.exclusionRows.count == 1 ? "" : "s")")
        }
        if !model.skippedRows.isEmpty {
            parts.append("\(model.skippedRows.count) skipped")
        }
        return parts.joined(separator: ", ")
    }

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Template")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                Picker("Template", selection: templateSelection) {
                    Text("First target").tag(Self.noTemplateTag)
                    ForEach(model.targetRows) { row in
                        Text(row.name).tag(row.id)
                    }
                }
                .labelsHidden()
                .font(LungfishInspectorStyle.controlFont)
                .help("The target row whose 1-based positions the report uses")
                .accessibilityIdentifier("msa-discriminating-sites-template")
            }
            numberField(
                "Target mismatch tolerance", text: $model.targetMismatchToleranceText,
                help: "How many target rows may carry a different base and still let a column qualify. 0 demands that every target agrees.",
                identifier: "msa-discriminating-sites-tolerance"
            )
            numberField(
                "Window length (bp)", text: $model.windowLengthText,
                help: "Template bases spanned when clustered columns are grouped into candidate oligo windows. A probe length is the useful default.",
                identifier: "msa-discriminating-sites-window-length"
            )
            numberField(
                "Exclusions that must differ", text: $model.minimumExclusionDifferencesText,
                placeholder: "All",
                help: "How many exclusion sequences must carry a different base. Blank means all of them.",
                identifier: "msa-discriminating-sites-min-exclusion-differences"
            )
        }
    }

    private func numberField(
        _ title: String,
        text: Binding<String>,
        placeholder: String = "",
        help: String,
        identifier: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            TextField(title, text: text, prompt: placeholder.isEmpty ? nil : Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .font(LungfishInspectorStyle.controlFont)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .labelsHidden()
                .help(help)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    private var templateSelection: Binding<String> {
        Binding(
            get: { model.templateRowID ?? Self.noTemplateTag },
            set: { model.templateRowID = $0 == Self.noTemplateTag ? nil : $0 }
        )
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Find Discriminating Sites") { model.requestRun() }
                    .font(LungfishInspectorStyle.controlFont)
                    .disabled(!model.canRun || model.onRunRequested == nil)
                    .help("Run lungfish-cli msa discriminating-sites through the Operation Center")
                    .accessibilityIdentifier("msa-discriminating-sites-run")
                if model.status == .running {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            if let message = model.validationMessage {
                Text(message)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultContent: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .running:
            Text("Scoring alignment columns…")
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(Color.lungfishDangerFallback)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            resultTables
        }
    }

    private var resultTables: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ForEach(Array(model.summaryLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Toggle("Highlight in viewport", isOn: $model.highlightsEnabled)
                .font(LungfishInspectorStyle.controlFont)
                .help("Tint the discriminating columns in the alignment and name each row as a target or an exclusion")
                .accessibilityIdentifier("msa-discriminating-sites-highlight")

            if model.sites.isEmpty {
                Text("No column separates every target from the exclusion sequences with these settings.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Select a row to show that column in the viewport.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.tertiary)
                Table(model.sortedSites, selection: $model.selectedSiteColumn, sortOrder: $model.siteSortOrder) {
                    TableColumn("Column", value: \.column) { site in
                        Text("\(site.column)").font(LungfishInspectorStyle.controlFont).monospacedDigit()
                    }
                    .width(min: 52, ideal: 60)
                    TableColumn("Template", value: \.templateSortKey) { site in
                        Text(site.templatePositionText).font(LungfishInspectorStyle.controlFont).monospacedDigit()
                    }
                    .width(min: 60, ideal: 68)
                    TableColumn("Target", value: \.targetBase) { site in
                        Text(site.targetBase).font(LungfishInspectorStyle.controlFont)
                    }
                    .width(min: 44, ideal: 50)
                    TableColumn("Differing", value: \.exclusionDifferenceCount) { site in
                        Text("\(site.exclusionDifferenceCount)").font(LungfishInspectorStyle.controlFont).monospacedDigit()
                    }
                    .width(min: 56, ideal: 64)
                    TableColumn("Exclusions", value: \.exclusionNames) { site in
                        Text(site.exclusionNames)
                            .font(LungfishInspectorStyle.controlFont)
                            .lineLimit(1)
                            .help(site.exclusionNames)
                    }
                }
                .frame(minHeight: 120, idealHeight: max(120, min(320, CGFloat(model.sites.count + 1) * 24 + 8)), maxHeight: 320)
                .accessibilityIdentifier("msa-discriminating-sites-table")
            }

            Text("Candidate windows")
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
            if model.windows.isEmpty {
                Text("No window of the chosen length holds more than one site.")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Table(model.windows) {
                    TableColumn("Template span") { window in
                        Button(window.spanText) { model.jump(toColumn: window.startColumn) }
                            .buttonStyle(.link)
                            .font(LungfishInspectorStyle.controlFont)
                            .help("Show the first column of this window in the viewport")
                    }
                    .width(min: 90, ideal: 100)
                    TableColumn("Sites") { window in
                        Text("\(window.siteCount)").font(LungfishInspectorStyle.controlFont).monospacedDigit()
                    }
                    .width(min: 40, ideal: 48)
                    TableColumn("Positions") { window in
                        Text(window.templatePositions.map(String.init).joined(separator: ", "))
                            .font(LungfishInspectorStyle.controlFont)
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 72, idealHeight: max(72, min(200, CGFloat(model.windows.count + 1) * 24 + 8)), maxHeight: 200)
                .accessibilityIdentifier("msa-discriminating-sites-windows-table")
            }

            // A narrow Inspector puts the export buttons on their own line
            // rather than truncating every title.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    copyTSVButton
                    Spacer(minLength: 0)
                    exportButtons
                }
                VStack(alignment: .leading, spacing: 6) {
                    copyTSVButton
                    HStack(spacing: 8) { exportButtons }
                }
            }
            if let outputURL = model.lastOutputURL {
                Text("Written by lungfish-cli to \(outputURL.path)")
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var copyTSVButton: some View {
        Button("Copy TSV") { model.copyTSV() }
            .font(LungfishInspectorStyle.controlFont)
            .disabled(model.siteTSV == nil)
            .help("Copy the per-column table as tab-separated text, in the layout lungfish-cli msa discriminating-sites writes")
            .accessibilityIdentifier("msa-discriminating-sites-copy")
    }

    @ViewBuilder
    private var exportButtons: some View {
        Button("Export TSV…") { model.requestExport(.tsv) }
            .font(LungfishInspectorStyle.controlFont)
            .disabled(model.onExportRequested == nil)
            .help("Write the per-column and candidate-window tables with a provenance sidecar using lungfish-cli msa discriminating-sites")
            .accessibilityIdentifier("msa-discriminating-sites-export-tsv")
        Button("Export JSON…") { model.requestExport(.json) }
            .font(LungfishInspectorStyle.controlFont)
            .disabled(model.onExportRequested == nil)
            .help("Write the full JSON report with a provenance sidecar using lungfish-cli msa discriminating-sites")
            .accessibilityIdentifier("msa-discriminating-sites-export-json")
    }
}
