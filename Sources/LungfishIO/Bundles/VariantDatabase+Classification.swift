// VariantDatabase+Classification.swift - Variant classification + SQL helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

extension VariantDatabase {

    // MARK: - Variant Classification

    /// Classifies a variant based on ref/alt alleles.
    static func classifyVariant(ref: String, alts: [String]) -> String {
        let concreteAlts = alts.filter { !$0.isEmpty && $0 != "." }
        guard let firstAlt = concreteAlts.first else {
            return VariantType.reference.rawValue
        }

        guard !concreteAlts.contains(where: isNonSequenceAlt) else {
            return VariantType.complex.rawValue
        }

        if ref.count == 1 && firstAlt.count == 1 {
            return VariantType.snp.rawValue
        } else if ref.count > firstAlt.count {
            return VariantType.deletion.rawValue
        } else if ref.count < firstAlt.count {
            return VariantType.insertion.rawValue
        } else if ref.count == firstAlt.count && ref.count > 1 {
            return VariantType.mnp.rawValue
        } else {
            return VariantType.complex.rawValue
        }
    }

    /// Classifies a variant using the first ALT allele without allocating intermediate strings.
    static func classifyVariant(ref: Substring, altField: Substring) -> String {
        let concreteAlts = altField
            .split(separator: ",", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty && $0 != "." }
        guard let firstAlt = concreteAlts.first else {
            return VariantType.reference.rawValue
        }

        guard !concreteAlts.contains(where: isNonSequenceAlt) else {
            return VariantType.complex.rawValue
        }

        if ref.count == 1 && firstAlt.count == 1 {
            return VariantType.snp.rawValue
        } else if ref.count > firstAlt.count {
            return VariantType.deletion.rawValue
        } else if ref.count < firstAlt.count {
            return VariantType.insertion.rawValue
        } else if ref.count == firstAlt.count && ref.count > 1 {
            return VariantType.mnp.rawValue
        } else {
            return VariantType.complex.rawValue
        }
    }

    static func isNonSequenceAlt<S: StringProtocol>(_ alt: S) -> Bool {
        (alt.count == 1 && alt.first == "*") ||
            (alt.count > 2 && alt.first == "<" && alt.last == ">") ||
            alt.contains { $0 == "[" || $0 == "]" }
    }

    /// Parses a VCF ##INFO=<ID=X,Number=Y,Type=Z,Description="..."> header line.
    ///
    /// Sync version of the parser in VCFReader (which uses async APIs).
    /// Returns nil if the line cannot be parsed.
    static func parseINFODefinition(_ str: Substring) -> (id: String, type: String, number: String, description: String)? {
        let content = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if content.hasPrefix("<"), content.hasSuffix(">"), content.count >= 2 {
            normalized = String(content.dropFirst().dropLast())
        } else {
            normalized = content
        }

        var dict: [String: String] = [:]

        var current = ""
        var fields: [String] = []
        var inQuotes = false
        var isEscaped = false

        for char in normalized {
            if isEscaped {
                current.append(char)
                isEscaped = false
                continue
            }
            if inQuotes, char == "\\" {
                isEscaped = true
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == ",", !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    fields.append(trimmed)
                }
                current = ""
                continue
            }
            current.append(char)
        }
        let trailing = current.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty {
            fields.append(trailing)
        }

        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            value = value.replacingOccurrences(of: "\\\"", with: "\"")
            value = value.replacingOccurrences(of: "\\\\", with: "\\")
            dict[key] = value
        }

        guard let id = dict["ID"], let type = dict["Type"], let number = dict["Number"] else { return nil }
        return (id: id, type: type, number: number, description: dict["Description"] ?? "")
    }

    /// Parses the END value from a VCF INFO field string.
    static func parseINFOEnd<S: StringProtocol>(_ info: S) -> Int? {
        guard !(info.count == 1 && info.first == ".") else { return nil }
        for pair in info.split(separator: ";") {
            if pair.hasPrefix("END=") {
                let value = pair.dropFirst(4)
                if let endVal = Int(value) {
                    // VCF END is 1-based inclusive; 0-based exclusive = endVal
                    return endVal
                }
            }
        }
        return nil
    }

    // MARK: - SQL Helpers

    /// Executes a SQL statement and throws on failure.
    func executeSQL(_ sql: String) throws {
        guard let db else {
            throw VariantDatabaseError.createFailed("Database not open")
        }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "Unknown SQLite error"
            if let errMsg { sqlite3_free(errMsg) }
            throw VariantDatabaseError.createFailed("\(sql): \(msg)")
        }
    }
}
