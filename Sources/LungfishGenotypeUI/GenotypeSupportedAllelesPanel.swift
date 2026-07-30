import AppKit
import SwiftUI
import LungfishKit

struct GenotypeSupportedAllelePresentation: Identifiable, Equatable {
    let id: String
    let allele: String
    let readSupport: String
    var qualifiers: [String] = []
    var readSupportIsSecondary = false
    var readSupportIsItalic = false
    var semanticAccessibilityDetails: String?

    var accessibilityLabel: String {
        let summary = "\(allele), read support \(readSupport)."
        guard let semanticAccessibilityDetails,
              !semanticAccessibilityDetails.isEmpty else {
            return summary
        }
        return "\(summary) \(semanticAccessibilityDetails)"
    }
}

struct GenotypeSupportedAllelesSnapshot: Equatable {
    enum LayoutMode: Equatable {
        case columns
        case compact
    }

    static let columnsMinimumWidth: CGFloat = 520
    private static let columnsWidthGrowthPerTextScale: CGFloat = 140
    static let columnTitles = ["Allele", "Read support"]

    let rows: [GenotypeSupportedAllelePresentation]

    func layoutMode(forWidth width: CGFloat) -> LayoutMode {
        width >= Self.columnsMinimumWidth ? .columns : .compact
    }

    func layoutMode(
        forWidth width: CGFloat,
        bodyFont: NSFont,
        captionFont: NSFont
    ) -> LayoutMode {
        let standardLineHeight = max(
            NSFont.systemFont(
                ofSize: NSFont.systemFontSize
            ).boundingRectForFont.height,
            1
        )
        let resolvedLineHeight = max(
            bodyFont.boundingRectForFont.height,
            captionFont.boundingRectForFont.height
        )
        let textScale = max(1, resolvedLineHeight / standardLineHeight)
        let responsiveMinimumWidth =
            Self.columnsMinimumWidth
                + (
                    (textScale - 1)
                        * Self.columnsWidthGrowthPerTextScale
                )
        return width >= responsiveMinimumWidth ? .columns : .compact
    }
}

enum GenotypeSupportedAllelesListHeightPolicy {
    static func height(
        availableHeight: CGFloat?,
        compact: Bool
    ) -> CGFloat {
        guard let availableHeight,
              availableHeight.isFinite,
              availableHeight > 0 else {
            return 360
        }
        let preferred = min(max(availableHeight, 280), 480)
        guard compact else { return preferred }
        return max(160, min(availableHeight, preferred))
    }
}

enum GenotypeSampleCurationCardStyle {
    static let cornerRadius: CGFloat = 8
    static let internalPadding: CGFloat = 10
    static let verticalOuterInset: CGFloat = 4
    static let strokeLineWidth: CGFloat = 1
    static let fillColor = NSColor.controlBackgroundColor
    static let strokeColor = NSColor.separatorColor
}

private struct GenotypeSampleCurationCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(GenotypeSampleCurationCardStyle.internalPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: GenotypeSampleCurationCardStyle.cornerRadius
                )
                .fill(
                    Color(
                        nsColor: GenotypeSampleCurationCardStyle.fillColor
                    )
                )
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: GenotypeSampleCurationCardStyle.cornerRadius
                )
                .stroke(
                    Color(
                        nsColor: GenotypeSampleCurationCardStyle.strokeColor
                    ),
                    lineWidth: GenotypeSampleCurationCardStyle.strokeLineWidth
                )
            )
            .padding(
                .vertical,
                GenotypeSampleCurationCardStyle.verticalOuterInset
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func genotypeSampleCurationCardChrome() -> some View {
        modifier(GenotypeSampleCurationCardModifier())
    }
}

struct GenotypeSupportedAllelesPanel: View {
    let snapshot: GenotypeSupportedAllelesSnapshot
    var typographyModel: ContentTypographyModel = .shared
    var availableHeight: CGFloat?
    var usesCompactHeight = false

    private var contentEmphasizedFont: Font {
        typographyModel.font(for: .emphasizedBody)
    }

    init(
        snapshot: GenotypeSupportedAllelesSnapshot,
        typographyModel: ContentTypographyModel = .shared,
        availableHeight: CGFloat? = nil,
        usesCompactHeight: Bool = false
    ) {
        self.snapshot = snapshot
        self.typographyModel = typographyModel
        self.availableHeight = availableHeight
        self.usesCompactHeight = usesCompactHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Supported Alleles")
                .font(contentEmphasizedFont)
                .accessibilityHidden(true)
                .background(
                    GenotypeSupportedAllelesAccessibilityElement(
                        label: "Supported Alleles",
                        semanticRole: .heading(level: 2)
                    )
                )

            GenotypeSupportedAllelesVirtualizedList(
                rows: snapshot.rows,
                bodyFont: typographyModel.resolvedNSFont(for: .body),
                captionFont: typographyModel.resolvedNSFont(for: .caption)
            )
            .frame(
                height: GenotypeSupportedAllelesListHeightPolicy.height(
                    availableHeight: availableHeight,
                    compact: usesCompactHeight
                )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .genotypeSampleCurationCardChrome()
    }
}

private struct GenotypeSupportedAllelesAccessibilityElement: NSViewRepresentable {
    enum SemanticRole {
        case staticText
        case heading(level: Int)
    }

    let label: String
    var semanticRole: SemanticRole = .staticText

    func makeNSView(context: Context) -> GenotypeSupportedAllelesAccessibilityView {
        let view = GenotypeSupportedAllelesAccessibilityView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(
        _ view: GenotypeSupportedAllelesAccessibilityView,
        context: Context
    ) {
        configure(view)
    }

    private func configure(_ view: GenotypeSupportedAllelesAccessibilityView) {
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(label)
        switch semanticRole {
        case .staticText:
            view.setAccessibilityRole(.staticText)
            view.headingLevel = nil
        case .heading(let level):
            view.setAccessibilityRole(.supportedAllelesHeading)
            view.headingLevel = level
        }
    }
}

private final class GenotypeSupportedAllelesAccessibilityView: NSView {
    nonisolated(unsafe) var headingLevel: Int?

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        var names = super.accessibilityAttributeNames()
        if headingLevel != nil, !names.contains(.supportedAllelesHeadingLevel) {
            names.append(.supportedAllelesHeadingLevel)
        }
        return names
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(
        _ attribute: NSAccessibility.Attribute
    ) -> Any? {
        if attribute == .supportedAllelesHeadingLevel {
            return headingLevel.map(NSNumber.init(value:))
        }
        return super.accessibilityAttributeValue(attribute)
    }
}

private extension NSAccessibility.Role {
    static let supportedAllelesHeading = Self(rawValue: "AXHeading")
}

private extension NSAccessibility.Attribute {
    static let supportedAllelesHeadingLevel = Self(rawValue: "AXHeadingLevel")
}

struct GenotypeSupportedAllelesVirtualizedList: NSViewRepresentable {
    let rows: [GenotypeSupportedAllelePresentation]
    let bodyFont: NSFont
    let captionFont: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rows: rows,
            bodyFont: bodyFont,
            captionFont: captionFont
        )
    }

    func makeNSView(context: Context) -> GenotypeSupportedAllelesListHostView {
        GenotypeSupportedAllelesListHostView(
            coordinator: context.coordinator
        )
    }

    func updateNSView(
        _ host: GenotypeSupportedAllelesListHostView,
        context: Context
    ) {
        host.update(
            rows: rows,
            bodyFont: bodyFont,
            captionFont: captionFont
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [GenotypeSupportedAllelePresentation]
        var bodyFont: NSFont
        var captionFont: NSFont
        var layoutMode: GenotypeSupportedAllelesSnapshot.LayoutMode = .columns

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
            guard rows.indices.contains(row) else { return 38 }
            let bodyLineHeight = ceil(bodyFont.boundingRectForFont.height)
            let captionLineHeight = ceil(
                captionFont.boundingRectForFont.height
            )
            switch layoutMode {
            case .columns:
                guard !rows[row].qualifiers.isEmpty else {
                    return max(38, bodyLineHeight + 8)
                }
                return ceil(
                    bodyLineHeight
                        + captionLineHeight
                        + 1
                        + 8
                )
            case .compact:
                let qualifierHeight = rows[row].qualifiers.isEmpty
                    ? 0
                    : captionLineHeight + 1
                return ceil(
                    bodyLineHeight
                        + captionLineHeight
                        + qualifierHeight
                        + 2
                        + 8
                )
            }
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
                captionFont: captionFont,
                layoutMode: layoutMode
            )
            return cell
        }
    }
}

@MainActor
final class GenotypeSupportedAllelesListHostView: NSView {
    private let alleleHeader = NSTextField(labelWithString: "Allele")
    private let readSupportHeader = NSTextField(
        labelWithString: "Read support"
    )
    let scrollView = NSScrollView(frame: .zero)
    let tableView = NSTableView(frame: .zero)
    private(set) var reloadCount = 0

    private let coordinator:
        GenotypeSupportedAllelesVirtualizedList.Coordinator
    private var currentRows: [GenotypeSupportedAllelePresentation]
    private var currentBodyFontSignature: FontSignature
    private var currentCaptionFontSignature: FontSignature
    private var currentLayoutMode:
        GenotypeSupportedAllelesSnapshot.LayoutMode = .columns

    init(
        coordinator: GenotypeSupportedAllelesVirtualizedList.Coordinator
    ) {
        self.coordinator = coordinator
        currentRows = coordinator.rows
        currentBodyFontSignature = FontSignature(coordinator.bodyFont)
        currentCaptionFontSignature = FontSignature(
            coordinator.captionFont
        )
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if reconcileLayoutMode(forWidth: newSize.width) {
            reloadTable()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let headerHeight = max(
            24,
            ceil(coordinator.captionFont.boundingRectForFont.height) + 8
        )
        let supportWidth = min(160, max(100, bounds.width * 0.28))
        let compact = currentLayoutMode == .compact
        readSupportHeader.isHidden = compact
        alleleHeader.frame = NSRect(
            x: 8,
            y: 0,
            width: max(
                0,
                bounds.width - (compact ? 16 : supportWidth + 20)
            ),
            height: headerHeight
        )
        readSupportHeader.frame = NSRect(
            x: max(8, bounds.width - supportWidth - 8),
            y: 0,
            width: supportWidth,
            height: headerHeight
        )
        scrollView.frame = NSRect(
            x: 0,
            y: headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - headerHeight)
        )
    }

    func update(
        rows: [GenotypeSupportedAllelePresentation],
        bodyFont: NSFont,
        captionFont: NSFont
    ) {
        let bodySignature = FontSignature(bodyFont)
        let captionSignature = FontSignature(captionFont)
        let rowsChanged = currentRows != rows
        let fontsChanged =
            currentBodyFontSignature != bodySignature
            || currentCaptionFontSignature != captionSignature
        guard rowsChanged || fontsChanged else { return }

        currentRows = rows
        currentBodyFontSignature = bodySignature
        currentCaptionFontSignature = captionSignature
        coordinator.rows = rows
        coordinator.bodyFont = bodyFont
        coordinator.captionFont = captionFont
        configureHeaderFonts()
        _ = reconcileLayoutMode(forWidth: bounds.width)
        reloadTable()
        needsLayout = true
    }

    private func configure() {
        let column = NSTableColumn(identifier: .supportedAllele)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle =
            .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.layoutMode = currentLayoutMode

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        readSupportHeader.alignment = .right
        for (field, identifier) in [
            (alleleHeader, "supported-alleles-header-allele"),
            (
                readSupportHeader,
                "supported-alleles-header-read-support"
            ),
        ] {
            field.textColor = .secondaryLabelColor
            field.setAccessibilityElement(true)
            field.setAccessibilityRole(.staticText)
            field.setAccessibilityLabel(field.stringValue)
            field.setAccessibilityIdentifier(identifier)
            addSubview(field)
        }
        addSubview(scrollView)
        configureHeaderFonts()
    }

    private func configureHeaderFonts() {
        let font = NSFontManager.shared.convert(
            coordinator.captionFont,
            toHaveTrait: .boldFontMask
        )
        alleleHeader.font = font
        readSupportHeader.font = font
    }

    @discardableResult
    private func reconcileLayoutMode(forWidth width: CGFloat) -> Bool {
        let layoutMode =
            GenotypeSupportedAllelesSnapshot(rows: [])
                .layoutMode(
                    forWidth: width,
                    bodyFont: coordinator.bodyFont,
                    captionFont: coordinator.captionFont
                )
        guard layoutMode != currentLayoutMode else { return false }
        currentLayoutMode = layoutMode
        coordinator.layoutMode = layoutMode
        return true
    }

    private func reloadTable() {
        reloadCount += 1
        tableView.reloadData()
    }

    private struct FontSignature: Equatable {
        let name: String
        let pointSize: CGFloat
        let traits: NSFontDescriptor.SymbolicTraits

        init(_ font: NSFont) {
            name = font.fontName
            pointSize = font.pointSize
            traits = font.fontDescriptor.symbolicTraits
        }
    }
}

private final class GenotypeSupportedAllelesTableCell: NSTableCellView {
    private let alleleLabel = NSTextField(labelWithString: "")
    private let qualifierLabel = NSTextField(labelWithString: "")
    private let readSupportLabel = NSTextField(labelWithString: "")
    private var layoutMode:
        GenotypeSupportedAllelesSnapshot.LayoutMode = .columns

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alleleLabel.lineBreakMode = .byTruncatingMiddle
        readSupportLabel.textColor = .secondaryLabelColor
        readSupportLabel.alignment = .right
        readSupportLabel.lineBreakMode = .byTruncatingHead
        qualifierLabel.textColor = .secondaryLabelColor
        qualifierLabel.lineBreakMode = .byTruncatingTail
        for label in [alleleLabel, qualifierLabel, readSupportLabel] {
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        row: GenotypeSupportedAllelePresentation,
        bodyFont: NSFont,
        captionFont: NSFont,
        layoutMode: GenotypeSupportedAllelesSnapshot.LayoutMode
    ) {
        self.layoutMode = layoutMode
        alleleLabel.stringValue = row.allele
        alleleLabel.font = bodyFont
        let hasQualifiers = !row.qualifiers.isEmpty
        qualifierLabel.isHidden = !hasQualifiers
        qualifierLabel.stringValue =
            row.qualifiers.joined(separator: " \u{00b7} ")
        qualifierLabel.font = captionFont
        readSupportLabel.stringValue = layoutMode == .compact
            ? "Read support: \(row.readSupport)"
            : row.readSupport
        readSupportLabel.alignment =
            layoutMode == .compact ? .left : .right
        readSupportLabel.font = row.readSupportIsItalic
            ? NSFontManager.shared.convert(
                captionFont,
                toHaveTrait: .italicFontMask
            )
            : captionFont
        readSupportLabel.textColor = row.readSupportIsSecondary
            ? .secondaryLabelColor
            : .labelColor
        setAccessibilityIdentifier(row.id)
        setAccessibilityLabel(row.accessibilityLabel)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 8
        let bodyHeight = ceil(
            alleleLabel.font?.boundingRectForFont.height ?? 17
        )
        let captionHeight = ceil(
            qualifierLabel.font?.boundingRectForFont.height ?? 14
        )
        switch layoutMode {
        case .columns:
            let supportWidth = min(160, max(90, bounds.width * 0.28))
            let alleleWidth = max(
                0,
                bounds.width - supportWidth - padding * 2 - 12
            )
            if qualifierLabel.isHidden {
                alleleLabel.frame = NSRect(
                    x: padding,
                    y: (bounds.height - bodyHeight) / 2,
                    width: alleleWidth,
                    height: bodyHeight
                )
            } else {
                alleleLabel.frame = NSRect(
                    x: padding,
                    y: bounds.height - padding / 2 - bodyHeight,
                    width: alleleWidth,
                    height: bodyHeight
                )
                qualifierLabel.frame = NSRect(
                    x: padding,
                    y: padding / 2,
                    width: alleleWidth,
                    height: captionHeight
                )
            }
            readSupportLabel.frame = NSRect(
                x: max(padding, bounds.width - supportWidth - padding),
                y: (bounds.height - captionHeight) / 2,
                width: supportWidth,
                height: captionHeight
            )
        case .compact:
            var y = bounds.height - padding / 2 - bodyHeight
            alleleLabel.frame = NSRect(
                x: padding,
                y: y,
                width: max(0, bounds.width - padding * 2),
                height: bodyHeight
            )
            if !qualifierLabel.isHidden {
                y -= captionHeight + 1
                qualifierLabel.frame = NSRect(
                    x: padding,
                    y: y,
                    width: max(0, bounds.width - padding * 2),
                    height: captionHeight
                )
            }
            y -= captionHeight + 1
            readSupportLabel.frame = NSRect(
                x: padding,
                y: max(padding / 2, y),
                width: max(0, bounds.width - padding * 2),
                height: captionHeight
            )
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let supportedAllele = Self("GenotypeSupportedAlleleColumn")
    static let supportedAlleleCell = Self("GenotypeSupportedAlleleCell")
}
