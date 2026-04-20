// AssemblySummaryStrip.swift - Quick-copy assembly summary metrics
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-summary-strip")

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(result: AssemblyResult, pasteboard: PasteboardWriting) {
        let fieldDefinitions = summaryFields(for: result)
        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
        valueFields.removeAll()

        for (identifier, title, value) in fieldDefinitions {
            let titleField = NSTextField(labelWithString: title)
            titleField.textColor = .secondaryLabelColor
            titleField.font = .systemFont(ofSize: 11, weight: .medium)

            let valueField = AssemblyQuickCopyTextField(labelWithString: value)
            valueField.pasteboard = pasteboard
            valueField.copiedValue = { [weak valueField] in valueField?.stringValue ?? "" }
            valueField.setAccessibilityIdentifier(identifier)
            valueField.setAccessibilityLabel(title)
            valueFields[identifier] = valueField

            let column = NSStackView(views: [titleField, valueField])
            column.orientation = .vertical
            column.spacing = 2
            stackView.addArrangedSubview(column)
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
#endif
}
