// VariantSmartFilter.swift - Per-sample smart-filter parsing and SQL compilation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum VariantSmartFilterError: Error, LocalizedError, Sendable {
    case emptyFilter
    case unsupportedClause(String)
    case unsupportedField(String)
    case invalidNumericValue(String)
    case invalidCount(String)

    public var errorDescription: String? {
        switch self {
        case .emptyFilter:
            return "Filter is empty."
        case .unsupportedClause(let clause):
            return "Unsupported smart-filter clause: \(clause)"
        case .unsupportedField(let field):
            return "Unsupported sample field: \(field)"
        case .invalidNumericValue(let value):
            return "Expected a numeric smart-filter value, found: \(value)"
        case .invalidCount(let value):
            return "Expected an integer count threshold, found: \(value)"
        }
    }
}

public enum VariantSmartComparisonOp: String, CaseIterable, Sendable {
    case gte = ">="
    case lte = "<="
    case neq = "!="
    case gt = ">"
    case lt = "<"
    case eq = "="

    static let parseOrder: [VariantSmartComparisonOp] = [.gte, .lte, .neq, .gt, .lt, .eq]

    var sql: String { rawValue }
}

public enum VariantSampleField: String, Sendable {
    case genotype = "GT"
    case alleleFrequency = "AF"
    case depth = "DP"

    init(token: String) throws {
        guard let field = Self(rawValue: token.uppercased()) else {
            throw VariantSmartFilterError.unsupportedField(token)
        }
        self = field
    }
}

public enum VariantSmartBinding: Equatable, Sendable {
    case text(String)
    case double(Double)
    case int(Int)
}

public struct VariantSmartCompiledSQL: Equatable, Sendable {
    public let sql: String
    public let bindings: [VariantSmartBinding]
}

public enum VariantSmartPredicate: CustomStringConvertible, Equatable, Sendable {
    case sample(VariantSamplePredicate)
    case count(VariantSampleCountPredicate)
    case sampleFieldComparison(VariantSampleFieldComparison)

    public var description: String {
        switch self {
        case .sample(let predicate):
            return predicate.description
        case .count(let predicate):
            return predicate.description
        case .sampleFieldComparison(let predicate):
            return predicate.description
        }
    }
}

public struct VariantSamplePredicate: CustomStringConvertible, Equatable, Sendable {
    public let sampleName: String?
    public let field: VariantSampleField
    public let op: VariantSmartComparisonOp
    public let value: String

    public var description: String {
        let sample = sampleName ?? "*"
        return "Sample[\(sample)].\(field.rawValue)\(op.rawValue)\(value)"
    }
}

public struct VariantSampleCountPredicate: CustomStringConvertible, Equatable, Sendable {
    public let predicate: VariantSamplePredicate
    public let op: VariantSmartComparisonOp
    public let count: Int

    public var description: String {
        "count(\(predicate.description))\(op.rawValue)\(count)"
    }
}

public struct VariantSampleFieldReference: CustomStringConvertible, Equatable, Sendable {
    public let sampleName: String
    public let field: VariantSampleField

    public var description: String {
        "Sample[\(sampleName)].\(field.rawValue)"
    }
}

public struct VariantSampleFieldComparison: CustomStringConvertible, Equatable, Sendable {
    public let lhs: VariantSampleFieldReference
    public let op: VariantSmartComparisonOp
    public let rhs: VariantSampleFieldReference

    public var description: String {
        "\(lhs.description)\(op.rawValue)\(rhs.description)"
    }
}

public struct VariantSmartFilter: Equatable, Sendable {
    public let predicates: [VariantSmartPredicate]

    public static func parse(_ text: String) throws -> VariantSmartFilter {
        let clauses = text.split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else {
            throw VariantSmartFilterError.emptyFilter
        }
        return VariantSmartFilter(predicates: try clauses.map(parseClause))
    }

    public func compileSQL(limit: Int = 5000) throws -> VariantSmartCompiledSQL {
        var bindings: [VariantSmartBinding] = []
        let conditions = try predicates.map { try Self.sqlCondition(for: $0, bindings: &bindings) }
        let boundedLimit = max(0, limit)
        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let sql = """
            SELECT id, chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count
            FROM variants\(whereClause)
            ORDER BY chromosome, position
            LIMIT \(boundedLimit)
            """
        return VariantSmartCompiledSQL(sql: sql, bindings: bindings)
    }

    private static func parseClause(_ clause: String) throws -> VariantSmartPredicate {
        if clause.hasPrefix("count(") {
            return .count(try parseCount(clause))
        }
        if let fieldComparison = try parseSampleFieldComparison(clause) {
            return .sampleFieldComparison(fieldComparison)
        }
        return .sample(try parseSamplePredicate(clause))
    }

    private static func parseCount(_ clause: String) throws -> VariantSampleCountPredicate {
        guard let close = clause.firstIndex(of: ")") else {
            throw VariantSmartFilterError.unsupportedClause(clause)
        }
        let start = clause.index(clause.startIndex, offsetBy: "count(".count)
        let inner = String(clause[start..<close])
        let rest = String(clause[clause.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        let (op, rhs) = try splitComparison(rest, original: clause)
        guard let count = Int(rhs) else {
            throw VariantSmartFilterError.invalidCount(rhs)
        }
        let predicate = try parseSamplePredicate(inner)
        guard predicate.sampleName == nil else {
            throw VariantSmartFilterError.unsupportedClause(clause)
        }
        return VariantSampleCountPredicate(predicate: predicate, op: op, count: count)
    }

    private static func parseSampleFieldComparison(_ clause: String) throws -> VariantSampleFieldComparison? {
        for op in VariantSmartComparisonOp.parseOrder {
            guard let range = clause.range(of: op.rawValue) else { continue }
            let lhsText = String(clause[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhsText = String(clause[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard rhsText.hasPrefix("Sample[") else { return nil }
            let lhs = try parseFieldReference(lhsText, original: clause)
            let rhs = try parseFieldReference(rhsText, original: clause)
            guard lhs.field == rhs.field else {
                throw VariantSmartFilterError.unsupportedClause(clause)
            }
            return VariantSampleFieldComparison(lhs: lhs, op: op, rhs: rhs)
        }
        return nil
    }

    private static func parseSamplePredicate(_ clause: String) throws -> VariantSamplePredicate {
        for op in VariantSmartComparisonOp.parseOrder {
            guard let range = clause.range(of: op.rawValue) else { continue }
            let lhsText = String(clause[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(clause[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let fieldRef = try parseOptionalWildcardReference(lhsText, original: clause)
            if fieldRef.field != .genotype {
                _ = try numericBinding(for: fieldRef.field, value: rhs)
            }
            return VariantSamplePredicate(sampleName: fieldRef.sampleName, field: fieldRef.field, op: op, value: rhs)
        }
        throw VariantSmartFilterError.unsupportedClause(clause)
    }

    private static func parseFieldReference(_ text: String, original: String) throws -> VariantSampleFieldReference {
        let parsed = try parseSampleReference(text, original: original)
        guard let sampleName = parsed.sampleName, sampleName != "*" else {
            throw VariantSmartFilterError.unsupportedClause(original)
        }
        return VariantSampleFieldReference(sampleName: sampleName, field: parsed.field)
    }

    private static func parseOptionalWildcardReference(_ text: String, original: String) throws -> VariantSamplePredicate {
        let parsed = try parseSampleReference(text, original: original)
        let sampleName = parsed.sampleName == "*" ? nil : parsed.sampleName
        return VariantSamplePredicate(sampleName: sampleName, field: parsed.field, op: .eq, value: "")
    }

    private static func parseSampleReference(_ text: String, original: String) throws -> (sampleName: String?, field: VariantSampleField) {
        guard text.hasPrefix("Sample["),
              let close = text.firstIndex(of: "]"),
              close < text.endIndex,
              text[text.index(after: close)] == "." else {
            throw VariantSmartFilterError.unsupportedClause(original)
        }
        let sampleStart = text.index(text.startIndex, offsetBy: "Sample[".count)
        let sampleName = String(text[sampleStart..<close])
        let fieldStart = text.index(close, offsetBy: 2)
        let fieldText = String(text[fieldStart...])
        guard !sampleName.isEmpty, !fieldText.isEmpty else {
            throw VariantSmartFilterError.unsupportedClause(original)
        }
        return (sampleName: sampleName, field: try VariantSampleField(token: fieldText))
    }

    private static func splitComparison(_ text: String, original: String) throws -> (VariantSmartComparisonOp, String) {
        for op in VariantSmartComparisonOp.parseOrder {
            guard text.hasPrefix(op.rawValue) else { continue }
            let rhs = String(text.dropFirst(op.rawValue.count)).trimmingCharacters(in: .whitespaces)
            guard !rhs.isEmpty else { throw VariantSmartFilterError.unsupportedClause(original) }
            return (op, rhs)
        }
        throw VariantSmartFilterError.unsupportedClause(original)
    }

    private static func sqlCondition(
        for predicate: VariantSmartPredicate,
        bindings: inout [VariantSmartBinding]
    ) throws -> String {
        switch predicate {
        case .sample(let predicate):
            return try samplePredicateSQL(predicate, alias: "g", bindings: &bindings)
        case .count(let predicate):
            let inner = try genotypeValueCondition(
                field: predicate.predicate.field,
                op: predicate.predicate.op,
                value: predicate.predicate.value,
                alias: "g",
                bindings: &bindings
            )
            bindings.append(.int(predicate.count))
            return "(SELECT COUNT(*) FROM genotypes g WHERE g.variant_id = variants.id AND \(inner)) \(predicate.op.sql) ?"
        case .sampleFieldComparison(let predicate):
            bindings.append(.text(predicate.lhs.sampleName))
            bindings.append(.text(predicate.rhs.sampleName))
            let comparison = try fieldComparisonSQL(
                field: predicate.lhs.field,
                op: predicate.op,
                lhsAlias: "lhs",
                rhsAlias: "rhs"
            )
            return """
                EXISTS (
                    SELECT 1 FROM genotypes lhs
                    JOIN genotypes rhs ON rhs.variant_id = lhs.variant_id
                    WHERE lhs.variant_id = variants.id
                      AND lhs.sample_name = ?
                      AND rhs.sample_name = ?
                      AND \(comparison)
                )
                """
        }
    }

    private static func samplePredicateSQL(
        _ predicate: VariantSamplePredicate,
        alias: String,
        bindings: inout [VariantSmartBinding]
    ) throws -> String {
        var parts = ["EXISTS (SELECT 1 FROM genotypes \(alias) WHERE \(alias).variant_id = variants.id"]
        if let sampleName = predicate.sampleName {
            bindings.append(.text(sampleName))
            parts.append("AND \(alias).sample_name = ?")
        }
        parts.append("AND \(try genotypeValueCondition(field: predicate.field, op: predicate.op, value: predicate.value, alias: alias, bindings: &bindings)))")
        return parts.joined(separator: " ")
    }

    private static func genotypeValueCondition(
        field: VariantSampleField,
        op: VariantSmartComparisonOp,
        value: String,
        alias: String,
        bindings: inout [VariantSmartBinding]
    ) throws -> String {
        switch field {
        case .genotype:
            bindings.append(.text(value))
            return "\(alias).genotype \(op.sql) ?"
        case .depth:
            bindings.append(try numericBinding(for: field, value: value))
            return "\(alias).depth \(op.sql) ?"
        case .alleleFrequency:
            bindings.append(try numericBinding(for: field, value: value))
            return "\(alleleFrequencyExpression(alias: alias)) \(op.sql) ?"
        }
    }

    private static func fieldComparisonSQL(
        field: VariantSampleField,
        op: VariantSmartComparisonOp,
        lhsAlias: String,
        rhsAlias: String
    ) throws -> String {
        switch field {
        case .genotype:
            return "\(lhsAlias).genotype \(op.sql) \(rhsAlias).genotype"
        case .depth:
            return "\(lhsAlias).depth \(op.sql) \(rhsAlias).depth"
        case .alleleFrequency:
            return "\(alleleFrequencyExpression(alias: lhsAlias)) \(op.sql) \(alleleFrequencyExpression(alias: rhsAlias))"
        }
    }

    private static func numericBinding(for field: VariantSampleField, value: String) throws -> VariantSmartBinding {
        guard let number = Double(value) else {
            throw VariantSmartFilterError.invalidNumericValue(value)
        }
        if field == .depth, number.rounded() == number {
            return .int(Int(number))
        }
        return .double(number)
    }

    private static func alleleFrequencyExpression(alias: String) -> String {
        """
        (
            CASE
                WHEN \(alias).allele_depths IS NULL THEN NULL
                WHEN instr(\(alias).allele_depths, ',') = 0 THEN NULL
                ELSE
                    CAST(substr(\(alias).allele_depths, instr(\(alias).allele_depths, ',') + 1) AS REAL)
                    / NULLIF(
                        CAST(substr(\(alias).allele_depths, 1, instr(\(alias).allele_depths, ',') - 1) AS REAL)
                        + CAST(substr(\(alias).allele_depths, instr(\(alias).allele_depths, ',') + 1) AS REAL),
                        0
                    )
            END
        )
        """
    }
}
