// VariantQueryBuilderParseTests.swift - Tests for restoring the query builder's filter state
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Task E4 (2026-08-08 repo review fix campaign, finding AS6): the "Edit
// Query..." toolbar button implies the sheet will show/restore the
// current filter, but `initialFilterText` was accepted as a parameter and
// never parsed/used -- the sheet always opened with a single blank
// default QueryRule regardless of the existing filter text, silently
// discarding the user's current query state. VariantQueryBuilderView.parseInitialRules(from:)
// is the pure, testable inverse of QueryRule.toFilterClause(), mirroring
// the working pattern already used by SampleQueryBuilderView.parseInitialRules
// (which is NOT buggy -- verified during this task; only the variant
// builder was missing this).

import XCTest
@testable import LungfishApp

@MainActor
final class VariantQueryBuilderParseTests: XCTestCase {

    func testEmptyTextProducesSingleDefaultRule() {
        let rules = VariantQueryBuilderView.parseInitialRules(from: "")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.value, "")
    }

    func testParsesCallQualityClause() {
        let rules = VariantQueryBuilderView.parseInitialRules(from: "qual>=30")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.category, .callQuality)
        XCTAssertEqual(rules.first?.field, "Quality")
        XCTAssertEqual(rules.first?.op, ">=")
        XCTAssertEqual(rules.first?.value, "30")
    }

    func testParsesFilterEqualsClause() {
        let rules = VariantQueryBuilderView.parseInitialRules(from: "filter=PASS")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.category, .callQuality)
        XCTAssertEqual(rules.first?.field, "Filter")
        XCTAssertEqual(rules.first?.value, "PASS")
    }

    func testParsesLocationClauses() {
        let regionRules = VariantQueryBuilderView.parseInitialRules(from: "region=chr1:1000-2000")
        XCTAssertEqual(regionRules.first?.category, .location)
        XCTAssertEqual(regionRules.first?.field, "Region")
        XCTAssertEqual(regionRules.first?.value, "chr1:1000-2000")

        let chrRules = VariantQueryBuilderView.parseInitialRules(from: "chr=chr2")
        XCTAssertEqual(chrRules.first?.category, .location)
        XCTAssertEqual(chrRules.first?.field, "Chromosome")

        let genesRules = VariantQueryBuilderView.parseInitialRules(from: "genes=BRCA1,BRCA2")
        XCTAssertEqual(genesRules.first?.category, .location)
        XCTAssertEqual(genesRules.first?.field, "Gene List")
    }

    func testParsesIdentityClauses() {
        let textRules = VariantQueryBuilderView.parseInitialRules(from: "text=rs123")
        XCTAssertEqual(textRules.first?.category, .identity)
        XCTAssertEqual(textRules.first?.field, "ID/Name")

        let typeRules = VariantQueryBuilderView.parseInitialRules(from: "type=Indel")
        XCTAssertEqual(typeRules.first?.category, .identity)
        XCTAssertEqual(typeRules.first?.field, "Type")
    }

    func testParsesSampleGenotypeClause() {
        let rules = VariantQueryBuilderView.parseInitialRules(from: "Sample[NA12878].GT=1/1")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.category, .sampleGenotype)
        XCTAssertEqual(rules.first?.field, "NA12878.GT")
        XCTAssertEqual(rules.first?.op, "=")
        XCTAssertEqual(rules.first?.value, "1/1")
    }

    func testParsesMultipleClausesJoinedBySemicolon() {
        let rules = VariantQueryBuilderView.parseInitialRules(from: "qual>=30; filter=PASS")
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].field, "Quality")
        XCTAssertEqual(rules[1].field, "Filter")
    }

    func testParsesKnownBuiltInFieldAsCallQualityOrPopulation() {
        let dpRules = VariantQueryBuilderView.parseInitialRules(from: "DP>=10")
        XCTAssertEqual(dpRules.first?.category, .callQuality)
        XCTAssertEqual(dpRules.first?.field, "DP")

        let afRules = VariantQueryBuilderView.parseInitialRules(from: "AF<0.01")
        XCTAssertEqual(afRules.first?.category, .population)
        XCTAssertEqual(afRules.first?.field, "AF")
    }

    func testUnrecognizedFieldFallsBackToInfoFieldCategoryPreservingRoundTrip() {
        // An INFO field not in any built-in category list must still
        // round-trip via the .infoField category rather than being
        // dropped or misclassified.
        let rules = VariantQueryBuilderView.parseInitialRules(from: "CADD_PHRED>=20")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.category, .infoField)
        XCTAssertEqual(rules.first?.field, "CADD_PHRED")
        XCTAssertEqual(rules.first?.op, ">=")
        XCTAssertEqual(rules.first?.value, "20")
    }

    func testUnparseableClauseFallsBackToRawTextRuleInsteadOfBeingDropped() {
        // A hand-typed filter that doesn't match any known clause shape
        // (variantFilterText can be set directly from a text field, not
        // only builder-generated) must not silently vanish -- it becomes
        // a preserved raw-text rule the user can see and edit.
        let rules = VariantQueryBuilderView.parseInitialRules(from: "some freeform text with no operator")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.value, "some freeform text with no operator")
    }

    func testRoundTripPreservesClauseViaToFilterClause() {
        // The parse -> toFilterClause() round trip must reproduce the
        // original clause for well-formed builder-generated text, so
        // reopening the builder and immediately clicking Apply doesn't
        // silently change the active filter.
        let original = "qual>=30; filter=PASS; DP>=10"
        let rules = VariantQueryBuilderView.parseInitialRules(from: original)
        let roundTripped = rules.compactMap { $0.toFilterClause() }.joined(separator: "; ")
        XCTAssertEqual(roundTripped, original)
    }
}
