import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public enum GenotypeResultPanelLayout: String, CaseIterable, Equatable {
    case listLeading
    case listTrailing
    case listTop

    public var displayName: String {
        switch self {
        case .listLeading:
            return "List Left"
        case .listTrailing:
            return "List Right"
        case .listTop:
            return "List Top"
        }
    }

    public var inspectorLabel: String {
        switch self {
        case .listTrailing:
            return "Detail | List"
        case .listLeading:
            return "List | Detail"
        case .listTop:
            return "List Over Detail"
        }
    }

    public var inspectorSystemImage: String {
        switch self {
        case .listTrailing:
            return "sidebar.left"
        case .listLeading:
            return "sidebar.right"
        case .listTop:
            return "rectangle.split.1x2"
        }
    }
}

public enum GenotypeResultViewportLens: String, CaseIterable, Equatable {
    case summary
    case review
    case audit

    public var displayName: String {
        switch self {
        case .summary: return "Summary"
        case .review:  return "Review"
        case .audit:   return "Audit"
        }
    }

    public var inspectorSystemImage: String {
        switch self {
        case .summary: return "tablecells"
        case .review:  return "checklist"
        case .audit:   return "doc.text.magnifyingglass"
        }
    }

    public var identifier: String {
        rawValue
    }
}

public enum GenotypeSummaryViewMode: String, CaseIterable, Equatable {
    case outline
    case matrix

    public var displayName: String {
        switch self {
        case .outline: return "Outline"
        case .matrix:  return "Matrix"
        }
    }
}

public enum GenotypeResultCellColorMode: String, CaseIterable, Equatable {
    case support
    case highlights
    case none

    public var displayName: String {
        switch self {
        case .support:
            return "Support"
        case .highlights:
            return "Highlights"
        case .none:
            return "None"
        }
    }
}

public struct GenotypeResultDisplayState: Equatable {
    public var viewportLens: GenotypeResultViewportLens = .summary
    public var summaryViewMode: GenotypeSummaryViewMode = .outline
    public var layout: GenotypeResultPanelLayout = .listTop
    public var hideLowSupport: Bool = false
    public var minimumSupportPercent: Double = 0
    public var supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus
    public var cellColorMode: GenotypeResultCellColorMode = .support
    public var hideFilteredHighlights: Bool = true
    /// When true, the Outline / Matrix views include observed loci
    /// that the active haplotype definition set does NOT cover. When false
    /// (the default), only the definition-set loci appear so the tape stays
    /// focused on the calls actually being haplotyped. For MCM that means
    /// the canonical 7 loci instead of every locus the demux observed.
    public var showsAncillaryLoci: Bool = false
    /// Loci selected for the deterministic haplotype Outline. Workbook updates
    /// write the subset supported by current.xlsx. `nil` means use the
    /// result-specific default selection.
    public var includedLoci: Set<String>? = nil

    /// Editable row-visibility filter: samples with fewer than this many
    /// `passedUniqueReads` may be hidden from the result rows. `0` (the
    /// default) disables the filter. This is a SEPARATE concern from the
    /// cohort flag below and must never alias it.
    public var minimumReads: Int = 0
    public var matrixMinimumReads: Int = 0
    public var matrixMinimumPercent: Double = 0
    public var matrixPercentDenominator: ONTGenotypeSupportDenominator = .viewedLocus
    public var matrixRowFilterText: String = ""
    public var matrixSampleFilterText: String = ""
    /// Whether the manual haplotype summary band below matrix sample headers
    /// is expanded. This presentation-only value is persisted with the
    /// project/window display state.
    public var manualHaplotypeBandExpanded: Bool = true
    /// Optional live override for the bundle-scoped candidate viewport settings.
    /// `nil` preserves the settings loaded from this result bundle's annotation
    /// sidecar. Full-length MHC controls use this while an edit is being applied.
    public var mhcCandidateDisplaySettings: ONTMHCCandidateDisplaySettings? = nil

    /// The historical "calls below this are unreliable" cohort flag (default
    /// `5_000`). It LABELS samples in the Cohort Summary panel; it does not
    /// hide rows. Previously hardcoded in the view controller, now editable.
    public var cohortFlagThreshold: Int = 5_000

    public init(
        viewportLens: GenotypeResultViewportLens = .summary,
        summaryViewMode: GenotypeSummaryViewMode = .outline,
        layout: GenotypeResultPanelLayout = .listTop,
        hideLowSupport: Bool = false,
        minimumSupportPercent: Double = 0,
        supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
        cellColorMode: GenotypeResultCellColorMode = .support,
        hideFilteredHighlights: Bool = true,
        showsAncillaryLoci: Bool = false,
        includedLoci: Set<String>? = nil,
        minimumReads: Int = 0,
        matrixMinimumReads: Int = 0,
        matrixMinimumPercent: Double = 0,
        matrixPercentDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
        matrixRowFilterText: String = "",
        matrixSampleFilterText: String = "",
        manualHaplotypeBandExpanded: Bool = true,
        mhcCandidateDisplaySettings: ONTMHCCandidateDisplaySettings? = nil,
        cohortFlagThreshold: Int = 5_000
    ) {
        self.viewportLens = viewportLens
        self.summaryViewMode = summaryViewMode
        self.layout = layout
        self.hideLowSupport = hideLowSupport
        self.minimumSupportPercent = minimumSupportPercent
        self.supportDenominator = supportDenominator
        self.cellColorMode = cellColorMode
        self.hideFilteredHighlights = hideFilteredHighlights
        self.showsAncillaryLoci = showsAncillaryLoci
        self.includedLoci = includedLoci
        self.minimumReads = minimumReads
        self.matrixMinimumReads = max(0, matrixMinimumReads)
        self.matrixMinimumPercent = max(0, min(100, matrixMinimumPercent))
        self.matrixPercentDenominator = matrixPercentDenominator
        self.matrixRowFilterText = matrixRowFilterText
        self.matrixSampleFilterText = matrixSampleFilterText
        self.manualHaplotypeBandExpanded = manualHaplotypeBandExpanded
        self.mhcCandidateDisplaySettings = mhcCandidateDisplaySettings
        self.cohortFlagThreshold = cohortFlagThreshold
    }

    public var activeMinimumSupportPercent: Double {
        hideLowSupport ? minimumSupportPercent : 0
    }

    public func normalized(forGenotypeOnlyResult isGenotypeOnlyResult: Bool) -> Self {
        guard isGenotypeOnlyResult else { return self }
        var normalized = self
        if normalized.viewportLens == .review {
            normalized.viewportLens = .summary
        }
        normalized.summaryViewMode = .matrix
        normalized.layout = .listTop
        return normalized
    }

    /// The effective row-visibility threshold. `0` means no row filtering.
    public var activeMinimumReads: Int {
        MinimumReadsThreshold(value: minimumReads).active
    }

    /// Sample IDs hidden by the editable row-visibility filter, sorted.
    /// Returns an empty array when the filter is off (`activeMinimumReads == 0`).
    public func samplesBelowFilter(_ reads: [(sample: String, reads: Int)]) -> [String] {
        let threshold = activeMinimumReads
        guard threshold > 0 else { return [] }
        return reads
            .filter { $0.reads < threshold }
            .map(\.sample)
            .sorted()
    }

    /// Sample IDs flagged as unreliable by the cohort flag, sorted.
    public func samplesBelowCohortFlag(_ reads: [(sample: String, reads: Int)]) -> [String] {
        reads
            .filter { $0.reads < cohortFlagThreshold }
            .map(\.sample)
            .sorted()
    }
}

extension GenotypeResultDisplayState {
    func replacingMatrixPresentation(
        from source: GenotypeResultDisplayState
    ) -> GenotypeResultDisplayState {
        var replaced = self
        replaced.hideLowSupport = source.hideLowSupport
        replaced.minimumSupportPercent = source.minimumSupportPercent
        replaced.supportDenominator = source.supportDenominator
        replaced.cellColorMode = source.cellColorMode
        replaced.hideFilteredHighlights = source.hideFilteredHighlights
        replaced.minimumReads = source.minimumReads
        replaced.matrixMinimumReads = source.matrixMinimumReads
        replaced.matrixMinimumPercent = source.matrixMinimumPercent
        replaced.matrixPercentDenominator = source.matrixPercentDenominator
        replaced.matrixRowFilterText = source.matrixRowFilterText
        replaced.matrixSampleFilterText = source.matrixSampleFilterText
        replaced.manualHaplotypeBandExpanded =
            source.manualHaplotypeBandExpanded
        replaced.mhcCandidateDisplaySettings = source.mhcCandidateDisplaySettings
        return replaced
    }

    func requiresMatrixDerivedProjection(
        comparedTo previous: GenotypeResultDisplayState
    ) -> Bool {
        hideLowSupport != previous.hideLowSupport
            || minimumSupportPercent != previous.minimumSupportPercent
            || supportDenominator != previous.supportDenominator
            || matrixMinimumReads != previous.matrixMinimumReads
            || matrixMinimumPercent != previous.matrixMinimumPercent
            || matrixPercentDenominator != previous.matrixPercentDenominator
    }

    func requiresMatrixFilterPass(comparedTo previous: GenotypeResultDisplayState) -> Bool {
        requiresMatrixDerivedProjection(comparedTo: previous)
            || minimumReads != previous.minimumReads
            || matrixRowFilterText != previous.matrixRowFilterText
            || matrixSampleFilterText != previous.matrixSampleFilterText
    }

    func requiresMatrixRedraw(comparedTo previous: GenotypeResultDisplayState) -> Bool {
        cellColorMode != previous.cellColorMode
            || hideFilteredHighlights != previous.hideFilteredHighlights
    }
}

struct GenotypeMatrixRenderedStyle: Equatable {
    var fillColor: AnnotationColor?
    var textColor: AnnotationColor?
    var borderColor: AnnotationColor?
    var isBold: Bool = false
    var isItalic: Bool = false

    static let `default` = GenotypeMatrixRenderedStyle()

    var isDefault: Bool {
        fillColor == nil && textColor == nil && borderColor == nil && !isBold && !isItalic
    }
}

enum GenotypeMatrixSemanticTextColorRole: Equatable {
    case primary
    case secondary
}

struct GenotypeMatrixSemanticTextPresentation: Equatable {
    let value: String
    let colorRole: GenotypeMatrixSemanticTextColorRole
    let isItalic: Bool
}

struct GenotypeMatrixScopedCommentCounts: Equatable {
    let alleleRow: Int
    let sampleColumn: Int
    let cell: Int

    var total: Int {
        alleleRow + sampleColumn + cell
    }
}

struct GenotypeMatrixCellChromeState: Equatable {
    let decorativeBorderWidth: CGFloat?
    let semanticInnerFrameWidth: CGFloat?
    let selectionCornerBracketWidth: CGFloat?
    let selectionCornerBracketLength: CGFloat
    let commentFoldSize: CGFloat?
}

struct GenotypeMatrixCellSemanticState: Equatable {
    let text: GenotypeMatrixSemanticTextPresentation
    let evidenceReads: Int?
    let review: GenotypeAnnotationSidecar.MatrixReviewDisposition?
    let chrome: GenotypeMatrixCellChromeState
    let commentCounts: GenotypeMatrixScopedCommentCounts
    let hasNativeCellCommentMarker: Bool
    let isSelected: Bool
    let accessibilityLabel: String
}

enum GenotypeMatrixContextCommand: Int, CaseIterable, Equatable {
    case hideSelectedRows
    case showOnlySelectedRows
    case hideSelectedColumns
    case showOnlySelectedColumns
    case resetVisibility
    case markFalsePositive
    case markFalseNegative
    case clearReview
    case editComment
    case removeComments
    case selectSupportedCells
    case editManualHaplotypeAssignments

    var isSelectionTargetedVisibilityCommand: Bool {
        switch self {
        case .hideSelectedRows, .showOnlySelectedRows,
             .hideSelectedColumns, .showOnlySelectedColumns:
            true
        case .resetVisibility, .markFalsePositive, .markFalseNegative, .clearReview,
             .editComment, .removeComments, .selectSupportedCells,
             .editManualHaplotypeAssignments:
            false
        }
    }
}

struct GenotypeMatrixContextMenuItemState: Equatable {
    let title: String
    let command: GenotypeMatrixContextCommand
    let availability: GenotypeMatrixCommandAvailability
    let keyEquivalent: String
    let keyModifierRawValue: UInt
}

struct GenotypeMatrixContextMenuState: Equatable {
    let selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    let visibilityItems: [GenotypeMatrixContextMenuItemState]
    let visibilitySubmenus: [GenotypeMatrixContextMenuSubmenuState]
    let items: [GenotypeMatrixContextMenuItemState]
    let inspectedTargetCount: Int
}

struct GenotypeMatrixContextMenuSubmenuState: Equatable {
    enum Kind: Equatable {
        case rowVisibility
        case columnVisibility
    }

    let kind: Kind
    let title: String
    let items: [GenotypeMatrixContextMenuItemState]
}

struct GenotypeMatrixContextMenuSnapshot: Equatable, Sendable {
    let selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    let capability: GenotypeMatrixReviewCapabilityState
    let visibilityCapability: GenotypeMatrixVisibilityCapabilitySnapshot
    let keyModifierRawValue: UInt
    let manualHaplotypeEditSample: String?

    init(
        selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget],
        capability: GenotypeMatrixReviewCapabilityState,
        visibilityCapability: GenotypeMatrixVisibilityCapabilitySnapshot,
        keyModifierRawValue: UInt,
        manualHaplotypeEditSample: String? = nil
    ) {
        self.selectionTargets = selectionTargets
        self.capability = capability
        self.visibilityCapability = visibilityCapability
        self.keyModifierRawValue = keyModifierRawValue
        self.manualHaplotypeEditSample = manualHaplotypeEditSample
    }
}

@MainActor
protocol GenotypeMatrixContextMenuSnapshotProviding: AnyObject {
    var cachedSnapshot: GenotypeMatrixContextMenuSnapshot { get }
}

@MainActor
final class GenotypeMatrixImmutableContextMenuSnapshotSource:
    GenotypeMatrixContextMenuSnapshotProviding {
    let cachedSnapshot: GenotypeMatrixContextMenuSnapshot

    init(snapshot: GenotypeMatrixContextMenuSnapshot) {
        cachedSnapshot = snapshot
    }
}

struct GenotypeMatrixContextMenuBuilder {
    static func make(snapshot: GenotypeMatrixContextMenuSnapshot) -> GenotypeMatrixContextMenuState {
        let selectionTargets = snapshot.selectionTargets
        let capability = snapshot.capability
        let visibilityCapability = snapshot.visibilityCapability
        var visibilityItems: [GenotypeMatrixContextMenuItemState] = []
        var visibilitySubmenus: [GenotypeMatrixContextMenuSubmenuState] = []
        let rowItems = rowVisibilityItems(capability: visibilityCapability)
        let columnItems = columnVisibilityItems(capability: visibilityCapability)
        switch visibilityCapability.selectionShape {
        case .rows:
            visibilityItems.append(contentsOf: rowItems)
        case .columns:
            visibilityItems.append(contentsOf: columnItems)
        case .cellRectangle, .sparseCells, .mixed:
            if !rowItems.isEmpty {
                visibilitySubmenus.append(.init(
                    kind: .rowVisibility,
                    title: "Row Visibility",
                    items: rowItems
                ))
            }
            if !columnItems.isEmpty {
                visibilitySubmenus.append(.init(
                    kind: .columnVisibility,
                    title: "Column Visibility",
                    items: columnItems
                ))
            }
        case .none:
            break
        }
        if visibilityCapability.canResetVisibility {
            visibilityItems.append(.init(
                title: visibilityCapability.showAllTitle,
                command: .resetVisibility,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ))
        }
        var items = [
            GenotypeMatrixContextMenuItemState(
                title: "Mark False Positive",
                command: .markFalsePositive,
                availability: capability.falsePositive,
                keyEquivalent: "p",
                keyModifierRawValue: snapshot.keyModifierRawValue
            ),
            GenotypeMatrixContextMenuItemState(
                title: "Mark False Negative",
                command: .markFalseNegative,
                availability: capability.falseNegative,
                keyEquivalent: "n",
                keyModifierRawValue: snapshot.keyModifierRawValue
            ),
            GenotypeMatrixContextMenuItemState(
                title: "Clear Review",
                command: .clearReview,
                availability: capability.clearReview,
                keyEquivalent: "r",
                keyModifierRawValue: snapshot.keyModifierRawValue
            ),
            GenotypeMatrixContextMenuItemState(
                title: commentMenuTitle(
                    capability: capability,
                    targetCount: selectionTargets.count
                ),
                command: .editComment,
                availability: capability.upsertComment,
                keyEquivalent: "m",
                keyModifierRawValue: snapshot.keyModifierRawValue
            ),
            GenotypeMatrixContextMenuItemState(
                title: selectionTargets.count == 1 ? "Remove Comment" : "Remove Comments",
                command: .removeComments,
                availability: capability.removeComments,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
        ]
        if snapshot.manualHaplotypeEditSample != nil {
            items.insert(
                GenotypeMatrixContextMenuItemState(
                    title: "Edit Haplotype Assignments…",
                    command: .editManualHaplotypeAssignments,
                    availability: .enabled,
                    keyEquivalent: "",
                    keyModifierRawValue: 0
                ),
                at: 0
            )
        }
        if capability.selectionShape == .rows || capability.selectionShape == .columns {
            items.append(GenotypeMatrixContextMenuItemState(
                title: "Select Supported Cells (≥ 1 read)",
                command: .selectSupportedCells,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ))
        }
        return GenotypeMatrixContextMenuState(
            selectionTargets: selectionTargets,
            visibilityItems: visibilityItems,
            visibilitySubmenus: visibilitySubmenus,
            items: items,
            inspectedTargetCount: selectionTargets.count
        )
    }

    private static func rowVisibilityItems(
        capability: GenotypeMatrixVisibilityCapabilitySnapshot
    ) -> [GenotypeMatrixContextMenuItemState] {
        guard capability.canHideSelectedRows else { return [] }
        return [
            .init(
                title: capability.hideSelectedRowsTitle,
                command: .hideSelectedRows,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
            .init(
                title: capability.showOnlySelectedRowsTitle,
                command: .showOnlySelectedRows,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
        ]
    }

    private static func columnVisibilityItems(
        capability: GenotypeMatrixVisibilityCapabilitySnapshot
    ) -> [GenotypeMatrixContextMenuItemState] {
        guard capability.canHideSelectedColumns else { return [] }
        return [
            .init(
                title: capability.hideSelectedColumnsTitle,
                command: .hideSelectedColumns,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
            .init(
                title: capability.showOnlySelectedColumnsTitle,
                command: .showOnlySelectedColumns,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
        ]
    }

    private static func commentMenuTitle(
        capability: GenotypeMatrixReviewCapabilityState,
        targetCount: Int
    ) -> String {
        switch capability.commentState {
        case .none:
            return "Add Comment…"
        case .uniform:
            return targetCount == 1 ? "Edit Comment…" : "Replace Comments…"
        case .mixed:
            return "Replace Comments…"
        }
    }
}

public enum GenotypeMatrixStyleField: Equatable {
    case fillColor(AnnotationColor?)
    case textColor(AnnotationColor?)
    case borderColor(AnnotationColor?)
    case isBold(Bool)
    case isItalic(Bool)
    case clear
}

public struct GenotypeMatrixStyleRequest: Equatable {
    public let targets: [GenotypeAnnotationSidecar.MatrixTarget]
    public let field: GenotypeMatrixStyleField
    public let minimumReads: Int?

    public init(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        field: GenotypeMatrixStyleField,
        minimumReads: Int? = nil
    ) {
        self.targets = targets
        self.field = field
        self.minimumReads = minimumReads
    }
}

public struct GenotypeMatrixReviewRequest: Equatable, Sendable {
    public enum Intent: Equatable, Sendable {
        case set(GenotypeAnnotationSidecar.MatrixReviewDisposition)
        case clear
    }

    public let targets: [GenotypeAnnotationSidecar.MatrixTarget]
    public let intent: Intent

    public init(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        intent: Intent
    ) {
        self.targets = targets
        self.intent = intent
    }
}

public struct GenotypeMatrixCommentEditRequest: Equatable, Sendable {
    public enum Intent: Equatable, Sendable {
        case upsert(body: String)
        case remove
        case replace(body: String)
    }

    public let targets: [GenotypeAnnotationSidecar.MatrixTarget]
    public let intent: Intent

    public init(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        intent: Intent
    ) {
        self.targets = targets
        self.intent = intent
    }

    /// Compatibility initializer for pre-semantic call sites. It now means an
    /// exact target-keyed upsert, never an append.
    public init(
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        body: String
    ) {
        self.init(targets: targets, intent: .upsert(body: body))
    }

    public var body: String {
        switch intent {
        case let .upsert(body), let .replace(body):
            return body
        case .remove:
            return ""
        }
    }
}

public enum GenotypeMatrixCommentScope: String, CaseIterable, Equatable, Identifiable, Sendable {
    case cell
    case alleleRow
    case sampleColumn

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cell:
            return "Cell"
        case .alleleRow:
            return "Allele Row"
        case .sampleColumn:
            return "Sample Column"
        }
    }

}

public struct GenotypeMatrixCommentCardState: Equatable, Sendable {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    public typealias Comment = GenotypeAnnotationSidecar.MatrixComment

    public let scope: GenotypeMatrixCommentScope
    public let targets: [Target]
    public let valueState: GenotypeMatrixValueState<String>
    public let currentComments: [Comment]

    public var targetCount: Int { targets.count }
    public var currentComment: Comment? {
        currentComments.count == 1 ? currentComments[0] : nil
    }

    public var authorState: GenotypeMatrixValueState<String> {
        Self.valueState(currentComments.map(\.author))
    }

    public var timestampState: GenotypeMatrixValueState<String> {
        Self.valueState(currentComments.map(\.timestamp))
    }

    public var metadataSummary: String {
        guard !currentComments.isEmpty else { return "" }
        return "\(Self.metadataValue(authorState, mixed: "Multiple authors"))"
            + " · \(Self.metadataValue(timestampState, mixed: "Multiple timestamps"))"
    }

    public var displayBody: String {
        guard case let .uniform(body) = valueState else { return "" }
        return body
    }

    public var currentValueSummary: String {
        switch valueState {
        case .none:
            return "No comment"
        case .uniform:
            return targetCount == 1 ? "Current comment" : "\(targetCount) comments"
        case .mixed:
            return "Multiple comments"
        }
    }

    public var requiresExplicitReplace: Bool {
        targetCount > 1 && valueState != .none
    }

    public var actionTitle: String {
        if requiresExplicitReplace {
            return "Replace Comments on \(targetCount) Targets"
        }
        switch valueState {
        case .none:
            return "Add Comment"
        case .uniform, .mixed:
            return "Save Changes"
        }
    }

    public var hasAnyComment: Bool {
        !currentComments.isEmpty
    }

    private static func valueState(
        _ values: [String]
    ) -> GenotypeMatrixValueState<String> {
        guard let first = values.first else { return .none }
        guard values.dropFirst().allSatisfy({ $0 == first }) else { return .mixed }
        return .uniform(first)
    }

    private static func metadataValue(
        _ state: GenotypeMatrixValueState<String>,
        mixed: String
    ) -> String {
        switch state {
        case .none:
            return ""
        case let .uniform(value):
            return value
        case .mixed:
            return mixed
        }
    }
}

public enum GenotypeMatrixAnnotationCommandError: Error, Equatable, LocalizedError {
    case explicitBulkCommentReplaceRequired

    public var errorDescription: String? {
        switch self {
        case .explicitBulkCommentReplaceRequired:
            return "Replacing existing comments on multiple targets requires explicit replace intent."
        }
    }
}

@available(*, deprecated, renamed: "GenotypeMatrixCommentEditRequest")
public typealias GenotypeMatrixCommentRequest = GenotypeMatrixCommentEditRequest

public struct GenotypeResultHighlightTarget: Equatable, Hashable {
    public let genotype: String
    public let locus: String
    public let sample: String?
    public let stableClusterID: String?

    public init(
        genotype: String,
        locus: String,
        sample: String? = nil,
        stableClusterID: String? = nil
    ) {
        self.genotype = genotype
        self.locus = locus
        self.sample = sample
        self.stableClusterID = stableClusterID
    }

    public var displayScope: String {
        sample == nil ? "Genotype Row" : "Sample Cell"
    }
}

public enum GenotypeResultHighlightScope: String, CaseIterable, Equatable {
    case selectedCell
    case selectedRow
    case clear

    public var displayName: String {
        switch self {
        case .selectedCell:
            return "Selected Cell"
        case .selectedRow:
            return "Selected Genotype Row"
        case .clear:
            return "Clear Highlight"
        }
    }
}

public enum GenotypeResultHighlightChannel: String, CaseIterable, Equatable {
    case fill
    case border

    public var displayName: String {
        switch self {
        case .fill:
            return "Fill"
        case .border:
            return "Border"
        }
    }
}

public struct GenotypeResultHighlightStyle: Equatable, Hashable, Sendable {
    public var fillColor: AnnotationColor?
    public var borderColor: AnnotationColor?

    public static let `default` = GenotypeResultHighlightStyle()

    public init(fillColor: AnnotationColor? = nil, borderColor: AnnotationColor? = nil) {
        self.fillColor = fillColor
        self.borderColor = borderColor
    }

    public var isDefault: Bool {
        fillColor == nil && borderColor == nil
    }

    public func color(for channel: GenotypeResultHighlightChannel) -> AnnotationColor? {
        switch channel {
        case .fill:
            return fillColor
        case .border:
            return borderColor
        }
    }

    public mutating func setColor(_ color: AnnotationColor?, for channel: GenotypeResultHighlightChannel) {
        switch channel {
        case .fill:
            fillColor = color
        case .border:
            borderColor = color
        }
    }
}

public struct GenotypeResultHighlightRequest: Equatable {
    public let target: GenotypeResultHighlightTarget
    public let scope: GenotypeResultHighlightScope
    public let channel: GenotypeResultHighlightChannel
    public let color: AnnotationColor?

    public init(
        target: GenotypeResultHighlightTarget,
        scope: GenotypeResultHighlightScope,
        channel: GenotypeResultHighlightChannel = .fill,
        color: AnnotationColor?
    ) {
        self.target = target
        self.scope = scope
        self.channel = channel
        self.color = color
    }
}
