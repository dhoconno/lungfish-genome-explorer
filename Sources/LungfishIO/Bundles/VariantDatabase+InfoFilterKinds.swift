// VariantDatabase+InfoFilterKinds.swift - An INFO filter on keys of both kinds compares each key by its own rule
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension VariantDatabase.InfoFilter {

    /// The condition of `=` or `!=` when the keys read are of both kinds, and nil when they are of one kind.
    ///
    /// A key that holds a comma-joined list (an `ANN_` or `CSQ_` part or an impact key) is compared by the members of
    /// its list, and any other key, such as a plain `GENE`, by its whole value. One plain key among the keys must not
    /// turn the member match off for the list keys, so each kind gets its own comparison and a variant counts when
    /// either holds. A value that holds a comma is a whole joined list and keeps the whole-value comparison, which
    /// `sqlCondition` builds for it.
    func mixedKindsCondition(
        _ allKeys: [String], paramIndex: inout Int32
    ) -> (sql: String, bindings: [(Int32, String)])? {
        guard op == .eq || op == .neq, !value.contains(",") else { return nil }
        let listKeys = allKeys.filter(Self.holdsValueList)
        guard !listKeys.isEmpty, listKeys.count < allKeys.count else { return nil }
        let plainKeys = allKeys.filter { !Self.holdsValueList($0) }
        var bindings: [(Int32, String)] = []
        func keyMatch(_ names: [String]) -> String {
            for name in names {
                bindings.append((paramIndex, name))
                paramIndex += 1
            }
            return "vi.key COLLATE NOCASE IN (\(names.map { _ in "?" }.joined(separator: ", ")))"
        }
        func bindValue() {
            bindings.append((paramIndex, value))
            paramIndex += 1
        }
        // The bindings follow the order of the placeholders in the statement, the list keys, their value, the plain
        // keys and theirs.
        let lists = keyMatch(listKeys)
        bindValue()
        let plains = keyMatch(plainKeys)
        bindValue()
        let member = "instr(',' || vi.value || ',', ',' || ? || ',')"
        let listCmp = op == .eq ? "\(member) > 0" : "\(member) = 0"
        let plainCmp = op == .eq ? "vi.value = ?" : "vi.value != ?"
        let sql = "EXISTS (SELECT 1 FROM variant_info vi WHERE vi.variant_id = variants.id AND "
            + "((\(lists) AND \(listCmp)) OR (\(plains) AND \(plainCmp))))"
        return (sql: sql, bindings: bindings)
    }
}
