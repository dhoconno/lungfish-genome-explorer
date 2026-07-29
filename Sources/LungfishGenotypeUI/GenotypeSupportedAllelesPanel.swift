import AppKit
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
    static let columnsMinimumWidth: CGFloat = 520

    let rows: [GenotypeSupportedAllelePresentation]

    var previewRows: ArraySlice<GenotypeSupportedAllelePresentation> {
        rows.prefix(Self.previewLimit)
    }

    var omittedRowCount: Int {
        max(0, rows.count - Self.previewLimit)
    }

    func layoutMode(forWidth width: CGFloat) -> LayoutMode {
        width >= Self.columnsMinimumWidth ? .columns : .compact
    }
}

struct GenotypeSupportedAllelesPanel: View {
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
                .accessibilityHidden(true)
                .background(
                    GenotypeSupportedAllelesAccessibilityElement(
                        label: "Supported Alleles"
                    )
                )

            ViewThatFits(in: .horizontal) {
                columnPreview
                    .frame(minWidth: GenotypeSupportedAllelesSnapshot.columnsMinimumWidth)
                compactPreview
            }

            if let title = Self.showAllButtonTitle(for: snapshot) {
                GenotypeSupportedAllelesShowAllButton(
                    title: title,
                    font: typographyModel.resolvedNSFont(for: .body),
                    isPresented: $showsAll
                )
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
                        .accessibilityHidden(true)
                        .background(
                            GenotypeSupportedAllelesAccessibilityElement(
                                label: row.accessibilityLabel
                            )
                        )
                    Text(row.locus)
                        .font(contentCaptionFont)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(row.uniqueReads)
                        .font(contentMonospacedFont.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(row.alignments)
                        .font(contentMonospacedFont.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(row.support)
                        .font(contentMonospacedFont.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                }
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
        VStack(alignment: .leading, spacing: 8) {
            Text("All \(snapshot.rows.count.formatted(.number)) Supported Alleles")
                .font(contentEmphasizedFont)
                .accessibilityHidden(true)
                .background(
                    GenotypeSupportedAllelesAccessibilityElement(
                        label: "All \(snapshot.rows.count.formatted(.number)) Supported Alleles"
                    )
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)

            GenotypeSupportedAllelesVirtualizedList(
                rows: snapshot.rows,
                bodyFont: typographyModel.resolvedNSFont(for: .body),
                captionFont: typographyModel.resolvedNSFont(for: .caption)
            )
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
        .accessibilityHidden(true)
        .background(
            GenotypeSupportedAllelesAccessibilityElement(
                label: row.accessibilityLabel
            )
        )
    }

    private static func showAllButtonTitle(
        for snapshot: GenotypeSupportedAllelesSnapshot
    ) -> String? {
        guard snapshot.omittedRowCount > 0 else { return nil }
        return "Show All \(snapshot.rows.count.formatted(.number)) Alleles…"
    }
}

private struct GenotypeSupportedAllelesAccessibilityElement: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSView) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(label)
    }
}

private struct GenotypeSupportedAllelesShowAllButton: NSViewRepresentable {
    let title: String
    let font: NSFont
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.showAll)
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: NSButton, coordinator: Coordinator) {
        coordinator.isPresented = $isPresented
        button.title = title
        button.font = font
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(title)
    }

    @MainActor
    final class Coordinator: NSObject {
        var isPresented: Binding<Bool>

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        @objc func showAll() {
            isPresented.wrappedValue = true
        }
    }
}

private struct GenotypeSupportedAllelesVirtualizedList: NSViewRepresentable {
    let rows: [GenotypeSupportedAllelePresentation]
    let bodyFont: NSFont
    let captionFont: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(rows: rows, bodyFont: bodyFont, captionFont: captionFont)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let column = NSTableColumn(identifier: .supportedAllele)
        column.resizingMask = .autoresizingMask

        let table = NSTableView(frame: .zero)
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.rows = rows
        context.coordinator.bodyFont = bodyFont
        context.coordinator.captionFont = captionFont
        guard let table = scrollView.documentView as? NSTableView else { return }
        table.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [GenotypeSupportedAllelePresentation]
        var bodyFont: NSFont
        var captionFont: NSFont

        init(
            rows: [GenotypeSupportedAllelePresentation],
            bodyFont: NSFont,
            captionFont: NSFont
        ) {
            self.rows = rows
            self.bodyFont = bodyFont
            self.captionFont = captionFont
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            heightOfRow row: Int
        ) -> CGFloat {
            max(38, bodyFont.pointSize + captionFont.pointSize + 12)
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let cell =
                tableView.makeView(
                    withIdentifier: .supportedAlleleCell,
                    owner: nil
                ) as? GenotypeSupportedAllelesTableCell
                ?? GenotypeSupportedAllelesTableCell()
            cell.identifier = .supportedAlleleCell
            cell.configure(
                row: rows[row],
                bodyFont: bodyFont,
                captionFont: captionFont
            )
            return cell
        }
    }
}

private final class GenotypeSupportedAllelesTableCell: NSTableCellView {
    private let alleleLabel = NSTextField(labelWithString: "")
    private let metricsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alleleLabel.lineBreakMode = .byTruncatingMiddle
        metricsLabel.textColor = .secondaryLabelColor
        metricsLabel.lineBreakMode = .byTruncatingTail
        for label in [alleleLabel, metricsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            alleleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            alleleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            alleleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            metricsLabel.leadingAnchor.constraint(equalTo: alleleLabel.leadingAnchor),
            metricsLabel.trailingAnchor.constraint(equalTo: alleleLabel.trailingAnchor),
            metricsLabel.topAnchor.constraint(equalTo: alleleLabel.bottomAnchor, constant: 1),
            metricsLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        row: GenotypeSupportedAllelePresentation,
        bodyFont: NSFont,
        captionFont: NSFont
    ) {
        alleleLabel.stringValue = row.allele
        alleleLabel.font = bodyFont
        metricsLabel.stringValue =
            "\(row.locus) • \(row.uniqueReads) unique • "
            + "\(row.alignments) alignments • \(row.support)"
        metricsLabel.font = captionFont
        setAccessibilityIdentifier(row.id)
        setAccessibilityLabel(row.accessibilityLabel)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let supportedAllele = Self("GenotypeSupportedAlleleColumn")
    static let supportedAlleleCell = Self("GenotypeSupportedAlleleCell")
}
