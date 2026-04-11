// ColumnFilterTests.swift - Tests for per-column filter model
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Testing
@testable import LungfishApp

struct ColumnFilterTests {

    // MARK: - Numeric Filters

    @Test
    func numericGreaterOrEqual() {
        let filter = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "100")
        #expect(filter.matchesNumeric(100))
        #expect(filter.matchesNumeric(200))
        #expect(filter.matchesNumeric(100.5))
        #expect(!filter.matchesNumeric(99))
        #expect(!filter.matchesNumeric(0))
    }

    @Test
    func numericLessOrEqual() {
        let filter = ColumnFilter(columnId: "hits", op: .lessOrEqual, value: "50")
        #expect(filter.matchesNumeric(50))
        #expect(filter.matchesNumeric(10))
        #expect(filter.matchesNumeric(0))
        #expect(!filter.matchesNumeric(51))
        #expect(!filter.matchesNumeric(100))
    }

    @Test
    func numericEqual() {
        let filter = ColumnFilter(columnId: "hits", op: .equal, value: "42")
        #expect(filter.matchesNumeric(42))
        #expect(!filter.matchesNumeric(41))
        #expect(!filter.matchesNumeric(43))
    }

    @Test
    func numericBetween() {
        let filter = ColumnFilter(columnId: "hits", op: .between, value: "10", value2: "20")
        #expect(filter.matchesNumeric(10))
        #expect(filter.matchesNumeric(15))
        #expect(filter.matchesNumeric(20))
        #expect(!filter.matchesNumeric(9))
        #expect(!filter.matchesNumeric(21))
    }

    @Test
    func numericBetweenWithoutSecondValue() {
        // If value2 is nil, "between" degrades to ≥
        let filter = ColumnFilter(columnId: "hits", op: .between, value: "10", value2: nil)
        #expect(filter.matchesNumeric(10))
        #expect(filter.matchesNumeric(100))
        #expect(!filter.matchesNumeric(9))
    }

    // MARK: - Text Filters

    @Test
    func textContains() {
        let filter = ColumnFilter(columnId: "name", op: .contains, value: "astro")
        #expect(filter.matchesString("Astrovirus"))
        #expect(filter.matchesString("Human astrovirus 1"))
        #expect(!filter.matchesString("Norovirus"))
        #expect(!filter.matchesString("Rotavirus"))
    }

    @Test
    func textContainsCaseInsensitive() {
        let filter = ColumnFilter(columnId: "name", op: .contains, value: "ASTRO")
        #expect(filter.matchesString("astrovirus"))
        #expect(filter.matchesString("Human Astrovirus 5"))
    }

    @Test
    func textEquals() {
        let filter = ColumnFilter(columnId: "name", op: .equal, value: "Rotavirus A")
        #expect(filter.matchesString("Rotavirus A"))
        #expect(filter.matchesString("rotavirus a"))  // case-insensitive
        #expect(!filter.matchesString("Rotavirus"))
        #expect(!filter.matchesString("Rotavirus A variant"))
    }

    @Test
    func textStartsWith() {
        let filter = ColumnFilter(columnId: "name", op: .startsWith, value: "Human")
        #expect(filter.matchesString("Human astrovirus"))
        #expect(filter.matchesString("human rotavirus"))  // case-insensitive
        #expect(!filter.matchesString("Mamastrovirus"))
        #expect(!filter.matchesString("Non-Human primate virus"))
    }

    // MARK: - Empty Filter

    @Test
    func emptyFilterMatchesEverything() {
        let filter = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "")
        #expect(!filter.isActive)
        #expect(filter.matchesNumeric(0))
        #expect(filter.matchesNumeric(999999))
        #expect(filter.matchesString("anything"))
        #expect(filter.matchesString(""))
    }

    // MARK: - K/M Suffix Parsing

    @Test
    func parseKMSuffixes() {
        let filter1 = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "1.5K")
        #expect(filter1.matchesNumeric(1500))
        #expect(filter1.matchesNumeric(2000))
        #expect(!filter1.matchesNumeric(1499))

        let filter2 = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "2M")
        #expect(filter2.matchesNumeric(2_000_000))
        #expect(!filter2.matchesNumeric(1_999_999))

        let filter3 = ColumnFilter(columnId: "hits", op: .lessOrEqual, value: "500k")
        #expect(filter3.matchesNumeric(500_000))
        #expect(!filter3.matchesNumeric(500_001))
    }

    // MARK: - Filter Composition

    @Test
    func filterComposition() {
        let filters: [ColumnFilter] = [
            ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "100"),
            ColumnFilter(columnId: "name", op: .contains, value: "virus"),
        ]

        struct Row {
            let hits: Int
            let name: String
        }

        let rows = [
            Row(hits: 200, name: "Norovirus GII"),      // passes both
            Row(hits: 50, name: "Astrovirus SG"),        // fails hits
            Row(hits: 300, name: "Mamastrovirus 1"),     // fails name (no "virus" substring... wait, "Mamastrovirus" contains "virus")
            Row(hits: 10, name: "Human picobirna"),      // fails both
        ]

        // Simulating composition: all filters must pass
        let filtered = rows.filter { row in
            filters.allSatisfy { filter in
                switch filter.columnId {
                case "hits": return filter.matchesNumeric(Double(row.hits))
                case "name": return filter.matchesString(row.name)
                default: return true
                }
            }
        }

        #expect(filtered.count == 2)  // Norovirus GII (200) and Mamastrovirus 1 (300)
        #expect(filtered[0].name == "Norovirus GII")
        #expect(filtered[1].name == "Mamastrovirus 1")
    }

    // MARK: - isActive

    @Test
    func isActiveReflectsValuePresence() {
        let active = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "100")
        #expect(active.isActive)

        let inactive = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "")
        #expect(!inactive.isActive)

        let whitespace = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "  ")
        #expect(!whitespace.isActive)
    }

    // MARK: - Numeric operators on string values

    @Test
    func numericFilterOnNonNumericStringReturnsFalse() {
        let filter = ColumnFilter(columnId: "hits", op: .greaterOrEqual, value: "100")
        // matchesString with a numeric filter should try to parse the string as a number
        #expect(!filter.matchesString("not a number"))
        #expect(filter.matchesString("200"))  // "200" parses as number
    }
}
