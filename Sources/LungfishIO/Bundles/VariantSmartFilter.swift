import Foundation

public enum VariantSmartFilterError: Error, LocalizedError, Sendable, Equatable {
    case empty
    case unsupportedSyntax(String)
    case invalidNumericValue(String)
    case unsupportedField(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Smart filter is empty."
        case .unsupportedSyntax(let text):
            return "Unsupported smart-filter syntax: \(text)"
        case .invalidNumericValue(let value):
            return "Expected numeric smart-filter value, got '\(value)'."
        case .unsupportedField(let field):
            return "Unsupported per-sample field '\(field)'."
        }
    }
}

public enum VariantSmartComparisonOp: String, Sendable, Equatable {
    case gt = ">"
    case gte = ">="
    case lt = "<"
    case lte = "<="
    case eq = "="
    case neq = "!="

    static let parseOrder: [Self] = [.gte, .lte, .neq, .gt, .lt, .eq]
}

public enum VariantSampleField: String, Sendable, Equatable {
    case genotype = "GT"
    case alleleFrequency = "AF"
    case depth = "DP"

    init(token: String) throws {
        switch token.uppercased() {
        case "GT": self = .genotype
        case "AF": self = .alleleFrequency
        case "DP": self = .depth
        default: throw VariantSmartFilterError.unsupportedField(token)
        }
    }
}

public struct VariantSmartBinding: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case int64(Int64)
        case double(Double)
    }

    public let value: Value

    public var stringValue: String {
        switch value {
        case .string(let value): return value
        case .int64(let value): return String(value)
        case .double(let value): return String(value)
        }
    }

    public static func string(_ value: String) -> Self { Self(value: .string(value)) }
    public static func int64(_ value: Int64) -> Self { Self(value: .int64(value)) }
    public static func double(_ value: Double) -> Self { Self(value: .double(value)) }
}

public struct VariantSmartCompiledSQL: Sendable, Equatable {
    public let sql: String
    public let bindings: [VariantSmartBinding]

    public init(sql: String, bindings: [VariantSmartBinding]) {
        self.sql = sql
        self.bindings = bindings
    }
}

public struct VariantSamplePredicate: Sendable, Equatable {
    public let sample: String
    public let field: VariantSampleField
    public let op: VariantSmartComparisonOp
    public let value: String

    public init(sample: String, field: VariantSampleField, op: VariantSmartComparisonOp, value: String) {
        self.sample = sample
        self.field = field
        self.op = op
        self.value = value
    }
}

public struct VariantSampleCountPredicate: Sendable, Equatable {
    public let predicate: VariantSamplePredicate
    public let op: VariantSmartComparisonOp
    public let count: Int
}

public struct VariantSampleFieldReference: Sendable, Equatable {
    public let sample: String
    public let field: VariantSampleField
}

public struct VariantSampleFieldComparison: Sendable, Equatable {
    public let lhs: VariantSampleFieldReference
    public let rhs: VariantSampleFieldReference
    public let field: VariantSampleField
    public let op: VariantSmartComparisonOp
}

public struct VariantSmartFilter: Sendable, Equatable {
    public var sampleComparisons: [VariantSamplePredicate] = []
    public var countComparisons: [VariantSampleCountPredicate] = []
    public var sampleFieldComparisons: [VariantSampleFieldComparison] = []

    public init(
        sampleComparisons: [VariantSamplePredicate] = [],
        countComparisons: [VariantSampleCountPredicate] = [],
        sampleFieldComparisons: [VariantSampleFieldComparison] = []
    ) {
        self.sampleComparisons = sampleComparisons
        self.countComparisons = countComparisons
        self.sampleFieldComparisons = sampleFieldComparisons
    }

    public static func parse(_ text: String) throws -> VariantSmartFilter {
        let clauses = text
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { throw VariantSmartFilterError.empty }

        var filter = VariantSmartFilter()
        for clause in clauses {
            if let count = try parseCountPredicate(clause) {
                filter.countComparisons.append(count)
            } else if let fieldComparison = try parseSampleFieldComparison(clause) {
                filter.sampleFieldComparisons.append(fieldComparison)
            } else if let predicate = try parseSamplePredicate(clause) {
                filter.sampleComparisons.append(predicate)
            } else {
                throw VariantSmartFilterError.unsupportedSyntax(clause)
            }
        }
        return filter
    }

    public func compileSQL(limit: Int = 5000) -> VariantSmartCompiledSQL {
        var conditions: [String] = []
        var bindings: [VariantSmartBinding] = []

        for predicate in sampleComparisons {
            conditions.append(Self.sql(for: predicate, bindings: &bindings))
        }
        for count in countComparisons {
            conditions.append(Self.sql(for: count, bindings: &bindings))
        }
        for comparison in sampleFieldComparisons {
            conditions.append(Self.sql(for: comparison, bindings: &bindings))
        }

        var sql = "SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY chromosome, position LIMIT \(max(1, limit))"
        return VariantSmartCompiledSQL(sql: sql, bindings: bindings)
    }

    private static func parseCountPredicate(_ text: String) throws -> VariantSampleCountPredicate? {
        guard text.lowercased().hasPrefix("count("), let close = text.firstIndex(of: ")") else { return nil }
        let innerStart = text.index(text.startIndex, offsetBy: 6)
        let inner = String(text[innerStart..<close])
        let tail = text[text.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (op, rhs) = splitComparison(tail), let count = Int(rhs) else {
            throw VariantSmartFilterError.unsupportedSyntax(text)
        }
        let predicate = try parseSamplePredicate(inner)
        return VariantSampleCountPredicate(predicate: predicate, op: op, count: count)
    }

    private static func parseSampleFieldComparison(_ text: String) throws -> VariantSampleFieldComparison? {
        guard let (op, rhs) = splitComparison(text) else { return nil }
        let lhsText = String(text[..<text.range(of: op.rawValue)!.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lhs = try parseSampleFieldReference(lhsText),
              let rhsRef = try parseSampleFieldReference(rhs) else {
            return nil
        }
        guard lhs.field == rhsRef.field else {
            throw VariantSmartFilterError.unsupportedSyntax(text)
        }
        return VariantSampleFieldComparison(lhs: lhs, rhs: rhsRef, field: lhs.field, op: op)
    }

    private static func parseSamplePredicate(_ text: String) throws -> VariantSamplePredicate? {
        guard let (op, rhs) = splitComparison(text) else { return nil }
        let lhs = String(text[..<text.range(of: op.rawValue)!.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fieldRef = try parseSampleFieldReference(lhs) else { return nil }
        if fieldRef.field != .genotype, Double(rhs) == nil {
            throw VariantSmartFilterError.invalidNumericValue(rhs)
        }
        return VariantSamplePredicate(sample: fieldRef.sample, field: fieldRef.field, op: op, value: rhs)
    }

    private static func splitComparison(_ text: String) -> (VariantSmartComparisonOp, String)? {
        for op in VariantSmartComparisonOp.parseOrder {
            if let range = text.range(of: op.rawValue) {
                let rhs = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rhs.isEmpty else { return nil }
                return (op, rhs)
            }
        }
        return nil
    }

    private static func parseSampleFieldReference(_ text: String) throws -> VariantSampleFieldReference? {
        let pattern = #"^Sample\[([^\]]+)\]\.([A-Za-z0-9_]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges == 3,
              let sampleRange = Range(match.range(at: 1), in: text),
              let fieldRange = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return VariantSampleFieldReference(
            sample: String(text[sampleRange]),
            field: try VariantSampleField(token: String(text[fieldRange]))
        )
    }

    private static func sql(for predicate: VariantSamplePredicate, bindings: inout [VariantSmartBinding]) -> String {
        var localConditions: [String] = []
        if predicate.sample != "*" {
            localConditions.append("g.sample_name = ?")
            bindings.append(.string(predicate.sample))
        }
        localConditions.append(sqlComparison(alias: "g", field: predicate.field, op: predicate.op))
        appendValueBinding(predicate, to: &bindings)
        return "EXISTS (SELECT 1 FROM genotypes g WHERE g.variant_id = variants.id AND \(localConditions.joined(separator: " AND ")))"
    }

    private static func sql(for count: VariantSampleCountPredicate, bindings: inout [VariantSmartBinding]) -> String {
        var localConditions: [String] = []
        if count.predicate.sample != "*" {
            localConditions.append("g.sample_name = ?")
            bindings.append(.string(count.predicate.sample))
        }
        localConditions.append(sqlComparison(alias: "g", field: count.predicate.field, op: count.predicate.op))
        appendValueBinding(count.predicate, to: &bindings)
        bindings.append(.int64(Int64(count.count)))
        return "(SELECT COUNT(*) FROM genotypes g WHERE g.variant_id = variants.id AND \(localConditions.joined(separator: " AND "))) \(count.op.rawValue) ?"
    }

    private static func sql(for comparison: VariantSampleFieldComparison, bindings: inout [VariantSmartBinding]) -> String {
        bindings.append(.string(comparison.lhs.sample))
        bindings.append(.string(comparison.rhs.sample))
        return """
        EXISTS (
            SELECT 1 FROM genotypes lhs
            INNER JOIN genotypes rhs ON rhs.variant_id = lhs.variant_id
            WHERE lhs.variant_id = variants.id
              AND lhs.sample_name = ?
              AND rhs.sample_name = ?
              AND \(fieldExpression(alias: "lhs", field: comparison.field)) \(comparison.op.rawValue) \(fieldExpression(alias: "rhs", field: comparison.field))
        )
        """
    }

    private static func sqlComparison(alias: String, field: VariantSampleField, op: VariantSmartComparisonOp) -> String {
        "\(fieldExpression(alias: alias, field: field)) \(op.rawValue) ?"
    }

    private static func appendValueBinding(_ predicate: VariantSamplePredicate, to bindings: inout [VariantSmartBinding]) {
        switch predicate.field {
        case .genotype:
            bindings.append(.string(predicate.value))
        case .depth:
            bindings.append(.int64(Int64(predicate.value) ?? 0))
        case .alleleFrequency:
            bindings.append(.double(Double(predicate.value) ?? 0))
        }
    }

    private static func fieldExpression(alias: String, field: VariantSampleField) -> String {
        switch field {
        case .genotype:
            return "\(alias).genotype"
        case .depth:
            return "\(alias).depth"
        case .alleleFrequency:
            let comma = "instr(\(alias).allele_depths, ',')"
            let ref = "CAST(substr(\(alias).allele_depths, 1, \(comma) - 1) AS REAL)"
            let alt = "CAST(substr(\(alias).allele_depths, \(comma) + 1) AS REAL)"
            return "(CASE WHEN \(alias).allele_depths IS NOT NULL AND \(comma) > 0 AND (\(ref) + \(alt)) > 0 THEN \(alt) / (\(ref) + \(alt)) ELSE NULL END)"
        }
    }
}
