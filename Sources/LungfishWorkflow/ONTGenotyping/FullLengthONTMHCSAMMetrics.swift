import Foundation

enum FullLengthONTMHCSAMMetricsError: Error, Equatable, Sendable {
    case emptyCIGAR
    case missingOperationLength(operator: Character)
    case invalidOperationLength(String)
    case zeroOperationLength(operator: Character)
    case trailingOperationLength(String)
    case unsupportedOperator(Character)
    case missingNMForAmbiguousMatch
    case negativeNM(Int)
    case nmSmallerThanExplicitDifferences(nm: Int, explicitDifferences: Int)
    case nmMismatchCountExceedsAmbiguousMatches(mismatchCount: Int, ambiguousMatchBases: Int)
}

struct FullLengthONTMHCSAMMetrics: Equatable, Sendable {
    let matches: Int
    let snps: Int
    let insertedBases: Int
    let deletedBases: Int
    let skippedReferenceBases: Int
    let softClippedBases: Int

    var comparableBases: Int { matches + snps }
    var nonIntronIndelBases: Int { insertedBases + deletedBases }
    var referenceSpan: Int { matches + snps + deletedBases + skippedReferenceBases }
    var querySpan: Int { matches + snps + insertedBases + softClippedBases }

    init(cigar: String, nm: Int?) throws {
        guard !cigar.isEmpty else {
            throw FullLengthONTMHCSAMMetricsError.emptyCIGAR
        }

        var explicitMatches = 0
        var explicitSubstitutions = 0
        var ambiguousMatchBases = 0
        var insertedBases = 0
        var deletedBases = 0
        var skippedReferenceBases = 0
        var softClippedBases = 0
        var lengthText = ""

        for character in cigar {
            if character >= "0" && character <= "9" {
                lengthText.append(character)
                continue
            }

            guard !lengthText.isEmpty else {
                throw FullLengthONTMHCSAMMetricsError.missingOperationLength(operator: character)
            }
            guard let length = Int(lengthText) else {
                throw FullLengthONTMHCSAMMetricsError.invalidOperationLength(lengthText)
            }
            guard length > 0 else {
                throw FullLengthONTMHCSAMMetricsError.zeroOperationLength(operator: character)
            }

            switch character {
            case "=": explicitMatches += length
            case "X": explicitSubstitutions += length
            case "M": ambiguousMatchBases += length
            case "I": insertedBases += length
            case "D": deletedBases += length
            case "N": skippedReferenceBases += length
            case "S": softClippedBases += length
            default:
                throw FullLengthONTMHCSAMMetricsError.unsupportedOperator(character)
            }
            lengthText = ""
        }

        guard lengthText.isEmpty else {
            throw FullLengthONTMHCSAMMetricsError.trailingOperationLength(lengthText)
        }

        let ambiguousSubstitutions: Int
        if ambiguousMatchBases > 0 {
            guard let nm else {
                throw FullLengthONTMHCSAMMetricsError.missingNMForAmbiguousMatch
            }
            guard nm >= 0 else {
                throw FullLengthONTMHCSAMMetricsError.negativeNM(nm)
            }
            let explicitDifferences = insertedBases + deletedBases + explicitSubstitutions
            guard nm >= explicitDifferences else {
                throw FullLengthONTMHCSAMMetricsError.nmSmallerThanExplicitDifferences(
                    nm: nm,
                    explicitDifferences: explicitDifferences
                )
            }
            ambiguousSubstitutions = nm - explicitDifferences
            guard ambiguousSubstitutions <= ambiguousMatchBases else {
                throw FullLengthONTMHCSAMMetricsError.nmMismatchCountExceedsAmbiguousMatches(
                    mismatchCount: ambiguousSubstitutions,
                    ambiguousMatchBases: ambiguousMatchBases
                )
            }
        } else {
            ambiguousSubstitutions = 0
        }

        self.matches = explicitMatches + ambiguousMatchBases - ambiguousSubstitutions
        self.snps = explicitSubstitutions + ambiguousSubstitutions
        self.insertedBases = insertedBases
        self.deletedBases = deletedBases
        self.skippedReferenceBases = skippedReferenceBases
        self.softClippedBases = softClippedBases
    }
}
