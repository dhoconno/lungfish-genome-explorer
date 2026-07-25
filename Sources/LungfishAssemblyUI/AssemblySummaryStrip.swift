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
}

@MainActor
final class AssemblySummaryStrip: NSView {
    private let stackView = NSStackView()
    private var valueFields: [String: AssemblyQuickCopyTextField] = [:]
    private var titleFields: [NSTextField] = []
    private var fieldColumns: [NSStackView] = []
    private var heightConstraint: NSLayoutConstraint?
    private var contentTypographyObservation: AssemblyContentTypographyObservation?

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
        let typography = ContentTypography.current()
        for titleField in titleFields {
            titleField.font = typography.font(for: .caption)
        }
        for valueField in valueFields.values {
            valueField.font = typography.font(for: .body)
        }
        rebuildRows(maximumColumnsPerRow: maximumColumnsPerRow(for: typography))

        let titleHeight = typography.font(for: .caption).boundingRectForFont.height
        let valueHeight = typography.font(for: .body).boundingRectForFont.height
        let rowHeight = ceil(titleHeight + valueHeight + 2)
        let rowCount = max(1, stackView.arrangedSubviews.count)
        heightConstraint?.constant = max(
            44,
            ceil(CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * stackView.spacing + 12)
        )
        needsLayout = true
    }

    private func maximumColumnsPerRow(for typography: ContentTypography) -> Int {
        switch typography.preference.scaleFactor {
        case 1.75...:
            return 4
        case 1.5..<1.75:
            return 6
        default:
            return max(1, fieldColumns.count)
        }
    }

    private func rebuildRows(maximumColumnsPerRow: Int) {
        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        guard !fieldColumns.isEmpty else { return }

        for start in stride(from: 0, to: fieldColumns.count, by: maximumColumnsPerRow) {
            let end = min(start + maximumColumnsPerRow, fieldColumns.count)
            let row = NSStackView(views: Array(fieldColumns[start..<end]))
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.distribution = .fillEqually
            row.spacing = 12
            stackView.addArrangedSubview(row)
        }
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
#endif
}
