import Foundation
import LungfishCore
import LungfishIO

enum GenotypeResultPanelLayout: String, CaseIterable, Equatable {
    case listLeading
    case listTrailing
    case listTop

    var displayName: String {
        switch self {
        case .listLeading:
            return "List Left"
        case .listTrailing:
            return "List Right"
        case .listTop:
            return "List Top"
        }
    }

    var inspectorLabel: String {
        switch self {
        case .listTrailing:
            return "Detail | List"
        case .listLeading:
            return "List | Detail"
        case .listTop:
            return "List Over Detail"
        }
    }

    var inspectorSystemImage: String {
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

enum GenotypeResultViewportLens: String, CaseIterable, Equatable {
    case summary
    case review
    case audit

    var displayName: String {
        switch self {
        case .summary: return "Summary"
        case .review:  return "Review"
        case .audit:   return "Audit"
        }
    }

    var inspectorSystemImage: String {
        switch self {
        case .summary: return "tablecells"
        case .review:  return "checklist"
        case .audit:   return "doc.text.magnifyingglass"
        }
    }

    var identifier: String {
        rawValue
    }
}

enum GenotypeSummaryViewMode: String, CaseIterable, Equatable {
    case outline
    case matrix

    var displayName: String {
        switch self {
        case .outline: return "Outline"
        case .matrix:  return "Matrix"
        }
    }
}

enum GenotypeResultCellColorMode: String, CaseIterable, Equatable {
    case support
    case highlights
    case none

    var displayName: String {
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

struct GenotypeResultDisplayState: Equatable {
    var viewportLens: GenotypeResultViewportLens = .summary
    var summaryViewMode: GenotypeSummaryViewMode = .outline
    var layout: GenotypeResultPanelLayout = .listTop
    var hideLowSupport: Bool = true
    var minimumSupportPercent: Double = 1.0
    var supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus
    var cellColorMode: GenotypeResultCellColorMode = .support
    var hideFilteredHighlights: Bool = true
    /// When true, the Outline / Matrix views include observed loci
    /// that the active haplotype definition set does NOT cover. When false
    /// (the default), only the definition-set loci appear so the tape stays
    /// focused on the calls actually being haplotyped. For MCM that means
    /// the canonical 7 loci instead of every locus the demux observed.
    var showsAncillaryLoci: Bool = false

    /// Editable row-visibility filter: samples with fewer than this many
    /// `passedUniqueReads` may be hidden from the result rows. `0` (the
    /// default) disables the filter. This is a SEPARATE concern from the
    /// cohort flag below and must never alias it.
    var minimumReads: Int = 0

    /// The historical "calls below this are unreliable" cohort flag (default
    /// `5_000`). It LABELS samples in the Cohort Summary panel; it does not
    /// hide rows. Previously hardcoded in the view controller, now editable.
    var cohortFlagThreshold: Int = 5_000

    init(
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

    var activeMinimumSupportPercent: Double {
        hideLowSupport ? minimumSupportPercent : 0
    }

    /// The effective row-visibility threshold. `0` means no row filtering.
    var activeMinimumReads: Int {
        MinimumReadsThreshold(value: minimumReads).active
    }

    /// Sample IDs hidden by the editable row-visibility filter, sorted.
    /// Returns an empty array when the filter is off (`activeMinimumReads == 0`).
    func samplesBelowFilter(_ reads: [(sample: String, reads: Int)]) -> [String] {
        let threshold = activeMinimumReads
        guard threshold > 0 else { return [] }
        return reads
            .filter { $0.reads < threshold }
            .map(\.sample)
            .sorted()
    }

    /// Sample IDs flagged as unreliable by the cohort flag, sorted.
    func samplesBelowCohortFlag(_ reads: [(sample: String, reads: Int)]) -> [String] {
        reads
            .filter { $0.reads < cohortFlagThreshold }
            .map(\.sample)
            .sorted()
    }
}

struct GenotypeResultHighlightTarget: Equatable, Hashable {
    let genotype: String
    let locus: String
    let sample: String?

    init(genotype: String, locus: String, sample: String? = nil) {
        self.genotype = genotype
        self.locus = locus
        self.sample = sample
    }

    var displayScope: String {
        sample == nil ? "Genotype Row" : "Sample Cell"
    }
}

enum GenotypeResultHighlightScope: String, CaseIterable, Equatable {
    case selectedCell
    case selectedRow
    case clear

    var displayName: String {
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

enum GenotypeResultHighlightChannel: String, CaseIterable, Equatable {
    case fill
    case border

    var displayName: String {
        switch self {
        case .fill:
            return "Fill"
        case .border:
            return "Border"
        }
    }
}

struct GenotypeResultHighlightStyle: Equatable, Hashable {
    var fillColor: AnnotationColor?
    var borderColor: AnnotationColor?

    static let `default` = GenotypeResultHighlightStyle()

    init(fillColor: AnnotationColor? = nil, borderColor: AnnotationColor? = nil) {
        self.fillColor = fillColor
        self.borderColor = borderColor
    }

    var isDefault: Bool {
        fillColor == nil && borderColor == nil
    }

    func color(for channel: GenotypeResultHighlightChannel) -> AnnotationColor? {
        switch channel {
        case .fill:
            return fillColor
        case .border:
            return borderColor
        }
    }

    mutating func setColor(_ color: AnnotationColor?, for channel: GenotypeResultHighlightChannel) {
        switch channel {
        case .fill:
            fillColor = color
        case .border:
            borderColor = color
        }
    }
}

struct GenotypeResultHighlightRequest: Equatable {
    let target: GenotypeResultHighlightTarget
    let scope: GenotypeResultHighlightScope
    let channel: GenotypeResultHighlightChannel
    let color: AnnotationColor?

    init(
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
