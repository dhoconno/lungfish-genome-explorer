// UniversalSearchAdvancedPopoverController.swift - Advanced project search builder popover
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

@MainActor
final class UniversalSearchAdvancedPopoverController: NSViewController {

    enum Scope: Int, CaseIterable {
        case all
        case esviritu
        case krakenBracken
        case taxTriage
        case fastq
        case vcf
        case manifests

        var title: String {
            switch self {
            case .all: return "All Project Data"
            case .esviritu: return "EsViritu"
            case .krakenBracken: return "Kraken/Bracken"
            case .taxTriage: return "TaxTriage"
            case .fastq: return "FASTQ Datasets"
            case .vcf: return "VCF + Reference"
            case .manifests: return "JSON Manifests"
            }
        }

        var typeTokens: [String] {
            switch self {
            case .all:
                return []
            case .esviritu:
                return ["type:virus_hit", "type:esviritu_result"]
            case .krakenBracken:
                return ["type:classification_taxon", "type:classification_result"]
            case .taxTriage:
                return ["type:taxtriage_organism", "type:taxtriage_result"]
            case .fastq:
                return ["type:fastq_dataset"]
            case .vcf:
                return ["type:vcf_sample", "type:vcf_track", "type:reference_bundle"]
            case .manifests:
                return ["type:manifest_document"]
            }
        }

        static func fromKinds(_ kinds: Set<String>) -> Scope {
            guard !kinds.isEmpty else { return .all }
            for candidate in Scope.allCases where candidate != .all {
                if Set(candidate.typeTokens.map { String($0.dropFirst("type:".count)) }) == kinds {
                    return candidate
                }
            }
            return .all
        }
    }

    var onApply: ((String) -> Void)?
    var onClear: (() -> Void)?

    private let scopePopup = NSPopUpButton()
    private let keywordField = NSSearchField()
    private let virusField = NSTextField()
    private let familyField = NSTextField()
    private let speciesField = NSTextField()
    private let sampleField = NSTextField()
    private let minUniqueReadsField = NSTextField()
    private let minTotalReadsField = NSTextField()
    private let maxTotalReadsField = NSTextField()
    private let dateFromField = NSTextField()
    private let dateToField = NSTextField()
    private let foundPathogensOnly = NSButton(checkboxWithTitle: "High-confidence pathogens only", target: nil, action: nil)

    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 430))
        view = container

        let titleLabel = NSTextField(labelWithString: "Advanced Search")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(wrappingLabelWithString: "Build structured filters for viruses, taxa, and read thresholds without memorizing query syntax.")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        configureControls()

        let grid = NSGridView(views: [
            [fieldLabel("Scope"), scopePopup],
            [fieldLabel("Keywords"), keywordField],
            [fieldLabel("Virus"), virusField],
            [fieldLabel("Family"), familyField],
            [fieldLabel("Species"), speciesField],
            [fieldLabel("Sample"), sampleField],
            [fieldLabel("Min Unique Reads"), minUniqueReadsField],
            [fieldLabel("Min Total Reads"), minTotalReadsField],
            [fieldLabel("Max Total Reads"), maxTotalReadsField],
            [fieldLabel("Date From"), dateFromField],
            [fieldLabel("Date To"), dateToField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        foundPathogensOnly.translatesAutoresizingMaskIntoConstraints = false
        foundPathogensOnly.font = .systemFont(ofSize: 11)

        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(applyTapped(_:))

        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearTapped(_:))

        let buttonRow = NSStackView(views: [clearButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(hintLabel)
        container.addSubview(grid)
        container.addSubview(foundPathogensOnly)
        container.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            grid.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            foundPathogensOnly.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            foundPathogensOnly.leadingAnchor.constraint(equalTo: grid.leadingAnchor),

            buttonRow.topAnchor.constraint(equalTo: foundPathogensOnly.bottomAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            buttonRow.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
        ])
    }

    func configure(from rawQuery: String) {
        let parsed = ProjectUniversalSearchQueryParser.parse(rawQuery, limit: 500)
        let scope = Scope.fromKinds(parsed.kinds)
        scopePopup.selectItem(at: scope.rawValue)

        keywordField.stringValue = parsed.textTerms.joined(separator: " ")
        virusField.stringValue = firstAttributeValue(for: "virus_name", in: parsed)
        familyField.stringValue = firstAttributeValue(for: "family", in: parsed)
        speciesField.stringValue = firstAttributeValue(for: "species", in: parsed)
        sampleField.stringValue = firstAttributeValue(for: "sample_name", in: parsed)

        minUniqueReadsField.stringValue = firstNumberValue(for: "read_count", comparison: .greaterThanOrEqual, in: parsed)
        minTotalReadsField.stringValue = firstNumberValue(for: "filtered_reads_in_sample", comparison: .greaterThanOrEqual, in: parsed)
        maxTotalReadsField.stringValue = firstNumberValue(for: "filtered_reads_in_sample", comparison: .lessThanOrEqual, in: parsed)

        dateFromField.stringValue = formatDate(parsed.dateFrom)
        dateToField.stringValue = formatDate(parsed.dateTo)

        let foundPathogenRequested = parsed.attributeFilters.contains {
            $0.key == "found_pathogen" && ($0.value == "true" || $0.value == "yes" || $0.value == "1")
        }
        foundPathogensOnly.state = foundPathogenRequested ? .on : .off
    }

    private func configureControls() {
        scopePopup.removeAllItems()
        scopePopup.addItems(withTitles: Scope.allCases.map(\.title))
        scopePopup.selectItem(at: Scope.all.rawValue)

        keywordField.placeholderString = "e.g. SARS-CoV-2"
        virusField.placeholderString = "virus name"
        familyField.placeholderString = "e.g. Coronaviridae"
        speciesField.placeholderString = "e.g. Severe acute respiratory syndrome coronavirus 2"
        sampleField.placeholderString = "sample ID or label"

        minUniqueReadsField.placeholderString = "20"
        minTotalReadsField.placeholderString = "1000"
        maxTotalReadsField.placeholderString = "1000000"

        dateFromField.placeholderString = "YYYY-MM-DD"
        dateToField.placeholderString = "YYYY-MM-DD"

        let textFields: [NSTextField] = [
            virusField,
            familyField,
            speciesField,
            sampleField,
            minUniqueReadsField,
            minTotalReadsField,
            maxTotalReadsField,
            dateFromField,
            dateToField,
        ]
        for field in textFields {
            field.controlSize = .small
            field.font = .systemFont(ofSize: 11)
        }
        keywordField.controlSize = .small
        keywordField.font = .systemFont(ofSize: 11)
    }

    @objc private func applyTapped(_ sender: Any) {
        onApply?(buildQuery())
    }

    @objc private func clearTapped(_ sender: Any) {
        onClear?()
    }

    private func buildQuery() -> String {
        var tokens: [String] = []

        let scope = Scope(rawValue: scopePopup.indexOfSelectedItem) ?? .all
        tokens.append(contentsOf: scope.typeTokens)

        let keyword = keywordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            tokens.append(keyword)
        }

        appendFieldToken(into: &tokens, key: "virus", value: virusField.stringValue)
        appendFieldToken(into: &tokens, key: "family", value: familyField.stringValue)
        appendFieldToken(into: &tokens, key: "species", value: speciesField.stringValue)
        appendFieldToken(into: &tokens, key: "sample", value: sampleField.stringValue)

        appendNumericToken(into: &tokens, key: "unique_reads", symbol: ">=", rawValue: minUniqueReadsField.stringValue)
        appendNumericToken(into: &tokens, key: "total_reads", symbol: ">=", rawValue: minTotalReadsField.stringValue)
        appendNumericToken(into: &tokens, key: "total_reads", symbol: "<=", rawValue: maxTotalReadsField.stringValue)

        appendDateToken(into: &tokens, prefix: "date>=", rawValue: dateFromField.stringValue)
        appendDateToken(into: &tokens, prefix: "date<=", rawValue: dateToField.stringValue)

        if foundPathogensOnly.state == .on {
            tokens.append("found_pathogen:true")
        }

        return tokens.joined(separator: " ")
    }

    private func appendFieldToken(into tokens: inout [String], key: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        if escaped.contains(where: { $0.isWhitespace }) {
            tokens.append("\(key):\"\(escaped)\"")
        } else {
            tokens.append("\(key):\(escaped)")
        }
    }

    private func appendNumericToken(into tokens: inout [String], key: String, symbol: String, rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else { return }
        let rendered: String
        if value.rounded() == value {
            rendered = String(Int(value))
        } else {
            rendered = String(value)
        }
        tokens.append("\(key)\(symbol)\(rendered)")
    }

    private func appendDateToken(into tokens: inout [String], prefix: String, rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let date = parseDate(trimmed) else { return }
        tokens.append("\(prefix)\(date)")
    }

    private func parseDate(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { return nil }
        return formatter.string(from: date)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func firstAttributeValue(for key: String, in parsed: ProjectUniversalSearchQuery) -> String {
        parsed.attributeFilters.first(where: { $0.key == key })?.value ?? ""
    }

    private func firstNumberValue(
        for key: String,
        comparison: ProjectUniversalSearchQuery.NumberComparison,
        in parsed: ProjectUniversalSearchQuery
    ) -> String {
        guard let value = parsed.numberFilters.first(where: { $0.key == key && $0.comparison == comparison })?.value else {
            return ""
        }
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }
}
