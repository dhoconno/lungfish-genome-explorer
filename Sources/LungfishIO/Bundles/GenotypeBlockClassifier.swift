import Foundation
import LungfishCore

public enum GenotypeBlockKind: String, Codable, Sendable {
    case blockCoherent
    case regionalRecombinant
    case atypical
    case unknown
}

public enum GenotypeBlockClassifier {
    public static func classify(
        calls: [(locus: String, h1: String, h2: String)]
    ) -> GenotypeBlockKind {
        guard !calls.isEmpty else { return .unknown }
        var h1Numbers = Set<Int>()
        var h2Numbers = Set<Int>()
        var recombinantLoci = 0
        for c in calls {
            if c.h1.hasPrefix("rec") || c.h2.hasPrefix("rec") {
                recombinantLoci += 1
            }
            if let h1 = mNumber(c.h1) { h1Numbers.insert(h1) }
            if let h2 = mNumber(c.h2) { h2Numbers.insert(h2) }
        }

        let h1Coherent = h1Numbers.count <= 1
        let h2Coherent = h2Numbers.count <= 1

        if recombinantLoci > 0 && h1Coherent && h2Coherent {
            return .regionalRecombinant
        }
        if h1Coherent && h2Coherent {
            return .blockCoherent
        }
        return .atypical
    }

    private static func mNumber(_ name: String) -> Int? {
        guard !name.isEmpty, name.first == "M" else { return nil }
        let chars = name.dropFirst()
        var digits = ""
        for ch in chars {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits)
    }
}
