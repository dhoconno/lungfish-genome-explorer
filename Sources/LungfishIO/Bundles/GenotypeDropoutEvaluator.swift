import Foundation

public struct GenotypeDropoutEvaluator: Sendable, Equatable {
    public let absolute: Int?
    public let sampleFraction: Double?
    public let locusFraction: Double?

    public init(absolute: Int?, sampleFraction: Double?, locusFraction: Double?) {
        self.absolute = absolute
        self.sampleFraction = sampleFraction
        self.locusFraction = locusFraction
    }

    public func isLowSupport(reads: Int, sampleTotal: Int, locusTotal: Int) -> Bool {
        if let absolute, reads < absolute { return true }
        if let sampleFraction, sampleTotal > 0 {
            if Double(reads) / Double(sampleTotal) < sampleFraction { return true }
        }
        if let locusFraction, locusTotal > 0 {
            if Double(reads) / Double(locusTotal) < locusFraction { return true }
        }
        return false
    }
}
