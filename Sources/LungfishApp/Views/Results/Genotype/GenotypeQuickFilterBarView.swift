import AppKit
import LungfishCore
import LungfishIO

/// Quick-filter bar that sits above the cohort list inside Panel A.
///
/// Hosts an NSSearchField for animal/comment matching plus a row of toggle
/// pills for common single-dimension filters (Has errors, Homozygous,
/// Recombinant, Bw6+, Has comments). The bar emits a smart-cohort predicate
/// equivalent to the active selection so the existing
/// `.genotypeResultSmartCohortApplied` notification path can apply it.
@MainActor
final class GenotypeQuickFilterBarView: NSView, NSSearchFieldDelegate {
    enum Pill: String, CaseIterable {
        case hasErrors
        case homozygous
        case recombinant
        case bw6Positive
        case hasComments
        case duplicate

        var displayName: String {
            switch self {
            case .hasErrors:    return "Has errors"
            case .homozygous:   return "Homozygous"
            case .recombinant:  return "Recombinant"
            case .bw6Positive:  return "Bw6+"
            case .hasComments:  return "Has comments"
            case .duplicate:    return "Duplicate"
            }
        }

        var predicate: SmartCohortPredicate {
            switch self {
            case .hasErrors:    return .hasErrorAtAnyLocus
            case .homozygous:   return .isHomozygousAcrossAll
            case .recombinant:  return .hasRegionalRecombinant
            case .bw6Positive:  return .commentContains("Bw6+")
            case .hasComments:  return .hasAnyComment
            case .duplicate:    return .commentContains("duplicate")
            }
        }
    }

    /// Called when the user changes either the search text or the active pills.
    /// The predicate is `nil` when nothing is active (full cohort), or the
    /// combined predicate the viewport should apply.
    var onFilterChanged: ((SmartCohortPredicate?) -> Void)?

    private let searchField = NSSearchField()
    private let pillStack = NSStackView()
    private var pillButtons: [Pill: NSButton] = [:]
    private var activePills: Set<Pill> = []
    private var currentSearchText: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildSubviews()
    }

    private func buildSubviews() {
        translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search comment, or M2 / M2A / M2@MHC-B for haplotype filters…"
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: 11)
        searchField.sendsSearchStringImmediately = true

        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pillStack.orientation = .horizontal
        pillStack.alignment = .centerY
        pillStack.spacing = 6
        for pill in Pill.allCases {
            let button = makePillButton(pill)
            pillButtons[pill] = button
            pillStack.addArrangedSubview(button)
        }

        let containerStack = NSStackView()
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 6
        containerStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        containerStack.addArrangedSubview(searchField)
        containerStack.addArrangedSubview(pillStack)

        addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func makePillButton(_ pill: Pill) -> NSButton {
        let button = NSButton(title: pill.displayName, target: self, action: #selector(togglePill(_:)))
        button.bezelStyle = .roundRect
        button.setButtonType(.pushOnPushOff)
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(pill.rawValue)
        return button
    }

    @objc private func togglePill(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let pill = Pill(rawValue: rawValue) else { return }
        if sender.state == .on {
            activePills.insert(pill)
        } else {
            activePills.remove(pill)
        }
        emitChange()
    }

    func setActivePills(_ pills: Set<Pill>) {
        activePills = pills
        for (pill, button) in pillButtons {
            button.state = pills.contains(pill) ? .on : .off
        }
        emitChange()
    }

    func setSearchText(_ text: String) {
        searchField.stringValue = text
        currentSearchText = text
        emitChange()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else { return }
        currentSearchText = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        emitChange()
    }

    private func emitChange() {
        var children: [SmartCohortPredicate] = activePills.map(\.predicate)
        if !currentSearchText.isEmpty {
            children.append(Self.parseSearchText(currentSearchText))
        }
        let combined: SmartCohortPredicate?
        if children.isEmpty {
            combined = nil
        } else if children.count == 1 {
            combined = children.first
        } else {
            combined = .all(children)
        }
        onFilterChanged?(combined)
    }

    /// Parse the search field's input into a `SmartCohortPredicate`.
    /// Supports three syntaxes beyond plain substring search:
    ///   - `M2A` (or `M2B`, `M3DR`, etc.) — animal carries that exact
    ///     haplotype at any locus
    ///   - `M2@MHC-A` (or `M2:MHC-A`, `M2@A`) — animal carries any
    ///     haplotype prefixed with M2 (M2A, M2B, M2DR…) at the named
    ///     locus; the locus name accepts the canonical `MHC-` form or
    ///     a bare suffix (`A`, `B`, `DRB`, etc.).
    ///   - Anything else falls through to comment substring search.
    static func parseSearchText(_ text: String) -> SmartCohortPredicate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `M2@A` / `M2:MHC-A` style
        let separators = CharacterSet(charactersIn: "@:")
        if let separatorRange = trimmed.rangeOfCharacter(from: separators) {
            let haplotype = String(trimmed[..<separatorRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let locusRaw = String(trimmed[separatorRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if !haplotype.isEmpty, !locusRaw.isEmpty {
                let locus = locusRaw.hasPrefix("MHC-") ? locusRaw : "MHC-\(locusRaw)"
                return .hasHaplotypePrefixAt(prefix: haplotype, locus: locus)
            }
        }
        // Exact haplotype name (M2A, M3DR, etc.) — single token, alphanum.
        if trimmed.range(of: "^M[0-9]+[A-Za-z]+$", options: .regularExpression) != nil {
            return .hasHaplotypeAtAnyLocus(name: trimmed)
        }
        // Bare M-prefix (M2, M3) — match any haplotype with that prefix
        // at any locus.
        if trimmed.range(of: "^M[0-9]+$", options: .regularExpression) != nil {
            return .hasHaplotypePrefixAtAnyLocus(prefix: trimmed)
        }
        return .commentContains(trimmed)
    }
}
