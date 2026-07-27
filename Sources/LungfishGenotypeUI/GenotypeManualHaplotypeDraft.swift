import Foundation
import LungfishCore
import LungfishIO

extension GenotypeManualHaplotypeAssignmentIndex {
    /// Canonical, immutable assignments for one sample.
    ///
    /// This snapshot intentionally has no store or bundle reference. Editors
    /// can therefore prepare and compare a complete sample without causing
    /// persistence as a side effect.
    struct SampleAssignments: Equatable, Sendable {
        let sample: String
        private let values: [
            GenotypeManualHaplotypeLocus:
                GenotypeManualHaplotypeSlotAssignments
        ]

        fileprivate init(
            sample: String,
            values: [
                GenotypeManualHaplotypeLocus:
                    GenotypeManualHaplotypeSlotAssignments
            ]
        ) {
            self.sample = sample
            self.values = values
        }

        subscript(
            locus: GenotypeManualHaplotypeLocus,
            slot: HaplotypeSlot
        ) -> ManualHaplotypeAssignment? {
            values[locus]?[slot]
        }

        var assignments: [ManualHaplotypeAssignment] {
            GenotypeManualHaplotypeLocus.allCases.flatMap { locus in
                HaplotypeSlot.allCases.compactMap { slot in
                    self[locus, slot]
                }
            }
        }
    }

    func sampleAssignments(for rawSample: String) -> SampleAssignments {
        let sample =
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedSampleIdentity(rawSample)
        let values = Dictionary(
            uniqueKeysWithValues:
                GenotypeManualHaplotypeLocus.allCases.map { locus in
                    (
                        locus,
                        assignments(sample: sample, locus: locus)
                    )
                }
        )
        return SampleAssignments(sample: sample, values: values)
    }
}

/// A pure, value-semantic editing buffer for one sample's fourteen manual
/// haplotype assignment slots.
///
/// The draft contains no persistence closure, annotation store, or bundle URL.
/// Callers explicitly pass `validatedAssignments()` to the atomic store
/// operation only after the analyst chooses Save.
struct GenotypeManualHaplotypeDraft: Equatable, Sendable {
    struct SlotAddress: Equatable, Hashable, Sendable {
        let locus: GenotypeManualHaplotypeLocus
        let slot: HaplotypeSlot
    }

    struct SlotValue: Equatable, Sendable {
        var label: String
        var colorTokenIndex: Int
        let diagnosticAlleles: [String]
        let notes: String
        let assignmentID: String?
        let updatedAt: String?
        let author: String?

        fileprivate init(
            label: String,
            colorTokenIndex: Int,
            diagnosticAlleles: [String],
            notes: String,
            assignmentID: String?,
            updatedAt: String?,
            author: String?
        ) {
            self.label = label
            self.colorTokenIndex = colorTokenIndex
            self.diagnosticAlleles = diagnosticAlleles
            self.notes = notes
            self.assignmentID = assignmentID
            self.updatedAt = updatedAt
            self.author = author
        }
    }

    struct SlotPair: Equatable, Sendable {
        var h1: SlotValue?
        var h2: SlotValue?

        subscript(slot: HaplotypeSlot) -> SlotValue? {
            get {
                switch slot {
                case .h1: h1
                case .h2: h2
                }
            }
            set {
                switch slot {
                case .h1: h1 = newValue
                case .h2: h2 = newValue
                }
            }
        }
    }

    struct OrderedSlot: Equatable, Sendable {
        let address: SlotAddress
        let value: SlotValue?
    }

    struct ValidationIssue: Equatable, Sendable {
        let address: SlotAddress
        let error:
            GenotypeManualHaplotypeAssignmentInputValidator.ValidationError
    }

    struct InvalidDraftError: Error, Equatable, LocalizedError, Sendable {
        let issues: [ValidationIssue]

        var errorDescription: String? {
            guard let first = issues.first else {
                return "The manual haplotype draft is invalid."
            }
            return first.error.localizedDescription
        }
    }

    let sample: String
    let original:
        GenotypeManualHaplotypeAssignmentIndex.SampleAssignments
    private(set) var values: [GenotypeManualHaplotypeLocus: SlotPair]
    private(set) var copySource: String?

    private let originalValues:
        [GenotypeManualHaplotypeLocus: SlotPair]
    private let labelCatalog:
        [GenotypeManualHaplotypeAssignmentIndex.LabelCatalogEntry]

    init(
        sample rawSample: String,
        index: GenotypeManualHaplotypeAssignmentIndex
    ) {
        let sample =
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedSampleIdentity(rawSample)
        let original = index.sampleAssignments(for: sample)
        let catalog = index.labelCatalog
        let initialValues = Self.makeValues(
            from: original,
            labelCatalog: catalog
        )

        self.sample = sample
        self.original = original
        self.values = initialValues
        self.copySource = nil
        self.originalValues = initialValues
        self.labelCatalog = catalog
    }

    static let orderedSlotAddresses: [SlotAddress] =
        GenotypeManualHaplotypeLocus.allCases.flatMap { locus in
            [
                SlotAddress(locus: locus, slot: .h1),
                SlotAddress(locus: locus, slot: .h2),
            ]
        }

    var orderedSlots: [OrderedSlot] {
        Self.orderedSlotAddresses.map { address in
            OrderedSlot(
                address: address,
                value: self[address.locus, address.slot]
            )
        }
    }

    var totalSlotCount: Int {
        Self.orderedSlotAddresses.count
    }

    var assignedSlotCount: Int {
        orderedSlots.lazy.compactMap(\.value).count
    }

    var isComplete: Bool {
        assignedSlotCount == totalSlotCount
    }

    var completenessSummary: String {
        "\(assignedSlotCount) of \(totalSlotCount) assigned"
    }

    var isDirty: Bool {
        values != originalValues
    }

    var validationIssues: [ValidationIssue] {
        orderedSlots.compactMap { orderedSlot in
            guard let value = orderedSlot.value else { return nil }
            do {
                _ = try GenotypeManualHaplotypeAssignmentInputValidator
                    .validatedLabel(value.label)
                return nil
            } catch let error as
                GenotypeManualHaplotypeAssignmentInputValidator
                    .ValidationError {
                return ValidationIssue(
                    address: orderedSlot.address,
                    error: error
                )
            } catch {
                preconditionFailure(
                    "Manual haplotype label validation emitted an unexpected error: \(error)"
                )
            }
        }
    }

    var isValid: Bool {
        validationIssues.isEmpty
    }

    subscript(
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) -> SlotValue? {
        values[locus]?[slot]
    }

    func validationIssue(
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) -> ValidationIssue? {
        validationIssues.first {
            $0.address == SlotAddress(locus: locus, slot: slot)
        }
    }

    mutating func setLabel(
        _ rawLabel: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        let label = Self.normalizedDraftLabel(rawLabel)
        let current = self[locus, slot]
        let originalValue = originalValues[locus]?[slot]
        let metadataSource = current ?? originalValue
        let colorTokenIndex = resolvedColorTokenIndex(
            for: label,
            retaining: current
        )
        setValue(
            SlotValue(
                label: label,
                colorTokenIndex: colorTokenIndex,
                diagnosticAlleles:
                    metadataSource?.diagnosticAlleles ?? [],
                notes: metadataSource?.notes ?? "",
                assignmentID: metadataSource?.assignmentID,
                updatedAt: metadataSource?.updatedAt,
                author: metadataSource?.author
            ),
            locus: locus,
            slot: slot
        )
    }

    mutating func clear(
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        setValue(nil, locus: locus, slot: slot)
    }

    func autocompleteSuggestions(
        matching rawQuery: String
    ) -> [GenotypeManualHaplotypeAssignmentIndex.LabelCatalogEntry] {
        let query = Self.normalizedDraftLabel(rawQuery)
        guard !query.isEmpty else { return labelCatalog }
        guard let normalizedQuery = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: query) else {
            return []
        }
        return labelCatalog.filter { entry in
            guard let normalizedLabel = try?
                GenotypeManualHaplotypeAssignmentInputValidator
                    .normalizedLabelKey(for: entry.label) else {
                return false
            }
            return normalizedLabel.contains(normalizedQuery)
        }
    }

    mutating func copyAssignments(
        from source:
            GenotypeManualHaplotypeAssignmentIndex.SampleAssignments
    ) {
        for address in Self.orderedSlotAddresses {
            guard let sourceAssignment =
                source[address.locus, address.slot] else {
                setValue(
                    nil,
                    locus: address.locus,
                    slot: address.slot
                )
                continue
            }
            let sourceValue = Self.slotValue(
                from: sourceAssignment,
                labelCatalog: labelCatalog
            )
            let targetMetadata =
                originalValues[address.locus]?[address.slot]
            setValue(
                SlotValue(
                    label: sourceValue.label,
                    colorTokenIndex: sourceValue.colorTokenIndex,
                    diagnosticAlleles:
                        targetMetadata?.diagnosticAlleles ?? [],
                    notes: targetMetadata?.notes ?? "",
                    assignmentID: targetMetadata?.assignmentID,
                    updatedAt: targetMetadata?.updatedAt,
                    author: targetMetadata?.author
                ),
                locus: address.locus,
                slot: address.slot
            )
        }
        copySource =
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedSampleIdentity(source.sample)
    }

    func validatedAssignments() throws -> [ManualHaplotypeAssignment] {
        let issues = validationIssues
        guard issues.isEmpty else {
            throw InvalidDraftError(issues: issues)
        }
        return try orderedSlots.compactMap { orderedSlot in
            guard let value = orderedSlot.value else { return nil }
            let label =
                try GenotypeManualHaplotypeAssignmentInputValidator
                    .validatedLabel(value.label)
            return ManualHaplotypeAssignment(
                sample: sample,
                locus: orderedSlot.address.locus.rawValue,
                slot: orderedSlot.address.slot,
                label: label,
                colorTokenIndex: value.colorTokenIndex,
                diagnosticAlleles: value.diagnosticAlleles,
                notes: value.notes,
                assignmentID: value.assignmentID,
                updatedAt: value.updatedAt,
                author: value.author
            )
        }
    }

    private mutating func setValue(
        _ value: SlotValue?,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        var pair = values[locus] ?? SlotPair(h1: nil, h2: nil)
        pair[slot] = value
        values[locus] = pair
    }

    private func resolvedColorTokenIndex(
        for label: String,
        retaining current: SlotValue?
    ) -> Int {
        if let current,
           let currentKey = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: current.label),
           let nextKey = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: label),
           currentKey == nextKey {
            return current.colorTokenIndex
        }
        if let entry = catalogEntry(for: label) {
            return entry.colorTokenIndex
        }
        if let draftColor = draftColorTokenIndex(for: label) {
            return draftColor
        }
        return Self.deterministicColorTokenIndex(for: label)
    }

    private static func deterministicColorTokenIndex(
        for label: String
    ) -> Int {
        if let normalizedLabel = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: label),
           let canonicalIndex = HaplotypeColorToken.canonicalByName[
                normalizedLabel.uppercased(
                    with: Locale(identifier: "en_US_POSIX")
                )
           ] {
            return canonicalIndex
        } else if let normalizedLabel = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: label) {
            return HaplotypeColorToken.assigned(
                forName: normalizedLabel
            ).canonicalIndex
        }
        return HaplotypeColorToken.assigned(forName: label).canonicalIndex
    }

    private func draftColorTokenIndex(for label: String) -> Int? {
        guard let normalizedLabel = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: label) else {
            return nil
        }
        for address in Self.orderedSlotAddresses {
            guard let candidate = self[address.locus, address.slot],
                  let candidateLabel = try?
                    GenotypeManualHaplotypeAssignmentInputValidator
                        .normalizedLabelKey(for: candidate.label),
                  candidateLabel == normalizedLabel else {
                continue
            }
            return candidate.colorTokenIndex
        }
        return nil
    }

    private func catalogEntry(
        for label: String
    ) -> GenotypeManualHaplotypeAssignmentIndex.LabelCatalogEntry? {
        guard let normalizedLabel = try?
            GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: label) else {
            return nil
        }
        return labelCatalog.first { entry in
            (try? GenotypeManualHaplotypeAssignmentInputValidator
                .normalizedLabelKey(for: entry.label)) == normalizedLabel
        }
    }

    private static func makeValues(
        from assignments:
            GenotypeManualHaplotypeAssignmentIndex.SampleAssignments,
        labelCatalog:
            [GenotypeManualHaplotypeAssignmentIndex.LabelCatalogEntry]
    ) -> [GenotypeManualHaplotypeLocus: SlotPair] {
        Dictionary(
            uniqueKeysWithValues:
                GenotypeManualHaplotypeLocus.allCases.map { locus in
                    (
                        locus,
                        SlotPair(
                            h1: assignments[locus, .h1].map {
                                slotValue(
                                    from: $0,
                                    labelCatalog: labelCatalog
                                )
                            },
                            h2: assignments[locus, .h2].map {
                                slotValue(
                                    from: $0,
                                    labelCatalog: labelCatalog
                                )
                            }
                        )
                    )
                }
        )
    }

    private static func slotValue(
        from assignment: ManualHaplotypeAssignment,
        labelCatalog:
            [GenotypeManualHaplotypeAssignmentIndex.LabelCatalogEntry]
    ) -> SlotValue {
        let label = normalizedDraftLabel(assignment.label)
        let validColorIndices = Set(
            HaplotypeColorToken.canonicalPalette.map(\.canonicalIndex)
        )
        let resolvedColor: Int
        if let catalogColor = labelCatalog.first(where: {
            guard let candidateKey = try?
                GenotypeManualHaplotypeAssignmentInputValidator
                    .normalizedLabelKey(for: $0.label),
                  let assignmentKey = try?
                GenotypeManualHaplotypeAssignmentInputValidator
                    .normalizedLabelKey(for: label) else {
                return false
            }
            return candidateKey == assignmentKey
        })?.colorTokenIndex {
            resolvedColor = catalogColor
        } else if validColorIndices.contains(assignment.colorTokenIndex) {
            resolvedColor = assignment.colorTokenIndex
        } else {
            resolvedColor = deterministicColorTokenIndex(for: label)
        }
        return SlotValue(
            label: label,
            colorTokenIndex: resolvedColor,
            diagnosticAlleles: assignment.diagnosticAlleles,
            notes: assignment.notes,
            assignmentID: assignment.assignmentID,
            updatedAt: assignment.updatedAt,
            author: assignment.author
        )
    }

    private static func normalizedDraftLabel(_ rawLabel: String) -> String {
        rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}
