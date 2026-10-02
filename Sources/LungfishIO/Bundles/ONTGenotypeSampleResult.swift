import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeSampleResult: Codable, Equatable, Sendable {
    public let sample: String
    public let passedAlignments: Int
    public let passedUniqueReads: Int
    public let sampleTotalReads: Int?
    public let sampleUniqueRetainedPercent: Double?
    public let calls: [ONTGenotypeCall]

    public init(
        sample: String,
        passedAlignments: Int,
        passedUniqueReads: Int,
        sampleTotalReads: Int?,
        sampleUniqueRetainedPercent: Double?,
        calls: [ONTGenotypeCall]
    ) {
        self.sample = sample
        self.passedAlignments = passedAlignments
        self.passedUniqueReads = passedUniqueReads
        self.sampleTotalReads = sampleTotalReads
        self.sampleUniqueRetainedPercent = sampleUniqueRetainedPercent
        self.calls = calls.sorted {
            if $0.passedAlignments != $1.passedAlignments {
                return $0.passedAlignments > $1.passedAlignments
            }
            return $0.genotype.localizedStandardCompare($1.genotype) == .orderedAscending
        }
    }

    public var callCount: Int {
        calls.count
    }

    public var topCall: ONTGenotypeCall? {
        calls.first
    }

    public var qcStatus: ONTGenotypeQCStatus {
        guard !calls.isEmpty, passedAlignments > 0, passedUniqueReads > 0 else {
            return .review
        }
        if passedAlignments < 20 || passedUniqueReads < 1_000 {
            return .lowSupport
        }
        return .ok
    }
}
