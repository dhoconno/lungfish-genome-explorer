import Foundation

public enum MHCAlleleDisplayOrder {
    public static func compare(
        _ lhs: String,
        _ rhs: String,
        lhsStableID: String,
        rhsStableID: String
    ) -> ComparisonResult {
        let left = ParsedName(lhs)
        let right = ParsedName(rhs)

        if left.groupRank != right.groupRank {
            return left.groupRank < right.groupRank ? .orderedAscending : .orderedDescending
        }

        for (leftValue, rightValue) in [
            (left.locus, right.locus),
            (left.allele, right.allele),
            (left.speciesPrefix, right.speciesPrefix),
            (lhs, rhs),
            (lhsStableID, rhsStableID),
        ] {
            let result = naturalCompare(leftValue, rightValue)
            if result != .orderedSame {
                return result
            }
        }

        return .orderedSame
    }

    public static func lessThan(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs, lhsStableID: "", rhsStableID: "") == .orderedAscending
    }

    private static func naturalCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .numeric],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private struct ParsedName {
        let speciesPrefix: String
        let locus: String
        let allele: String
        let groupRank: Int

        init(_ name: String) {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speciesPrefix = ""
                locus = ""
                allele = ""
                groupRank = 10
                return
            }

            guard
                let star = name.firstIndex(of: "*"),
                let separator = name[..<star].lastIndex(of: "-")
            else {
                speciesPrefix = ""
                locus = name
                allele = ""
                groupRank = 9
                return
            }

            let parsedSpeciesPrefix = String(name[..<separator])
            let locusStart = name.index(after: separator)
            let parsedLocus = String(name[locusStart..<star])
            let alleleStart = name.index(after: star)
            let parsedAllele = String(name[alleleStart...])

            guard
                !parsedSpeciesPrefix.isEmpty,
                !parsedLocus.isEmpty,
                !parsedAllele.isEmpty
            else {
                speciesPrefix = ""
                locus = name
                allele = ""
                groupRank = 9
                return
            }

            speciesPrefix = parsedSpeciesPrefix
            locus = parsedLocus
            allele = parsedAllele
            groupRank = Self.groupRank(for: parsedLocus)
        }

        private static func groupRank(for locus: String) -> Int {
            if isNumberedLocus(locus, prefix: "A", allowsLetterSuffix: false) { return 0 }
            if locus == "B" { return 1 }
            if isNumberedLocus(locus, prefix: "B", allowsLetterSuffix: true) { return 2 }

            switch locus {
            case "I": return 3
            case "F": return 4
            case "G": return 5
            case "AG": return 6
            case "J": return 7
            case "K": return 8
            default: return 9
            }
        }

        private static func isNumberedLocus(
            _ locus: String,
            prefix: Character,
            allowsLetterSuffix: Bool
        ) -> Bool {
            guard locus.first == prefix else { return false }
            let remainder = locus.dropFirst()
            let digits = remainder.prefix(while: \Character.isNumber)
            guard !digits.isEmpty else { return false }

            let suffix = remainder.dropFirst(digits.count)
            return suffix.isEmpty || (allowsLetterSuffix && suffix.allSatisfy(\.isLetter))
        }
    }
}
