import Foundation
import LungfishIO

/// The result-scoped policy that owns presentation selection for completed
/// genotype-result bundles. It deliberately preserves the persisted
/// `outline` and `matrix` raw values used by existing bundles.
public struct GenotypeResultPresentationPolicy: Equatable, Sendable {
    public enum Choice: Equatable, Sendable {
        case haplotypeCalls
        case genotypeMatrix

        public var summaryViewMode: GenotypeSummaryViewMode {
            switch self {
            case .haplotypeCalls: return .outline
            case .genotypeMatrix: return .matrix
            }
        }

        public var displayName: String {
            switch self {
            case .haplotypeCalls: return "Haplotype Calls"
            case .genotypeMatrix: return "Genotype Matrix"
            }
        }
    }

    public enum PersistencePolicy: Equatable, Sendable {
        /// The selected mode may be saved in the bundle annotation sidecar.
        case bundle
        /// The selected mode changes this controller's state only.
        case sessionOnly
        /// A fallback may be shown, but it must not replace a saved preference.
        case preserveStoredPreference
    }

    private let isTypedHaplotypedMiSeq: Bool
    private let isGenotypeOnlyResult: Bool
    private let hasNativeGenotypeMatrixContent: Bool
    private let hasHaplotypeAnalysis: Bool
    private let hasUsableHaplotypeAnalysis: Bool
    private let isReadOnly: Bool

    public init(
        legacyBundleKind: String? = nil,
        legacyWorkflowDeclarationsAbsent: Bool = false,
        workflowKind: GenotypeResultWorkflowKind?,
        workflowMode: GenotypeResultWorkflowMode?,
        manualHaplotypeEligibility: GenotypeManualHaplotypeEligibility,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        hasNativeGenotypeMatrixContent: Bool,
        isReadOnly: Bool
    ) {
        isTypedHaplotypedMiSeq = GenotypeEffectiveCallAuthority.isIdentityBoundMiSeqShape(
            legacyBundleKind: legacyBundleKind, legacyWorkflowDeclarationsAbsent: legacyWorkflowDeclarationsAbsent,
            workflowKind: workflowKind, workflowMode: workflowMode, analysis: haplotypeAnalysis)
        if case .eligible = manualHaplotypeEligibility {
            isGenotypeOnlyResult = true
        } else {
            isGenotypeOnlyResult = false
        }
        self.hasNativeGenotypeMatrixContent = hasNativeGenotypeMatrixContent
        hasHaplotypeAnalysis = haplotypeAnalysis != nil
        hasUsableHaplotypeAnalysis = Self.isUsable(haplotypeAnalysis)
        self.isReadOnly = isReadOnly
    }

    /// Legacy compatibility is allowed only when both workflow declarations
    /// are genuinely absent. Unsupported future strings, JSON nulls, and
    /// malformed values intentionally fail closed instead of decoding to the
    /// same `nil` values as a missing declaration.
    public static func workflowDeclarationsAreAbsent(
        in manifest: ONTGenotypeResultBundleManifest
    ) -> Bool {
        GenotypeEffectiveCallAuthority.workflowDeclarationsAreAbsent(in: manifest)
    }

    /// True only for the typed, haplotyped miSeq result shape with an analysis
    /// that can supply unambiguous sample/locus calls.
    public var appliesToHaplotypedMiSeq: Bool {
        isTypedHaplotypedMiSeq && !isGenotypeOnlyResult && hasUsableHaplotypeAnalysis
    }

    /// The selector choices provided by this policy. Empty means the existing
    /// workflow-specific viewport policy remains in charge.
    public var choices: [Choice] {
        if appliesToHaplotypedMiSeq {
            return [.haplotypeCalls, .genotypeMatrix]
        }
        if isGenotypeOnlyResult {
            return [.genotypeMatrix]
        }
        return []
    }

    public var defaultSummaryViewMode: GenotypeSummaryViewMode {
        if appliesToHaplotypedMiSeq {
            return .outline
        }
        if usesMalformedHaplotypedMiSeqFallback || isGenotypeOnlyResult {
            return .matrix
        }
        if hasHaplotypeAnalysis {
            return .outline
        }
        return hasNativeGenotypeMatrixContent ? .matrix : .outline
    }

    /// Empty and structurally malformed haplotype analyses fall back to the
    /// matrix without mutating the bundle's saved `outline`/`matrix` value.
    public var haplotypeCallsUnavailableExplanation: String? {
        guard usesMalformedHaplotypedMiSeqFallback else { return nil }
        return "Haplotype Calls is unavailable because the saved haplotype analysis is empty or malformed. Showing Genotype Matrix instead."
    }

    public var persistencePolicy: PersistencePolicy {
        if usesMalformedHaplotypedMiSeqFallback {
            return .preserveStoredPreference
        }
        return isReadOnly ? .sessionOnly : .bundle
    }

    public var viewportAccessibilityHelp: String {
        accessibilityHelp(prefix: "View presentation")
    }

    public var inspectorAccessibilityHelp: String {
        accessibilityHelp(prefix: "Inspector view presentation")
    }

    /// Converts stale presentation ingress to the one state owned by this
    /// policy. It does not touch legacy lenses outside typed miSeq results.
    public func normalize(
        displayState: GenotypeResultDisplayState
    ) -> GenotypeResultDisplayState {
        var normalized = displayState
        if appliesToHaplotypedMiSeq {
            if normalized.viewportLens != .summary {
                normalized.summaryViewMode = .outline
            }
            normalized.viewportLens = .summary
            return normalized
        }
        if usesMalformedHaplotypedMiSeqFallback {
            normalized.viewportLens = .summary
            normalized.summaryViewMode = .matrix
            return normalized
        }
        if isGenotypeOnlyResult {
            return normalized.normalized(forGenotypeOnlyResult: true)
        }
        return normalized
    }

    public static func isUsable(_ analysis: GenotypeHaplotypeAnalysis?) -> Bool {
        GenotypeEffectiveCallAuthority.hasUsableAnalysis(analysis)
    }

    private var usesMalformedHaplotypedMiSeqFallback: Bool {
        isTypedHaplotypedMiSeq && !isGenotypeOnlyResult && !hasUsableHaplotypeAnalysis
    }

    private func accessibilityHelp(prefix: String) -> String {
        if appliesToHaplotypedMiSeq {
            let persistence = isReadOnly
                ? " Changes apply for this session only because this bundle is read-only."
                : ""
            return "\(prefix). Choose Haplotype Calls or Genotype Matrix.\(persistence)"
        }
        if let explanation = haplotypeCallsUnavailableExplanation {
            return "\(prefix). \(explanation)"
        }
        return "\(prefix)."
    }

}
