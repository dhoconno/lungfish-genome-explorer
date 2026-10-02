import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeLocusSummary: Codable, Equatable, Sendable {
    public let locus: String
    public let sharedCalls: [ONTGenotypeSharedCall]

    public init(locus: String, sharedCalls: [ONTGenotypeSharedCall]) {
        self.locus = locus
        self.sharedCalls = sharedCalls.sorted {
            if $0.sampleCount != $1.sampleCount {
                return $0.sampleCount > $1.sampleCount
            }
            if $0.totalUniqueReads != $1.totalUniqueReads {
                return $0.totalUniqueReads > $1.totalUniqueReads
            }
            return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
        }
    }

    public var sampleCount: Int {
        Set(sharedCalls.flatMap { $0.sampleSupport.map(\.sample) }).count
    }

    public var callCount: Int {
        sharedCalls.count
    }

    public var totalUniqueReads: Int {
        sharedCalls.reduce(0) { $0 + $1.totalUniqueReads }
    }
}
