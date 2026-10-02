import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeSharedCall: Codable, Equatable, Sendable {
    public let locus: String
    public let genotype: String
    public let sampleSupport: [ONTGenotypeSampleSupport]

    public init(locus: String, genotype: String, sampleSupport: [ONTGenotypeSampleSupport]) {
        self.locus = locus
        self.genotype = genotype
        self.sampleSupport = sampleSupport.sorted {
            if $0.passedUniqueReads != $1.passedUniqueReads {
                return $0.passedUniqueReads > $1.passedUniqueReads
            }
            if $0.passedAlignments != $1.passedAlignments {
                return $0.passedAlignments > $1.passedAlignments
            }
            return $0.sample.localizedStandardCompare($1.sample) == .orderedAscending
        }
    }

    public var sampleCount: Int {
        sampleSupport.count
    }

    public var totalAlignments: Int {
        sampleSupport.reduce(0) { $0 + $1.passedAlignments }
    }

    public var totalUniqueReads: Int {
        sampleSupport.reduce(0) { $0 + $1.passedUniqueReads }
    }

    public var topSupport: ONTGenotypeSampleSupport? {
        sampleSupport.first
    }

    public var aliasDisplay: String? {
        guard let pipeIndex = genotype.firstIndex(of: "|") else { return nil }
        let aliases = genotype[genotype.index(after: pipeIndex)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return aliases.isEmpty ? nil : aliases.joined(separator: ", ")
    }

    public func support(for sample: String) -> ONTGenotypeSampleSupport? {
        sampleSupport.first { $0.sample == sample }
    }
}
