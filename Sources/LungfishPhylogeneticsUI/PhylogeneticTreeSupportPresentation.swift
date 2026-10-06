// PhylogeneticTreeSupportPresentation.swift - how branch support and rooting read in the tree viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

/// Text, columns and colours for branch support values (rulings V1 and V3).
///
/// A tree imported with recorded support labels (for example SH-aLRT and UFBoot from
/// IQ-TREE) gets one node table column per label and a threshold colour scheme. A tree
/// without labels keeps the single Support column and the older 0 to 1 gradient.
public enum PhylogeneticTreeSupportPresentation {
    public struct Column: Equatable, Sendable {
        public let id: String
        public let title: String
    }

    public enum Strength: Equatable, Sendable {
        case strong
        case weak
        case missing
    }

    /// The column identifier of a tree imported without support labels.
    static let unlabelledColumnID = "support"
    static let columnIDPrefix = "support"

    /// The text the viewport summary and the Inspector Rooting row show.
    public static func rootingText(isRooted: Bool) -> String {
        isRooted ? "Rooted" : "Unrooted (drawn root is arbitrary)"
    }

    /// One column per recorded label, or the single Support column when none are recorded.
    public static func columns(labels: [String]) -> [Column] {
        guard !labels.isEmpty else {
            return [Column(id: unlabelledColumnID, title: "Support")]
        }
        return labels.map { Column(id: "\(columnIDPrefix)-\($0)", title: $0) }
    }

    static func isSupportColumnID(_ id: String) -> Bool {
        id == unlabelledColumnID || id.hasPrefix("\(columnIDPrefix)-")
    }

    /// The node table cell text for a support column.
    public static func cellValue(for node: PhylogeneticTreeNormalizedNode, columnID: String) -> String {
        guard columnID != unlabelledColumnID else { return node.support?.rawValue ?? "" }
        let label = String(columnID.dropFirst(columnIDPrefix.count + 1))
        return node.supportValues.first { $0.label == label }?.rawValue ?? ""
    }

    /// The support text as the tree file wrote it, for example "99.9/100".
    public static func supportText(for node: PhylogeneticTreeNormalizedNode) -> String? {
        if !node.supportValues.isEmpty {
            return node.supportValues.map(\.rawValue).joined(separator: "/")
        }
        return node.support?.rawValue
    }

    /// What the support values are, for example "SH-aLRT/UFBoot", read from the labels.
    public static func supportType(for node: PhylogeneticTreeNormalizedNode) -> String? {
        if !node.supportValues.isEmpty {
            return node.supportValues.map(\.label).joined(separator: "/")
        }
        return node.support?.interpretation
    }

    /// The Support and Support Type rows of the selected node.
    public static func detailRows(for node: PhylogeneticTreeNormalizedNode) -> [(String, String)] {
        guard let text = supportText(for: node) else { return [] }
        return [("Support", text), ("Support Type", supportType(for: node) ?? "unknown")]
    }

    /// "support 99.9/100 (SH-aLRT/UFBoot)" for the detail line.
    static func detailSummary(for node: PhylogeneticTreeNormalizedNode) -> String? {
        guard let text = supportText(for: node) else { return nil }
        return "support \(text) (\(supportType(for: node) ?? "unknown"))"
    }

    // MARK: - Colour

    /// The label that colours the canvas: UFBoot when recorded, else the first label.
    public static func colorLabel(labels: [String]) -> String? {
        labels.contains(PhylogeneticTreeSupportLabel.ufBoot) ? PhylogeneticTreeSupportLabel.ufBoot : labels.first
    }

    /// The value at or above which a label counts as strong support
    /// (UFBoot 95 after Minh 2013, SH-aLRT 80 after Guindon 2010, aBayes 0.95).
    static func strongThreshold(for label: String) -> (value: Double, text: String)? {
        switch label {
        case PhylogeneticTreeSupportLabel.ufBoot: return (95, "95")
        case PhylogeneticTreeSupportLabel.shALRT: return (80, "80")
        case PhylogeneticTreeSupportLabel.aBayes: return (0.95, "0.95")
        default: return nil
        }
    }

    public static func strength(for node: PhylogeneticTreeNormalizedNode, labels: [String]) -> Strength {
        guard let label = colorLabel(labels: labels),
              let value = node.supportValues.first(where: { $0.label == label })?.value else {
            return .missing
        }
        guard let threshold = strongThreshold(for: label) else { return .weak }
        return value >= threshold.value ? .strong : .weak
    }

    /// "Color shows UFBoot (95 or higher strong). SH-aLRT 80 or higher also indicates strong
    /// support." Only labels present in the tree are named. Nil when no labels are recorded.
    public static func legendText(labels: [String]) -> String? {
        guard let colorLabel = colorLabel(labels: labels) else { return nil }
        var sentences: [String] = []
        if let threshold = strongThreshold(for: colorLabel) {
            sentences.append("Color shows \(colorLabel) (\(threshold.text) or higher strong).")
        } else {
            sentences.append("Color shows \(colorLabel).")
        }
        for label in labels where label != colorLabel {
            if let threshold = strongThreshold(for: label) {
                sentences.append("\(label) \(threshold.text) or higher also indicates strong support.")
            }
        }
        return sentences.joined(separator: " ")
    }

    static func strengthColor(_ strength: Strength) -> NSColor {
        switch strength {
        case .strong: return .systemBlue
        case .weak: return .systemOrange
        case .missing: return .tertiaryLabelColor
        }
    }

    /// The canvas node colour in support mode.
    static func nodeColor(for node: PhylogeneticTreeNormalizedNode, labels: [String]) -> NSColor {
        guard labels.isEmpty else { return strengthColor(strength(for: node, labels: labels)) }
        guard let value = node.support?.rawValue, let numeric = Double(value) else {
            return .tertiaryLabelColor
        }
        let normalized = max(0, min(1, numeric > 1 ? numeric / 100 : numeric))
        return NSColor.systemBlue.blended(withFraction: 1 - normalized, of: .systemGray) ?? .systemBlue
    }

    /// The legend line: a coloured dot before each word, then the thresholds.
    static func legendAttributedString(labels: [String], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (strength, word) in [(Strength.strong, "Strong"), (.weak, "Weaker"), (.missing, "No value")] {
            result.append(NSAttributedString(
                string: "\u{25CF} ",
                attributes: [.font: font, .foregroundColor: strengthColor(strength)]
            ))
            result.append(NSAttributedString(string: "\(word)   ", attributes: textAttributes))
        }
        result.append(NSAttributedString(string: legendText(labels: labels) ?? "", attributes: textAttributes))
        return result
    }

    /// The legend as VoiceOver reads it, naming each colour.
    static func legendAccessibilityValue(labels: [String]) -> String {
        "Blue strong, orange weaker, grey no value. \(legendText(labels: labels) ?? "")"
    }

    /// Where the canvas draws a node's support text, sized for the font.
    static func canvasTextRect(_ text: String, font: NSFont, nodePoint point: NSPoint) -> NSRect {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let height = ceil(size.height)
        return NSRect(x: point.x + 5, y: point.y - height - 3, width: ceil(size.width) + 2, height: height)
    }
}
