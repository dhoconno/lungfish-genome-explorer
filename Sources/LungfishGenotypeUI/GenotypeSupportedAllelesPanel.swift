import SwiftUI
import LungfishKit

struct GenotypeSupportedAllelePresentation: Identifiable, Equatable {
    let id: String
    let allele: String
    let locus: String
    let uniqueReads: String
    let alignments: String
    let support: String

    var accessibilityLabel: String {
        "\(allele), locus \(locus), \(uniqueReads) unique reads, "
            + "\(alignments) alignments, \(support) support"
    }
}

struct GenotypeSupportedAllelesSnapshot: Equatable {
    enum LayoutMode: Equatable {
        case columns
        case compact
    }

    static let previewLimit = 12

    let rows: [GenotypeSupportedAllelePresentation]

    var previewRows: ArraySlice<GenotypeSupportedAllelePresentation> {
        rows.prefix(Self.previewLimit)
    }

    var omittedRowCount: Int {
        max(0, rows.count - Self.previewLimit)
    }

    func layoutMode(forWidth width: CGFloat) -> LayoutMode {
        width >= 520 ? .columns : .compact
    }
}

struct GenotypeSupportedAllelesPanel: View {
    enum FullListContainer: Equatable {
        case virtualizedList
    }

    struct TestingPresentationState: Equatable {
        let inlineRows: [GenotypeSupportedAllelePresentation]
        let inlineAccessibilityLabels: [String]
        let showAllButtonTitle: String?
        let popoverRows: [GenotypeSupportedAllelePresentation]
        let fullListContainer: FullListContainer
    }

    let snapshot: GenotypeSupportedAllelesSnapshot
    var typographyModel: ContentTypographyModel = .shared

    @State private var showsAll = false

    private var contentBodyFont: Font {
        typographyModel.font(for: .body)
    }

    private var contentEmphasizedFont: Font {
        typographyModel.font(for: .emphasizedBody)
    }

    private var contentCaptionFont: Font {
        typographyModel.font(for: .caption)
    }

    private var contentMonospacedFont: Font {
        typographyModel.font(for: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Supported Alleles")
                .font(contentEmphasizedFont)
                .accessibilityAddTraits(.isHeader)

            ViewThatFits(in: .horizontal) {
                columnPreview
                    .frame(minWidth: 520)
                compactPreview
            }

            if let title = Self.showAllButtonTitle(for: snapshot) {
                Button(title) {
                    showsAll = true
                }
                .popover(isPresented: $showsAll) {
                    fullList
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnPreview: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            GridRow {
                columnHeader("Allele")
                columnHeader("Locus")
                columnHeader("Unique Reads")
                columnHeader("Alignments")
                columnHeader("Support")
            }
            .accessibilityHidden(true)

            ForEach(Array(snapshot.previewRows)) { row in
                GridRow {
                    Text(row.allele)
                        .font(contentBodyFont)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                    Text(row.locus)
                        .font(contentCaptionFont)
                        .foregroundStyle(.secondary)
                    Text(row.uniqueReads)
                        .font(contentMonospacedFont.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(row.alignments)
                        .font(contentMonospacedFont.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text(row.support)
                        .font(contentMonospacedFont.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.accessibilityLabel)
            }
        }
    }

    private var compactPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.previewRows.enumerated()), id: \.element.id) { index, row in
                compactRow(row)
                    .padding(.vertical, 5)
                if index < snapshot.previewRows.count - 1 {
                    Divider()
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var fullList: some View {
        List(snapshot.rows) { row in
            compactRow(row)
                .padding(.vertical, 3)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(contentCaptionFont.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func compactRow(_ row: GenotypeSupportedAllelePresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.allele)
                .font(contentBodyFont)
                .lineLimit(2)
            Text(
                "\(row.locus) • \(row.uniqueReads) unique • "
                    + "\(row.alignments) alignments • \(row.support)"
            )
            .font(contentCaptionFont)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private static func showAllButtonTitle(
        for snapshot: GenotypeSupportedAllelesSnapshot
    ) -> String? {
        guard snapshot.omittedRowCount > 0 else { return nil }
        return "Show All \(snapshot.rows.count.formatted(.number)) Alleles…"
    }

    static func testingPresentationState(
        snapshot: GenotypeSupportedAllelesSnapshot,
        showsAll: Bool
    ) -> TestingPresentationState {
        let inlineRows = Array(snapshot.previewRows)
        let buttonTitle = showAllButtonTitle(for: snapshot)
        return TestingPresentationState(
            inlineRows: inlineRows,
            inlineAccessibilityLabels:
                ["Supported Alleles"]
                + inlineRows.map(\.accessibilityLabel)
                + [buttonTitle].compactMap { $0 },
            showAllButtonTitle: buttonTitle,
            popoverRows: showsAll ? snapshot.rows : [],
            fullListContainer: .virtualizedList
        )
    }

    var testingContentTypographyPointSizes: (body: CGFloat, caption: CGFloat) {
        (
            typographyModel.resolvedNSFont(for: .body).pointSize,
            typographyModel.resolvedNSFont(for: .caption).pointSize
        )
    }
}
