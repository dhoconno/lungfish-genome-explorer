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
    public var hideLowSupport: Bool = true
    public var minimumSupportPercent: Double = 1.0
    public var supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus
    public var cellColorMode: GenotypeResultCellColorMode = .support
    public var hideFilteredHighlights: Bool = true
    /// When true, the Outline / Matrix views include observed loci
    /// that the active haplotype definition set does NOT cover. When false
    /// (the default), only the definition-set loci appear so the tape stays
    /// focused on the calls actually being haplotyped. For MCM that means
    /// the canonical 7 loci instead of every locus the demux observed.
    public var showsAncillaryLoci: Bool = false

    /// Editable row-visibility filter: samples with fewer than this many
    /// `passedUniqueReads` may be hidden from the result rows. `0` (the
    /// default) disables the filter. This is a SEPARATE concern from the
    /// cohort flag below and must never alias it.
    public var minimumReads: Int = 0

    /// The historical "calls below this are unreliable" cohort flag (default
    /// `5_000`). It LABELS samples in the Cohort Summary panel; it does not
    /// hide rows. Previously hardcoded in the view controller, now editable.
    public var cohortFlagThreshold: Int = 5_000

    public init(
        viewportLens: GenotypeResultViewportLens = .summary,
        summaryViewMode: GenotypeSummaryViewMode = .outline,
        layout: GenotypeResultPanelLayout = .listTop,
        hideLowSupport: Bool = true,
        minimumSupportPercent: Double = 1.0,
        supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
        cellColorMode: GenotypeResultCellColorMode = .support,
        hideFilteredHighlights: Bool = true,
        showsAncillaryLoci: Bool = false,
        minimumReads: Int = 0,
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
        self.minimumReads = minimumReads
        self.cohortFlagThreshold = cohortFlagThreshold
    }

    public var activeMinimumSupportPercent: Double {
        hideLowSupport ? minimumSupportPercent : 0
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

public struct GenotypeResultHighlightTarget: Equatable, Hashable {
    public let genotype: String
    public let locus: String
    public let sample: String?

    public init(genotype: String, locus: String, sample: String? = nil) {
        self.genotype = genotype
        self.locus = locus
        self.sample = sample
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
