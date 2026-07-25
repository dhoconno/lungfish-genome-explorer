import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

@MainActor
final class GenotypeHaplotypeDefinitionMatrixView: NSView {
    struct DiagnosticAllele: Equatable {
        let name: String
        let reads: Int

        var isObserved: Bool {
            reads > 0
        }
    }

    struct Row: Equatable {
        enum Status: String, Equatable {
            case called
            case candidate
            case absent

            var displayName: String {
            switch self {
            case .called: return "Called"
            case .candidate: return "Observed support"
            case .absent: return "Not observed"
            }
        }
        }

        let sample: String
        let locus: String
        let callName: String
        let haplotypeName: String
        let haplotypeColor: AnnotationColor?
        let observedCount: Int
        let diagnosticCount: Int
        let minimumMatches: Int
        let status: Status
        let alleles: [DiagnosticAllele]

        init(
            sample: String,
            locus: String,
            callName: String,
            haplotypeName: String,
            haplotypeColor: AnnotationColor? = nil,
            observedCount: Int,
            diagnosticCount: Int,
            minimumMatches: Int,
            status: Status,
            alleles: [DiagnosticAllele]
        ) {
            self.sample = sample
            self.locus = locus
            self.callName = callName
            self.haplotypeName = haplotypeName
            self.haplotypeColor = haplotypeColor
            self.observedCount = observedCount
            self.diagnosticCount = diagnosticCount
            self.minimumMatches = minimumMatches
            self.status = status
            self.alleles = alleles
        }

        var ruleText: String {
            "\(observedCount)/\(minimumMatches)/\(diagnosticCount)"
        }

        func allele(named name: String) -> DiagnosticAllele? {
            alleles.first { $0.name == name }
        }
    }

    private enum Column {
        static let sample = NSUserInterfaceItemIdentifier("sample")
        static let locus = NSUserInterfaceItemIdentifier("locus")
        static let call = NSUserInterfaceItemIdentifier("call")
        static let haplotype = NSUserInterfaceItemIdentifier("haplotype")
        static let rule = NSUserInterfaceItemIdentifier("rule")
        static let status = NSUserInterfaceItemIdentifier("status")
        static let allelePrefix = "allele:"

        static func allele(_ name: String) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("\(allelePrefix)\(name)")
        }

        static func alleleName(from identifier: NSUserInterfaceItemIdentifier) -> String? {
            let raw = identifier.rawValue
            guard raw.hasPrefix(allelePrefix) else { return nil }
            return String(raw.dropFirst(allelePrefix.count))
        }
    }

    private let headerStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "Diagnostic allele matrix")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No haplotype definition matrix is available for the active filters.")

    private var allRows: [Row] = []
    private var rows: [Row] = []
    private var alleleColumns: [String] = []
    private var definitionName: String?
    private var contentTypographyObservation: ContentTypographyViewObservation?
    private var contentPreferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var typographyBaselineWidths: [String: CGFloat] = [:]
    private var typographyBaselineMinWidths: [String: CGFloat] = [:]
    private var lastAppliedTypographyScale: CGFloat = 1
#if DEBUG
    private var configurationCount = 0
#endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildSubviews()
    }

    func configure(rows: [Row], definitionName: String?) {
#if DEBUG
        configurationCount += 1
#endif
        allRows = rows
        self.definitionName = definitionName
        let newAlleleColumns = orderedAlleleColumns(from: rows)
        let columnsChanged = newAlleleColumns != alleleColumns
        alleleColumns = newAlleleColumns
        updateHeader()
        if columnsChanged || tableView.tableColumns.isEmpty {
            rebuildColumns()
        }
        applySortDescriptors()
        tableView.reloadData()
        emptyLabel.isHidden = !rows.isEmpty
        applyContentTypography()
    }

    func exportSnapshot(
        bundleURL: URL,
        analysisName: String,
        lens: String
    ) -> GenotypeViewportExportSnapshot {
        let exportRows = rows.map { row -> GenotypeViewportExportRow in
            let reads = Dictionary(uniqueKeysWithValues: alleleColumns.map { alleleName in
                (alleleName, row.allele(named: alleleName)?.reads ?? 0)
            })
            return GenotypeViewportExportRow(
                genotype: row.haplotypeName,
                locus: "\(row.sample) \(row.locus)",
                sampleCount: row.observedCount,
                totalUniqueReads: row.alleles.reduce(0) { $0 + max(0, $1.reads) },
                sampleReads: reads,
                rowStyle: GenotypeResultHighlightStyle(),
                cellStyles: [:]
            )
        }
        var filters: [String: String] = [
            "view": "Haplotype diagnostic allele matrix",
            "definition": definitionName ?? "",
            "rowCount": "\(rows.count)",
        ]
        filters["statusLegend"] = "Called, observed support, not observed"
        return GenotypeViewportExportSnapshot(
            bundleURL: bundleURL,
            analysisName: analysisName,
            lens: lens,
            filters: filters,
            sampleNames: alleleColumns,
            rows: exportRows
        )
    }

    private func buildSubviews() {
        translatesAutoresizingMaskIntoConstraints = false

        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 3
        headerStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 8, right: 12)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(subtitleLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.headerView = NSTableHeaderView()
        tableView.backgroundColor = .textBackgroundColor

        scrollView.documentView = tableView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 11, weight: .regular)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        addSubview(headerStack)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),
        ])

        setAccessibilityIdentifier("genotype-haplotype-definition-matrix")
        setAccessibilityLabel("Haplotype diagnostic allele matrix")
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(excludedSubtree: { _ in true }),
            rootProvider: { [weak self] in self },
            afterApply: { [weak self] in self?.applyContentTypography() }
        )
    }

    private func updateHeader() {
        let base = "Rows are haplotype definitions. Diagnostic genotype columns show read support or genotypes not observed in this run."
        if let definitionName, !definitionName.isEmpty {
            subtitleLabel.stringValue = "Definition: \(definitionName). \(base) Rule is observed / required / total."
        } else {
            subtitleLabel.stringValue = "\(base) Rule is observed / required / total."
        }
    }

    private func rebuildColumns() {
        captureTypographyBaselines()
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        addColumn(Column.sample, title: "Sample", width: 78)
        addColumn(Column.locus, title: "Locus", width: 72)
        addColumn(Column.call, title: "Call", width: 108)
        addColumn(Column.haplotype, title: "Haplotype", width: 86)
        addColumn(Column.rule, title: "Obs/Req/Total", width: 92)
        addColumn(Column.status, title: "Status", width: 78)
        for allele in alleleColumns {
            addColumn(Column.allele(allele), title: allele, width: 126, minWidth: 88)
        }
        registerTypographyBaselines()
    }

    private func addColumn(
        _ identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat? = nil
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minWidth ?? width
        column.resizingMask = .userResizingMask
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier.rawValue, ascending: true)
        tableView.addTableColumn(column)
    }

    private func orderedAlleleColumns(from rows: [Row]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows {
            for allele in row.alleles where seen.insert(allele.name).inserted {
                ordered.append(allele.name)
            }
        }
        return ordered
    }

    private func value(row: Row, column: NSUserInterfaceItemIdentifier) -> String {
        switch column {
        case Column.sample:
            return row.sample
        case Column.locus:
            return row.locus
        case Column.call:
            return row.callName
        case Column.haplotype:
            return row.haplotypeName
        case Column.rule:
            return row.ruleText
        case Column.status:
            return row.status.displayName
        default:
            guard let alleleName = Column.alleleName(from: column),
                  let allele = row.allele(named: alleleName) else {
                return ""
            }
            return allele.isObserved ? "\(allele.reads)" : "[not observed]"
        }
    }

    private func textColor(row: Row, column: NSUserInterfaceItemIdentifier) -> NSColor {
        if Column.alleleName(from: column) != nil {
            guard let allele = row.allele(named: Column.alleleName(from: column) ?? "") else {
                return .tertiaryLabelColor
            }
            return allele.isObserved ? .labelColor : .secondaryLabelColor
        }
        if column == Column.status {
            return statusColor(row.status)
        }
        if column == Column.haplotype {
            return color(from: row.haplotypeColor ?? HaplotypeColorToken.assigned(forName: row.haplotypeName).fillColor)
        }
        return .labelColor
    }

    private func font(row: Row, column: NSUserInterfaceItemIdentifier) -> NSFont {
        let size = resolvedContentTypography().font(for: .monospaced).pointSize
        if column == Column.haplotype || row.status == .called && column == Column.status {
            return .monospacedSystemFont(ofSize: size, weight: .semibold)
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func resolvedContentTypography() -> ContentTypography {
        ContentTypography(
            preference: AppSettings.shared.contentTextSizePreference,
            preferredFontProvider: contentPreferredFontProvider
        )
    }

    private var contentTypographyScale: CGFloat {
        resolvedContentTypography().font(for: .body).pointSize / max(
            contentPreferredFontProvider.canonicalUnscaledPointSize(for: .body),
            1
        )
    }

    private func applyContentTypography() {
        captureTypographyBaselines()
        let typography = resolvedContentTypography()
        titleLabel.font = typography.font(for: .emphasizedBody)
        subtitleLabel.font = typography.font(for: .caption)
        emptyLabel.font = typography.font(for: .body)
        tableView.rowHeight = typography.tableRowHeight(minimum: 24, verticalPadding: 7)
        tableView.headerView?.frame.size.height =
            typography.tableHeaderHeight(minimum: 24, verticalPadding: 8)
        registerTypographyBaselines()
        let scale = contentTypographyScale
        for column in tableView.tableColumns {
            let key = column.identifier.rawValue
            let baselineWidth = typographyBaselineWidths[key] ?? column.width
            let baselineMinimum = typographyBaselineMinWidths[key] ?? column.minWidth
            let headerFont = typography.font(for: .tableHeader)
            let headerWidth = ceil(
                (column.title as NSString).size(withAttributes: [.font: headerFont]).width + 20
            )
            column.headerCell.font = headerFont
            column.minWidth = max(baselineMinimum * scale, headerWidth)
            column.width = max(baselineWidth * scale, column.minWidth)
        }
        lastAppliedTypographyScale = scale
        tableView.reloadData()
        needsLayout = true
    }

    private func registerTypographyBaselines() {
        for column in tableView.tableColumns {
            let key = column.identifier.rawValue
            if typographyBaselineWidths[key] == nil {
                typographyBaselineWidths[key] = column.width
            }
            if typographyBaselineMinWidths[key] == nil {
                typographyBaselineMinWidths[key] = column.minWidth
            }
        }
    }

    private func captureTypographyBaselines() {
        let scale = max(lastAppliedTypographyScale, 0.01)
        for column in tableView.tableColumns {
            typographyBaselineWidths[column.identifier.rawValue] = column.width / scale
            typographyBaselineMinWidths[column.identifier.rawValue] = column.minWidth / scale
        }
    }

    private func statusColor(_ status: Row.Status) -> NSColor {
        switch status {
        case .called:
            return .controlAccentColor
        case .candidate:
            return .labelColor
        case .absent:
            return .secondaryLabelColor
        }
    }

    private func color(from annotationColor: AnnotationColor) -> NSColor {
        NSColor(
            calibratedRed: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            alpha: annotationColor.alpha
        )
    }

    private func applySortDescriptors() {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else {
            rows = allRows
            return
        }
        rows = allRows.sorted {
            compare($0, $1, key: key, ascending: descriptor.ascending)
        }
    }

    private func compare(_ lhs: Row, _ rhs: Row, key: String, ascending: Bool) -> Bool {
        let ordered: ComparisonResult
        switch key {
        case Column.sample.rawValue:
            ordered = lhs.sample.localizedStandardCompare(rhs.sample)
        case Column.locus.rawValue:
            ordered = lhs.locus.localizedStandardCompare(rhs.locus)
        case Column.call.rawValue:
            ordered = lhs.callName.localizedStandardCompare(rhs.callName)
        case Column.haplotype.rawValue:
            ordered = lhs.haplotypeName.localizedStandardCompare(rhs.haplotypeName)
        case Column.rule.rawValue:
            if lhs.observedCount != rhs.observedCount {
                ordered = lhs.observedCount < rhs.observedCount ? .orderedAscending : .orderedDescending
            } else if lhs.minimumMatches != rhs.minimumMatches {
                ordered = lhs.minimumMatches < rhs.minimumMatches ? .orderedAscending : .orderedDescending
            } else {
                ordered = lhs.diagnosticCount < rhs.diagnosticCount ? .orderedAscending : .orderedDescending
            }
        case Column.status.rawValue:
            if lhs.status != rhs.status {
                ordered = statusSortRank(lhs.status) < statusSortRank(rhs.status) ? .orderedAscending : .orderedDescending
            } else {
                ordered = lhs.haplotypeName.localizedStandardCompare(rhs.haplotypeName)
            }
        default:
            if let allele = Column.alleleName(from: NSUserInterfaceItemIdentifier(key)) {
                let lhsReads = lhs.allele(named: allele)?.reads ?? 0
                let rhsReads = rhs.allele(named: allele)?.reads ?? 0
                if lhsReads == rhsReads {
                    ordered = lhs.haplotypeName.localizedStandardCompare(rhs.haplotypeName)
                } else {
                    ordered = lhsReads < rhsReads ? .orderedAscending : .orderedDescending
                }
            } else {
                ordered = lhs.haplotypeName.localizedStandardCompare(rhs.haplotypeName)
            }
        }
        return ascending ? ordered == .orderedAscending : ordered == .orderedDescending
    }

    private func statusSortRank(_ status: Row.Status) -> Int {
        switch status {
        case .called: return 0
        case .candidate: return 1
        case .absent: return 2
        }
    }
}

extension GenotypeHaplotypeDefinitionMatrixView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
        guard rowIndex >= 0, rowIndex < rows.count, let tableColumn else { return nil }
        let row = rows[rowIndex]
        let identifier = tableColumn.identifier
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        field.stringValue = value(row: row, column: identifier)
        field.font = font(row: row, column: identifier)
        field.textColor = textColor(row: row, column: identifier)
        field.alignment = Column.alleleName(from: identifier) == nil ? .left : .center
        field.toolTip = tooltip(row: row, column: identifier)
        return field
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applySortDescriptors()
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = MatrixRowView()
        if row >= 0, row < rows.count {
            view.status = rows[row].status
        }
        return view
    }

    private func tooltip(row: Row, column: NSUserInterfaceItemIdentifier) -> String? {
        if let alleleName = Column.alleleName(from: column) {
            guard let allele = row.allele(named: alleleName) else {
                return "Not diagnostic for \(row.haplotypeName)"
            }
            if allele.isObserved {
                return "\(alleleName): \(allele.reads) unique reads supporting \(row.haplotypeName)"
            }
            return "\(alleleName): not observed for \(row.haplotypeName)"
        }
        if column == Column.rule {
            return "\(row.observedCount) observed, \(row.minimumMatches) required, \(row.diagnosticCount) total diagnostic genotypes"
        }
        return nil
    }
}

private final class MatrixRowView: NSTableRowView {
    var status: GenotypeHaplotypeDefinitionMatrixView.Row.Status = .absent

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            super.drawBackground(in: dirtyRect)
            return
        }
        switch status {
        case .called:
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            dirtyRect.fill()
        case .candidate:
            NSColor.textBackgroundColor.setFill()
            dirtyRect.fill()
        case .absent:
            NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill()
            dirtyRect.fill()
        }
    }
}

#if DEBUG
extension GenotypeHaplotypeDefinitionMatrixView {
    var testingCellFontPointSize: CGFloat {
        guard let row = rows.first ?? allRows.first else { return 0 }
        return font(row: row, column: Column.sample).pointSize
    }

    var testingRowHeight: CGFloat {
        tableView.rowHeight
    }

    var testingColumnWidths: [CGFloat] {
        tableView.tableColumns.map(\.width)
    }

    var testingConfigurationCount: Int {
        configurationCount
    }

    var testingText: String {
        var values = [
            "Diagnostic allele matrix",
            subtitleLabel.stringValue,
            "Sample",
            "Locus",
            "Call",
            "Haplotype",
            "Obs/Req/Total",
            "Status",
        ]
        values.append(contentsOf: alleleColumns)
        for row in rows {
            values.append(row.sample)
            values.append(row.locus)
            values.append(row.callName)
            values.append(row.haplotypeName)
            values.append(row.ruleText)
            values.append(row.status.displayName)
            for allele in alleleColumns {
                if let diagnostic = row.allele(named: allele) {
                    let suffix = diagnostic.isObserved ? "\(diagnostic.reads)" : "[not observed]"
                    values.append("\(allele) \(suffix)")
                }
            }
        }
        if rows.isEmpty {
            values.append(emptyLabel.stringValue)
        }
        return values.joined(separator: "\n")
    }
}
#endif
