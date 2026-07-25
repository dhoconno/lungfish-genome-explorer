// AssemblySummaryStrip.swift - Quick-copy assembly summary metrics
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow
import LungfishKit

@MainActor
final class AssemblyContentTypographyObservation {
    private var token: NSObjectProtocol?

    init(handler: @escaping @MainActor () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
    }

    func cancel() {
        guard let token else { return }
        self.token = nil
        NotificationCenter.default.removeObserver(token)
    }

    isolated deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

@MainActor
final class AssemblyQuickCopyTextField: NSTextField {
    var pasteboard: PasteboardWriting = DefaultPasteboard()
    var copiedValue: (() -> String)?
    var explicitAccessibilityValue: String?

    convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        self.stringValue = string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isEditable = false
        drawsBackground = false
        lineBreakMode = .byTruncatingMiddle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let value = copiedValue?(), !value.isEmpty else {
            super.mouseDown(with: event)
            return
        }
        pasteboard.setString(value)
    }

    func copyCurrentValue() {
        guard let value = copiedValue?(), !value.isEmpty else { return }
        pasteboard.setString(value)
    }

    override func accessibilityValue() -> String? {
        explicitAccessibilityValue ?? super.accessibilityValue()
    }
}

@MainActor
final class AssemblySummaryStrip: NSView {
    private let stackView = NSStackView()
    private var valueFields: [String: AssemblyQuickCopyTextField] = [:]
    private var titleFields: [NSTextField] = []
    private var fieldColumns: [NSStackView] = []
    private var heightConstraint: NSLayoutConstraint?
    private var contentTypographyObservation: AssemblyContentTypographyObservation?
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var currentRowGroups: [[Int]] = []
    private var lastLayoutSignature: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-summary-strip")

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        let heightConstraint = heightAnchor.constraint(equalToConstant: 44)
        self.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        contentTypographyObservation = AssemblyContentTypographyObservation { [weak self] in
            self?.applyContentTypography()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        contentTypographyObservation?.cancel()
    }

    override func layout() {
        updateMeasuredLayout()
        super.layout()
    }

    func configure(result: AssemblyResult, pasteboard: PasteboardWriting) {
        let fieldDefinitions = summaryFields(for: result)
        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        valueFields.removeAll()
        titleFields.removeAll()
        fieldColumns.removeAll()

        for (identifier, title, value) in fieldDefinitions {
            let titleField = NSTextField(labelWithString: title)
            titleField.textColor = .secondaryLabelColor
            titleField.lineBreakMode = .byWordWrapping
            titleField.maximumNumberOfLines = 2
            titleField.toolTip = title

            let valueField = AssemblyQuickCopyTextField(labelWithString: value)
            valueField.lineBreakMode = .byWordWrapping
            valueField.maximumNumberOfLines = 2
            valueField.toolTip = value
            valueField.pasteboard = pasteboard
            valueField.copiedValue = { [weak valueField] in valueField?.stringValue ?? "" }
            valueField.setAccessibilityIdentifier(identifier)
            valueField.setAccessibilityLabel(title)
            valueField.setAccessibilityValue(value)
            valueFields[identifier] = valueField
            titleFields.append(titleField)

            let column = NSStackView(views: [titleField, valueField])
            column.orientation = .vertical
            column.spacing = 2
            fieldColumns.append(column)
        }
        applyContentTypography()
    }

    private func applyContentTypography() {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        for titleField in titleFields {
            titleField.font = typography.font(for: .caption)
        }
        for valueField in valueFields.values {
            valueField.font = typography.font(for: .body)
        }
        currentRowGroups.removeAll()
        lastLayoutSignature = nil
        updateMeasuredLayout()
        needsLayout = true
    }

    private func updateMeasuredLayout() {
        guard !fieldColumns.isEmpty else {
            updateHeight(44)
            return
        }
        let availableWidth = max(1, bounds.width - 24)
        let signature = [
            String(Int(availableWidth.rounded(.down))),
            titleFields.map { "\($0.font?.pointSize ?? 0):\($0.stringValue)" }.joined(separator: "|"),
            valueFields.values.map { "\($0.font?.pointSize ?? 0):\($0.stringValue)" }.sorted().joined(separator: "|"),
        ].joined(separator: "#")
        guard signature != lastLayoutSignature else { return }
        lastLayoutSignature = signature
        let groups = rowGroups(fitting: availableWidth)
        if groups != currentRowGroups {
            currentRowGroups = groups
            rebuildRows(groups: groups)
        }
        let rowHeights = groups.map { measuredRowHeight(indices: $0, width: availableWidth) }
        let total = rowHeights.reduce(0, +)
            + CGFloat(max(0, rowHeights.count - 1)) * stackView.spacing
            + 12
        updateHeight(max(44, ceil(total)))
    }

    private func rowGroups(fitting availableWidth: CGFloat) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var currentMinimum: CGFloat = 0
        for index in fieldColumns.indices {
            let minimum = minimumTwoLineWidth(for: index)
            let candidateCount = current.count + 1
            let candidateMinimum = max(currentMinimum, minimum)
            let required = candidateMinimum * CGFloat(candidateCount)
                + CGFloat(candidateCount - 1) * 12
            if !current.isEmpty, required > availableWidth {
                groups.append(current)
                current = [index]
                currentMinimum = minimum
            } else {
                current.append(index)
                currentMinimum = candidateMinimum
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func minimumTwoLineWidth(for index: Int) -> CGFloat {
        guard index < titleFields.count,
              let titleFont = titleFields[index].font,
              let valueField = fieldColumns[index].arrangedSubviews.last as? NSTextField,
              let valueFont = valueField.font else {
            return 64
        }
        return max(
            64,
            max(
                twoLineWidth(text: titleFields[index].stringValue, font: titleFont),
            twoLineWidth(text: valueField.stringValue, font: valueFont)
            )
        )
    }

    private func twoLineWidth(text: String, font: NSFont) -> CGFloat {
        let singleLine = ceil((text as NSString).size(withAttributes: [.font: font]).width + 2)
        var low: CGFloat = 32
        var high = max(low, singleLine)
        let twoLines = ceil(font.boundingRectForFont.height * 2) + 1
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if measuredTextHeight(text, font: font, width: middle) <= twoLines {
                high = middle
            } else {
                low = middle
            }
        }
        return ceil(high)
    }

    private func measuredRowHeight(indices: [Int], width: CGFloat) -> CGFloat {
        guard !indices.isEmpty else { return 0 }
        let fieldWidth = max(
            1,
            (width - CGFloat(indices.count - 1) * 12) / CGFloat(indices.count)
        )
        return ceil(indices.map { index in
            guard let titleFont = titleFields[index].font,
                  let valueField = fieldColumns[index].arrangedSubviews.last as? NSTextField,
                  let valueFont = valueField.font else { return CGFloat(0) }
            return min(
                measuredTextHeight(titleFields[index].stringValue, font: titleFont, width: fieldWidth),
                ceil(titleFont.boundingRectForFont.height * 2)
            ) + 2 + min(
                measuredTextHeight(valueField.stringValue, font: valueFont, width: fieldWidth),
                ceil(valueFont.boundingRectForFont.height * 2)
            )
        }.max() ?? 0)
    }

    private func measuredTextHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        ceil((text as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height)
    }

    private func updateHeight(_ height: CGFloat) {
        guard abs((heightConstraint?.constant ?? 0) - height) > 0.5 else { return }
        heightConstraint?.constant = height
    }

    private func rebuildRows(groups: [[Int]]) {
        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        for group in groups {
            let row = NSStackView(views: group.map { fieldColumns[$0] })
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.distribution = .fillEqually
            row.spacing = 12
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }
    }

    func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        applyContentTypography()
    }

    private func summaryFields(for result: AssemblyResult) -> [(String, String, String)] {
        var fields: [(String, String, String)] = [
            ("assembly-result-summary-assembler", "Assembler", result.tool.displayName),
            ("assembly-result-summary-read-type", "Read Type", displayReadType(result.readType)),
            ("assembly-result-summary-contigs", "Contigs", "\(result.statistics.contigCount)"),
            ("assembly-result-summary-total-bp", "Total bp", "\(result.statistics.totalLengthBP)"),
            ("assembly-result-summary-n50", "N50", "\(result.statistics.n50) bp"),
            ("assembly-result-summary-l50", "L50", "\(result.statistics.l50)"),
            ("assembly-result-summary-longest", "Longest", "\(result.statistics.largestContigBP) bp"),
            ("assembly-result-summary-global-gc", "Global GC", String(format: "%.1f%%", result.statistics.gcPercent)),
        ]

        if let assemblerVersion = result.assemblerVersion, !assemblerVersion.isEmpty {
            fields.append(("assembly-result-summary-version", "Version", assemblerVersion))
        }
        if result.wallTimeSeconds > 0 {
            fields.append(("assembly-result-summary-wall-time", "Wall Time", String(format: "%.1fs", result.wallTimeSeconds)))
        }

        return fields
    }

    private func displayReadType(_ readType: AssemblyReadType) -> String {
        switch readType {
        case .illuminaShortReads:
            return "Illumina Short Reads"
        case .ontReads:
            return "ONT Reads"
        case .pacBioHiFi:
            return "PacBio HiFi/CCS"
        }
    }

#if DEBUG
    func value(for identifier: String) -> String {
        valueFields[identifier]?.stringValue ?? ""
    }

    func copyValue(for identifier: String) {
        valueFields[identifier]?.copyCurrentValue()
    }

    func testValueFontPointSize(identifier: String) -> CGFloat {
        valueFields[identifier]?.font?.pointSize ?? 0
    }

    func testAccessibilityValue(identifier: String) -> String {
        valueFields[identifier]?.accessibilityValue() as? String
            ?? valueFields[identifier]?.stringValue
            ?? ""
    }

    var testHeight: CGFloat { heightConstraint?.constant ?? 0 }
    var testRowCount: Int { stackView.arrangedSubviews.count }
    var testFieldsAllowWrapping: Bool {
        !valueFields.isEmpty && valueFields.values.allSatisfy {
            $0.lineBreakMode == .byWordWrapping && $0.maximumNumberOfLines == 2
        }
    }
    var testRowsFillAvailableWidth: Bool {
        stackView.arrangedSubviews.allSatisfy {
            abs($0.frame.width - stackView.bounds.width) < 1
        }
    }
    var testContentFramesAreContained: Bool {
        fieldColumns.allSatisfy {
            bounds.contains(convert($0.bounds, from: $0))
        }
    }
    var testHasAmbiguousLayout: Bool {
        hasAmbiguousLayout
            || stackView.hasAmbiguousLayout
            || stackView.arrangedSubviews.contains(where: \.hasAmbiguousLayout)
    }
    var testMeasuredContentHeight: CGFloat {
        guard !currentRowGroups.isEmpty else { return 0 }
        let width = max(1, bounds.width - 24)
        return currentRowGroups.map { measuredRowHeight(indices: $0, width: width) }.reduce(0, +)
            + CGFloat(max(0, currentRowGroups.count - 1)) * stackView.spacing
            + 12
    }
    func testSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }
#endif
}
