import AppKit
import LungfishCore
import LungfishIO

/// Single filter bar above the active genotype content.
///
/// The text field is sample-oriented: animal IDs, haplotype names, comments,
/// genotype strings, and imported metadata fields/values are all evaluated by
/// the owning viewport. Toggle pills remain a compact way to apply common
/// sample predicates without duplicating filtering in the Inspector.
@MainActor
final class GenotypeQuickFilterBarView: NSView, NSSearchFieldDelegate {
    private static let preferredHeight: CGFloat = 40

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

    struct FilterState: Equatable {
        var searchText: String = ""
        var activePills: Set<Pill> = []

        var pillPredicate: SmartCohortPredicate? {
            let children = activePills
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.predicate)
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            return .all(children)
        }

        var saveablePredicate: SmartCohortPredicate? {
            var children = activePills
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.predicate)
            let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty {
                children.append(GenotypeQuickFilterBarView.parseSearchText(search))
            }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            return .all(children)
        }

        var displaySummary: String {
            var parts = activePills
                .sorted { $0.rawValue < $1.rawValue }
                .map(\.displayName)
            let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !search.isEmpty {
                parts.append(search)
            }
            return parts.joined(separator: " + ")
        }
    }

    /// Backward-compatible callback for pill-only predicates.
    var onFilterChanged: ((SmartCohortPredicate?) -> Void)?
    /// Preferred callback: emits pill state and raw sample-search text.
    var onStateChanged: ((FilterState) -> Void)?
    /// Emitted when the clearable saved-cohort chip is clicked.
    var onSavedCohortCleared: (() -> Void)?

    private let searchField = NSSearchField()
    private let savedCohortButton = NSButton()
    private let pillStack = NSStackView()
    private let pillScrollView = NSScrollView()
    private var pillButtons: [Pill: NSButton] = [:]
    private var activePills: Set<Pill> = []
    private var currentSearchText: String = ""
    private let searchDebounceInterval: TimeInterval = 0.18

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
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search samples or haplotypes…"
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: 11)
        searchField.sendsSearchStringImmediately = true

        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pillStack.orientation = .horizontal
        pillStack.alignment = .centerY
        pillStack.spacing = 6
        configureSavedCohortButton()
        pillStack.addArrangedSubview(savedCohortButton)
        pillStack.translatesAutoresizingMaskIntoConstraints = true
        updatePillDocumentFrame()
        pillScrollView.translatesAutoresizingMaskIntoConstraints = false
        pillScrollView.drawsBackground = false
        pillScrollView.borderType = .noBorder
        pillScrollView.hasHorizontalScroller = true
        pillScrollView.hasVerticalScroller = false
        pillScrollView.autohidesScrollers = true
        pillScrollView.documentView = pillStack

        let containerStack = NSStackView()
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 6
        containerStack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        containerStack.addArrangedSubview(searchField)

        addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    private func makePillButton(_ pill: Pill) -> NSButton {
        let button = NSButton(title: pill.displayName, target: self, action: #selector(togglePill(_:)))
        button.bezelStyle = .roundRect
        button.setButtonType(.pushOnPushOff)
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(pill.rawValue)
        return button
    }

    private func configureSavedCohortButton() {
        savedCohortButton.title = ""
        savedCohortButton.bezelStyle = .roundRect
        savedCohortButton.controlSize = .small
        savedCohortButton.target = self
        savedCohortButton.action = #selector(clearSavedCohort(_:))
        savedCohortButton.isHidden = true
        savedCohortButton.identifier = NSUserInterfaceItemIdentifier("savedCohort")
        savedCohortButton.toolTip = "Clear saved cohort filter"
    }

    func setSavedCohortName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            savedCohortButton.title = ""
            savedCohortButton.isHidden = true
        } else {
            savedCohortButton.title = "Saved: \(trimmed)"
            savedCohortButton.isHidden = false
        }
        updatePillDocumentFrame()
    }

    @objc private func clearSavedCohort(_ sender: NSButton) {
        setSavedCohortName(nil)
        onSavedCohortCleared?()
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
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(emitDebouncedSearchChange),
            object: nil
        )
        perform(
            #selector(emitDebouncedSearchChange),
            with: nil,
            afterDelay: searchDebounceInterval
        )
    }

    private func emitChange() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(emitDebouncedSearchChange),
            object: nil
        )
        let state = FilterState(searchText: currentSearchText, activePills: activePills)
        onStateChanged?(state)
        onFilterChanged?(state.pillPredicate)
    }

    @objc private func emitDebouncedSearchChange() {
        emitChange()
    }

    private func updatePillDocumentFrame() {
        let pillSize = pillStack.fittingSize
        pillStack.frame = NSRect(x: 0, y: 0, width: pillSize.width, height: max(24, pillSize.height))
    }

    /// Parse the search field's input into a `SmartCohortPredicate`.
    /// Supports three syntaxes beyond plain substring search:
    ///   - `Cohort=Kenyon20` (or `Cohort:Kenyon20`) — sample metadata
    ///     field/value contains query.
    ///   - `M2A` (or `M2B`, `M3DR`, etc.) — animal carries that exact
    ///     haplotype at any locus
    ///   - `M2@MHC-A` (or `M2:MHC-A`, `M2@A`) — animal carries any
    ///     haplotype prefixed with M2 (M2A, M2B, M2DR…) at the named
    ///     locus; the locus name accepts the canonical `MHC-` form or
    ///     a bare suffix (`A`, `B`, `DRB`, etc.).
    ///   - Anything else falls through to comment substring search.
    nonisolated static func parseSearchText(_ text: String) -> SmartCohortPredicate {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let metadataQuery = metadataFieldQuery(from: trimmed) {
            return .metadataFieldContains(field: metadataQuery.field, value: metadataQuery.value)
        }
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
        return .textContains(trimmed)
    }

    private nonisolated static func metadataFieldQuery(from text: String) -> (field: String, value: String)? {
        for separator in ["=", ":"] {
            guard let range = text.range(of: separator) else { continue }
            let field = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !field.isEmpty, !value.isEmpty else { continue }
            // Preserve the established `M2:A` / `M2@A` haplotype syntax.
            if separator == ":",
               field.range(of: #"^M[0-9]+$"#, options: .regularExpression) != nil {
                continue
            }
            return (field, value)
        }
        return nil
    }
}

#if DEBUG
extension GenotypeQuickFilterBarView {
    var testingSavedCohortChipTitle: String? {
        savedCohortButton.isHidden ? nil : savedCohortButton.title
    }

    var testingVisibleButtonTitles: [String] {
        func collect(from view: NSView) -> [String] {
            let current: [String]
            if let button = view as? NSButton, !button.isHidden {
                current = [button.title]
            } else {
                current = []
            }
            return current + view.subviews.flatMap(collect(from:))
        }
        return collect(from: self)
    }

    func testingClearSavedCohort() {
        clearSavedCohort(savedCohortButton)
    }
}
#endif
