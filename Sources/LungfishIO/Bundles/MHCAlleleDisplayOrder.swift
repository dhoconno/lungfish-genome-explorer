import Foundation

public enum MHCAlleleDisplayOrder {
    /// Compares two MHC allele display names in biological display order.
    /// Natural fields are tokenized into ASCII digit and non-digit runs. Digit runs sort
    /// before non-digit runs and compare by overflow-free numeric magnitude; non-digit
    /// runs compare by ASCII-lowercased Unicode scalar value.
    ///
    /// - Parameters:
    ///   - lhs: The left display name.
    ///   - rhs: The right display name.
    ///   - lhsStableID: A stable identifier used to break display-name ties. Defaults to `""`.
    ///   - rhsStableID: A stable identifier used to break display-name ties. Defaults to `""`.
    public static func compare(
        _ lhs: String,
        _ rhs: String,
        lhsStableID: String = "",
        rhsStableID: String = ""
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
            (left.completeName, right.completeName),
            (lhsStableID, rhsStableID),
        ] {
            let result = naturalCompare(leftValue, rightValue)
            if result != .orderedSame {
                return result
            }
        }

        for (leftValue, rightValue) in [
            (left.completeName, right.completeName),
            (lhsStableID, rhsStableID),
        ] {
            let result = exactCompare(leftValue, rightValue)
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
        let leftTokens = asciiNaturalTokens(lhs)
        let rightTokens = asciiNaturalTokens(rhs)

        for (left, right) in zip(leftTokens, rightTokens) {
            if left.isDigits != right.isDigits {
                return left.isDigits ? .orderedAscending : .orderedDescending
            }
            if left.isDigits, left.values.count != right.values.count {
                return left.values.count < right.values.count ? .orderedAscending : .orderedDescending
            }
            let result = scalarCompare(left.values, right.values)
            if result != .orderedSame {
                return result
            }
        }

        if leftTokens.count != rightTokens.count {
            return leftTokens.count < rightTokens.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func exactCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        scalarCompare(
            lhs.unicodeScalars.map(\.value),
            rhs.unicodeScalars.map(\.value)
        )
    }

    private static func scalarCompare(_ lhs: [UInt32], _ rhs: [UInt32]) -> ComparisonResult {
        if lhs.elementsEqual(rhs) {
            return .orderedSame
        }
        return lhs.lexicographicallyPrecedes(rhs) ? .orderedAscending : .orderedDescending
    }

    private static func asciiNaturalTokens(_ value: String) -> [ASCIINaturalToken] {
        var tokens: [ASCIINaturalToken] = []
        var currentValues: [UInt32] = []
        var currentIsDigits: Bool?

        func appendCurrentToken() {
            guard let isDigits = currentIsDigits else { return }
            let values: [UInt32]
            if isDigits {
                values = Array(currentValues.drop(while: { $0 == 48 }))
            } else {
                values = currentValues
            }
            tokens.append(ASCIINaturalToken(isDigits: isDigits, values: values))
        }

        for scalar in value.unicodeScalars {
            let isDigits = isASCIIDigit(scalar.value)
            if let currentIsDigits, currentIsDigits != isDigits {
                appendCurrentToken()
                currentValues.removeAll(keepingCapacity: true)
            }
            currentIsDigits = isDigits
            currentValues.append(isDigits ? scalar.value : asciiLowercased(scalar.value))
        }
        appendCurrentToken()
        return tokens
    }

    private static func isASCIIDigit(_ value: UInt32) -> Bool {
        value >= 48 && value <= 57
    }

    private static func asciiLowercased(_ value: UInt32) -> UInt32 {
        value >= 65 && value <= 90 ? value + 32 : value
    }

    private struct ASCIINaturalToken {
        let isDigits: Bool
        let values: [UInt32]
    }

    private struct ParsedName {
        let speciesPrefix: String
        let locus: String
        let allele: String
        let completeName: String
        let groupRank: Int

        init(_ name: String) {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speciesPrefix = ""
                locus = ""
                allele = ""
                completeName = ""
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
                completeName = name
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
                completeName = name
                groupRank = 9
                return
            }

            speciesPrefix = parsedSpeciesPrefix
            locus = parsedLocus
            allele = parsedAllele
            completeName = name
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
            let prefixByte = String(prefix).utf8.first
            guard locus.utf8.first == prefixByte else { return false }
            let remainder = locus.utf8.dropFirst()
            let digits = remainder.prefix(while: { $0 >= 48 && $0 <= 57 })
            guard !digits.isEmpty else { return false }

            let suffix = remainder.dropFirst(digits.count)
            return suffix.isEmpty || (allowsLetterSuffix && suffix.allSatisfy {
                ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
            })
        }
    }
}
