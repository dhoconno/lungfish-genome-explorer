import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

/// Single filter bar above the active genotype content.
///
/// The owning viewport routes the text through one shared sample/allele/
/// haplotype index. Toggle pills remain a compact way to apply common sample
/// predicates without duplicating filtering in the Inspector.
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
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let savedCohortButton = NSButton()
    private let pillStack = NSStackView()
    private let pillScrollView = NSScrollView()
    private var pillButtons: [Pill: NSButton] = [:]
    private var activePills: Set<Pill> = []
    private var currentSearchText: String = ""
    private var hasHaplotypingResult = false
    private var lastAnnouncedEmptyState: String?
    private var searchAnnouncementPoster: any AccessibilityAnnouncementPosting =
        AccessibilityAnnouncementPoster()
    private let searchDebounceInterval: TimeInterval = 0.18
    private var contentTypographyObservation: ContentTypographyViewObservation?

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
        searchField.placeholderString = "Search samples or alleles…"
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: 11)
        searchField.sendsSearchStringImmediately = true
        searchField.identifier = NSUserInterfaceItemIdentifier("genotype-quick-search")
        searchField.setAccessibilityIdentifier("genotype-quick-search")
        searchField.setAccessibilityLabel("Search samples or alleles")

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.lineBreakMode = .byTruncatingTail
        emptyStateLabel.setAccessibilityRole(.staticText)
        emptyStateLabel.setAccessibilityIdentifier("genotype-quick-search-empty-state")

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
        containerStack.addArrangedSubview(emptyStateLabel)

        addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(),
            rootProvider: { [weak self] in self },
            afterApply: { [weak self] in
                self?.applyContentTypography()
            }
        )
    }

    override var intrinsicContentSize: NSSize {
        let lineHeight = searchField.font?.boundingRectForFont.height ?? 0
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(
                Self.preferredHeight,
                ceil(lineHeight + (emptyStateLabel.isHidden ? 26 : 48))
            )
        )
    }

    private func applyContentTypography() {
        searchField.font = ContentTypography.current().font(for: .body)
        invalidateIntrinsicContentSize()
        needsLayout = true
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

    func restoreStateWithoutEmitting(_ state: FilterState) {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(emitDebouncedSearchChange),
            object: nil
        )
        currentSearchText = state.searchText
        searchField.stringValue = state.searchText
        activePills = state.activePills
        for (pill, button) in pillButtons {
            button.state = state.activePills.contains(pill) ? .on : .off
        }
    }

    func configureSearchCapability(hasHaplotypingResult: Bool) {
        self.hasHaplotypingResult = hasHaplotypingResult
        let label = hasHaplotypingResult
            ? "Search samples, alleles, or haplotypes"
            : "Search samples or alleles"
        searchField.placeholderString = "\(label)…"
        searchField.setAccessibilityLabel(label)
        if !emptyStateLabel.isHidden {
            updateEmptyState(query: currentSearchText, hasMatches: false)
        }
    }

    func updateEmptyState(query: String, hasMatches: Bool) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !hasMatches else {
            emptyStateLabel.stringValue = ""
            emptyStateLabel.isHidden = true
            lastAnnouncedEmptyState = nil
            invalidateIntrinsicContentSize()
            return
        }
        let subject = hasHaplotypingResult
            ? "samples, alleles, or haplotypes"
            : "samples or alleles"
        let message = "No \(subject) match “\(query)”. Press Escape to clear the search."
        emptyStateLabel.stringValue = message
        emptyStateLabel.isHidden = false
        if lastAnnouncedEmptyState != message {
            searchAnnouncementPoster.post(message, priority: .medium)
            lastAnnouncedEmptyState = message
        }
        invalidateIntrinsicContentSize()
    }

    @discardableResult
    func focusSearchField() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(searchField)
    }

    func clearSearch() {
        guard !currentSearchText.isEmpty || !searchField.stringValue.isEmpty else {
            updateEmptyState(query: "", hasMatches: true)
            return
        }
        setSearchText("")
        updateEmptyState(query: "", hasMatches: true)
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

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === searchField,
              commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        clearSearch()
        return true
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
    var testingSearchFontPointSize: CGFloat {
        searchField.font?.pointSize ?? 0
    }

    var testingSearchPlaceholder: String {
        searchField.placeholderString ?? ""
    }

    var testingSearchAccessibilityLabel: String {
        searchField.accessibilityLabel() ?? ""
    }

    var testingSearchAccessibilityIdentifier: String {
        searchField.accessibilityIdentifier()
    }

    var testingEmptyStateMessage: String {
        emptyStateLabel.isHidden ? "" : emptyStateLabel.stringValue
    }

    func testingSetAnnouncementPoster(
        _ poster: any AccessibilityAnnouncementPosting
    ) {
        searchAnnouncementPoster = poster
    }

    var testingSearchField: NSSearchField {
        searchField
    }
}
#endif

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
