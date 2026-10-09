import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeResultDisplayState: Equatable {
    public var viewportLens: GenotypeResultViewportLens = .summary
    public var summaryViewMode: GenotypeSummaryViewMode = .outline
    public var layout: GenotypeResultPanelLayout = .listTop
    public var hideLowSupport: Bool = false
    public var minimumSupportPercent: Double = 0
    public var supportDenominator: ONTGenotypeSupportDenominator = .viewedLocus
    public var cellColorMode: GenotypeResultCellColorMode = .support
    /// Show only observed alleles used by the active haplotype definitions.
    public var diagnosticAllelesOnly: Bool = false
    public var hideFilteredHighlights: Bool = true
    /// When true, the Outline / Matrix views include observed loci
    /// that the active haplotype definition set does NOT cover. When false
    /// (the default), only the definition-set loci appear so the tape stays
    /// focused on the calls actually being haplotyped. For MCM that means
    /// the canonical 7 loci instead of every locus the demux observed.
    public var showsAncillaryLoci: Bool = false
    /// Loci selected for the deterministic haplotype Outline. `nil` means use the
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
    /// "Seen in at least N% of animals": a prevalence
    /// filter over the logical sample roster, separate from the per-sample
    /// read fraction `matrixMinimumPercent`. `0` (the default) is off.
    public var matrixMinimumPrevalencePercent: Double = 0
    public var matrixRowFilterText: String = ""
    public var matrixSampleFilterText: String = ""
    /// Whether the manual haplotype summary band below matrix sample headers
    /// is expanded. This presentation-only value defaults to collapsed and is
    /// restored only from an existing window-owned, bundle-keyed entry.
    public var manualHaplotypeBandExpanded: Bool = false
    /// Optional live override for the bundle-scoped candidate viewport settings.
    /// `nil` preserves the settings loaded from this result bundle's annotation
    /// sidecar. Full-length MHC controls use this while an edit is being applied.
    public var mhcCandidateDisplaySettings: ONTMHCCandidateDisplaySettings? = nil
    /// Display-only order override. Nil uses the result bundle's portable default.
    public var genotypeLocusDisplayOrder: [String]? = nil

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
        diagnosticAllelesOnly: Bool = false,
        hideFilteredHighlights: Bool = true,
        showsAncillaryLoci: Bool = false,
        includedLoci: Set<String>? = nil,
        minimumReads: Int = 0,
        matrixMinimumReads: Int = 0,
        matrixMinimumPercent: Double = 0,
        matrixPercentDenominator: ONTGenotypeSupportDenominator = .viewedLocus,
        matrixMinimumPrevalencePercent: Double = 0,
        matrixRowFilterText: String = "",
        matrixSampleFilterText: String = "",
        manualHaplotypeBandExpanded: Bool = false,
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
        self.diagnosticAllelesOnly = diagnosticAllelesOnly
        self.hideFilteredHighlights = hideFilteredHighlights
        self.showsAncillaryLoci = showsAncillaryLoci
        self.includedLoci = includedLoci
        self.minimumReads = minimumReads
        self.matrixMinimumReads = max(0, matrixMinimumReads)
        self.matrixMinimumPercent = max(0, min(100, matrixMinimumPercent))
        self.matrixPercentDenominator = matrixPercentDenominator
        self.matrixMinimumPrevalencePercent = max(0, min(100, matrixMinimumPrevalencePercent))
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
        normalized.viewportLens = .summary
        normalized.summaryViewMode = .matrix
        normalized.layout = .listTop
        return normalized
    }

    /// Applies the result-scoped presentation rules without changing the raw
    /// persisted `outline` and `matrix` values used by existing bundles.
    public func normalized(
        using presentationPolicy: GenotypeResultPresentationPolicy
    ) -> Self {
        presentationPolicy.normalize(displayState: self)
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
        replaced.diagnosticAllelesOnly = source.diagnosticAllelesOnly
        replaced.hideFilteredHighlights = source.hideFilteredHighlights
        replaced.minimumReads = source.minimumReads
        replaced.matrixMinimumReads = source.matrixMinimumReads
        replaced.matrixMinimumPercent = source.matrixMinimumPercent
        replaced.matrixPercentDenominator = source.matrixPercentDenominator
        replaced.matrixMinimumPrevalencePercent = source.matrixMinimumPrevalencePercent
        replaced.matrixRowFilterText = source.matrixRowFilterText
        replaced.matrixSampleFilterText = source.matrixSampleFilterText
        replaced.manualHaplotypeBandExpanded =
            source.manualHaplotypeBandExpanded
        replaced.mhcCandidateDisplaySettings = source.mhcCandidateDisplaySettings
        replaced.genotypeLocusDisplayOrder = source.genotypeLocusDisplayOrder
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
            || matrixMinimumPrevalencePercent != previous.matrixMinimumPrevalencePercent
    }

    func requiresMatrixFilterPass(comparedTo previous: GenotypeResultDisplayState) -> Bool {
        requiresMatrixDerivedProjection(comparedTo: previous)
            || diagnosticAllelesOnly != previous.diagnosticAllelesOnly
            || minimumReads != previous.minimumReads
            || matrixRowFilterText != previous.matrixRowFilterText
            || matrixSampleFilterText != previous.matrixSampleFilterText
            || genotypeLocusDisplayOrder != previous.genotypeLocusDisplayOrder
    }

    func requiresMatrixRedraw(comparedTo previous: GenotypeResultDisplayState) -> Bool {
        cellColorMode != previous.cellColorMode
            || hideFilteredHighlights != previous.hideFilteredHighlights
    }
}
