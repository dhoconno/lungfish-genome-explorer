enum FullLengthONTMHCSAMMetricsMetric: String, Equatable, Sendable {
    case matches
    case snps
    case ambiguousMatchBases
    case insertedBases
    case deletedBases
    case skippedReferenceBases
    case softClippedBases
    case explicitDifferences
    case comparableBases
    case nonIntronIndelBases
    case referenceSpan
    case querySpan
    case alignmentScore
    case targetEnd
}

enum FullLengthONTMHCSAMMetricsArithmeticOperation: Equatable, Sendable {
    case accumulateCIGAROperator(Character)
    case add
    case subtract
    case multiply(Int)
}

enum FullLengthONTMHCSAMMetricsError: Error, Equatable, Sendable {
    case emptyCIGAR
    case missingOperationLength(operator: Character)
    case invalidOperationLength(String)
    case zeroOperationLength(operator: Character)
    case trailingOperationLength(String)
    case unsupportedOperator(Character)
    case missingNMForAmbiguousMatch
    case invalidNM(String)
    case negativeNM(Int)
    case nmSmallerThanExplicitDifferences(nm: Int, explicitDifferences: Int)
    case nmMismatchCountExceedsAmbiguousMatches(mismatchCount: Int, ambiguousMatchBases: Int)
    case arithmeticOverflow(
        metric: FullLengthONTMHCSAMMetricsMetric,
        operation: FullLengthONTMHCSAMMetricsArithmeticOperation
    )
}

struct FullLengthONTMHCSAMMetrics: Equatable, Sendable {
    let matches: Int
    let snps: Int
    let insertedBases: Int
    let deletedBases: Int
    let skippedReferenceBases: Int
    let softClippedBases: Int

    private let comparableBaseCount: Int
    private let nonIntronIndelBaseCount: Int
    private let referenceBaseSpan: Int
    private let queryBaseSpan: Int

    var comparableBases: Int { comparableBaseCount }
    var nonIntronIndelBases: Int { nonIntronIndelBaseCount }
    var referenceSpan: Int { referenceBaseSpan }
    var querySpan: Int { queryBaseSpan }

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

            let operation = FullLengthONTMHCSAMMetricsArithmeticOperation.accumulateCIGAROperator(character)
            switch character {
            case "=":
                explicitMatches = try Self.adding(
                    explicitMatches,
                    length,
                    metric: .matches,
                    operation: operation
                )
            case "X":
                explicitSubstitutions = try Self.adding(
                    explicitSubstitutions,
                    length,
                    metric: .snps,
                    operation: operation
                )
            case "M":
                ambiguousMatchBases = try Self.adding(
                    ambiguousMatchBases,
                    length,
                    metric: .ambiguousMatchBases,
                    operation: operation
                )
            case "I":
                insertedBases = try Self.adding(
                    insertedBases,
                    length,
                    metric: .insertedBases,
                    operation: operation
                )
            case "D":
                deletedBases = try Self.adding(
                    deletedBases,
                    length,
                    metric: .deletedBases,
                    operation: operation
                )
            case "N":
                skippedReferenceBases = try Self.adding(
                    skippedReferenceBases,
                    length,
                    metric: .skippedReferenceBases,
                    operation: operation
                )
            case "S":
                softClippedBases = try Self.adding(
                    softClippedBases,
                    length,
                    metric: .softClippedBases,
                    operation: operation
                )
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
            let explicitIndels = try Self.adding(
                insertedBases,
                deletedBases,
                metric: .explicitDifferences,
                operation: .add
            )
            let explicitDifferences = try Self.adding(
                explicitIndels,
                explicitSubstitutions,
                metric: .explicitDifferences,
                operation: .add
            )
            guard nm >= explicitDifferences else {
                throw FullLengthONTMHCSAMMetricsError.nmSmallerThanExplicitDifferences(
                    nm: nm,
                    explicitDifferences: explicitDifferences
                )
            }
            ambiguousSubstitutions = try Self.subtracting(
                nm,
                explicitDifferences,
                metric: .snps,
                operation: .subtract
            )
            guard ambiguousSubstitutions <= ambiguousMatchBases else {
                throw FullLengthONTMHCSAMMetricsError.nmMismatchCountExceedsAmbiguousMatches(
                    mismatchCount: ambiguousSubstitutions,
                    ambiguousMatchBases: ambiguousMatchBases
                )
            }
        } else {
            ambiguousSubstitutions = 0
        }

        let allPotentialMatches = try Self.adding(
            explicitMatches,
            ambiguousMatchBases,
            metric: .matches,
            operation: .add
        )
        let matches = try Self.subtracting(
            allPotentialMatches,
            ambiguousSubstitutions,
            metric: .matches,
            operation: .subtract
        )
        let snps = try Self.adding(
            explicitSubstitutions,
            ambiguousSubstitutions,
            metric: .snps,
            operation: .add
        )
        let comparableBases = try Self.adding(matches, snps, metric: .comparableBases, operation: .add)
        let nonIntronIndelBases = try Self.adding(
            insertedBases,
            deletedBases,
            metric: .nonIntronIndelBases,
            operation: .add
        )
        let comparableAndDeleted = try Self.adding(
            comparableBases,
            deletedBases,
            metric: .referenceSpan,
            operation: .add
        )
        let referenceSpan = try Self.adding(
            comparableAndDeleted,
            skippedReferenceBases,
            metric: .referenceSpan,
            operation: .add
        )
        let comparableAndInserted = try Self.adding(
            comparableBases,
            insertedBases,
            metric: .querySpan,
            operation: .add
        )
        let querySpan = try Self.adding(
            comparableAndInserted,
            softClippedBases,
            metric: .querySpan,
            operation: .add
        )

        self.matches = matches
        self.snps = snps
        self.insertedBases = insertedBases
        self.deletedBases = deletedBases
        self.skippedReferenceBases = skippedReferenceBases
        self.softClippedBases = softClippedBases
        self.comparableBaseCount = comparableBases
        self.nonIntronIndelBaseCount = nonIntronIndelBases
        self.referenceBaseSpan = referenceSpan
        self.queryBaseSpan = querySpan
    }

    static func adding(
        _ lhs: Int,
        _ rhs: Int,
        metric: FullLengthONTMHCSAMMetricsMetric,
        operation: FullLengthONTMHCSAMMetricsArithmeticOperation
    ) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw FullLengthONTMHCSAMMetricsError.arithmeticOverflow(metric: metric, operation: operation)
        }
        return result.partialValue
    }

    static func subtracting(
        _ lhs: Int,
        _ rhs: Int,
        metric: FullLengthONTMHCSAMMetricsMetric,
        operation: FullLengthONTMHCSAMMetricsArithmeticOperation
    ) throws -> Int {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw FullLengthONTMHCSAMMetricsError.arithmeticOverflow(metric: metric, operation: operation)
        }
        return result.partialValue
    }

    static func multiplying(
        _ lhs: Int,
        _ rhs: Int,
        metric: FullLengthONTMHCSAMMetricsMetric,
        operation: FullLengthONTMHCSAMMetricsArithmeticOperation
    ) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw FullLengthONTMHCSAMMetricsError.arithmeticOverflow(metric: metric, operation: operation)
        }
        return result.partialValue
    }
}
