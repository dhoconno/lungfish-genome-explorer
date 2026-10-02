import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeAnchorSummary: Codable, Equatable, Sendable {
    public let label: String
    public let source: ONTGenotypeAnchorSource
    public let loci: [String]
    public let sharedCalls: [ONTGenotypeSharedCall]
    public let sampleSupport: [ONTGenotypeSampleSupport]
    public let caveat: String

    public init(
        label: String,
        source: ONTGenotypeAnchorSource,
        loci: [String],
        sharedCalls: [ONTGenotypeSharedCall],
        sampleSupport: [ONTGenotypeSampleSupport],
        caveat: String = "Anchor groups are derived from source labels and sample-level observation. They are not phased haplotype calls, zygosity calls, copy-number calls, absence calls, or inheritance assertions."
    ) {
        self.label = label
        self.source = source
        self.loci = loci.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.sharedCalls = sharedCalls.sorted {
            if $0.locus != $1.locus {
                return $0.locus.localizedStandardCompare($1.locus) == .orderedAscending
            }
            if $0.sampleCount != $1.sampleCount {
                return $0.sampleCount > $1.sampleCount
            }
            return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
        }
        self.sampleSupport = sampleSupport.sorted {
            if $0.passedUniqueReads != $1.passedUniqueReads {
                return $0.passedUniqueReads > $1.passedUniqueReads
            }
            return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
        }
        self.caveat = caveat
    }

    public var sampleCount: Int {
        sampleSupport.count
    }

    public var totalUniqueReads: Int {
        sharedCalls.reduce(0) { $0 + $1.totalUniqueReads }
    }
}
