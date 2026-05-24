import Foundation

public struct GenotypeDropoutEvaluator: Sendable, Equatable {
    public let absolute: Int?
    public let sampleFraction: Double?
    public let locusFraction: Double?
    /// Optional per-locus overrides for `locusFraction`. When present, the
    /// override for the call's locus replaces the global `locusFraction`.
    /// Empty/`nil` map means every locus uses the global threshold.
    public let locusFractionOverrides: [String: Double]

    public init(
        absolute: Int?,
        sampleFraction: Double?,
        locusFraction: Double?,
        locusFractionOverrides: [String: Double] = [:]
    ) {
        self.absolute = absolute
        self.sampleFraction = sampleFraction
        self.locusFraction = locusFraction
        self.locusFractionOverrides = locusFractionOverrides
    }

    /// Resolve the effective locus-fraction threshold for a given locus,
    /// honouring per-locus overrides.
    public func effectiveLocusFraction(forLocus locus: String?) -> Double? {
        if let locus, let override = locusFractionOverrides[locus] {
            return override
        }
        return locusFraction
    }

    public func isLowSupport(reads: Int, sampleTotal: Int, locusTotal: Int) -> Bool {
        isLowSupport(reads: reads, sampleTotal: sampleTotal, locusTotal: locusTotal, locus: nil)
    }

    public func isLowSupport(
        reads: Int,
        sampleTotal: Int,
        locusTotal: Int,
        locus: String?
    ) -> Bool {
        if let absolute, reads < absolute { return true }
        if let sampleFraction, sampleTotal > 0 {
            if Double(reads) / Double(sampleTotal) < sampleFraction { return true }
        }
        if let lf = effectiveLocusFraction(forLocus: locus), locusTotal > 0 {
            if Double(reads) / Double(locusTotal) < lf { return true }
        }
        return false
    }
}
