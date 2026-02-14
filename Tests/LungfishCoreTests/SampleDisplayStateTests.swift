// SampleDisplayStateTests.swift - Tests for sample display state model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SampleDisplayStateTests: XCTestCase {

    // MARK: - Default State

    func testDefaultStateShowsAllSamples() {
        let state = SampleDisplayState()
        let samples = ["S1", "S2", "S3"]
        let visible = state.visibleSamples(from: samples)
        XCTAssertEqual(visible, ["S1", "S2", "S3"])
    }

    func testDefaultStateProperties() {
        let state = SampleDisplayState()
        XCTAssertTrue(state.sortFields.isEmpty)
        XCTAssertTrue(state.filters.isEmpty)
        XCTAssertTrue(state.hiddenSamples.isEmpty)
        XCTAssertTrue(state.showGenotypeRows)
        XCTAssertEqual(state.rowHeight, 12)
        XCTAssertEqual(state.summaryBarHeight, 20)
    }

    // MARK: - Hidden Samples

    func testHiddenSamplesExcluded() {
        var state = SampleDisplayState()
        state.hiddenSamples = ["S2"]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"])
        XCTAssertEqual(visible, ["S1", "S3"])
    }

    func testHideAllSamples() {
        var state = SampleDisplayState()
        state.hiddenSamples = ["S1", "S2", "S3"]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"])
        XCTAssertTrue(visible.isEmpty)
    }

    func testHideNonexistentSample() {
        var state = SampleDisplayState()
        state.hiddenSamples = ["S99"]
        let visible = state.visibleSamples(from: ["S1", "S2"])
        XCTAssertEqual(visible, ["S1", "S2"])
    }

    // MARK: - Metadata Filtering

    func testEqualsFilter() {
        var state = SampleDisplayState()
        state.filters = [SampleFilter(field: "sex", op: .equals, value: "male")]

        let metadata: [String: [String: String]] = [
            "S1": ["sex": "male"],
            "S2": ["sex": "female"],
            "S3": ["sex": "Male"],  // case-insensitive
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S1", "S3"])
    }

    func testNotEqualsFilter() {
        var state = SampleDisplayState()
        state.filters = [SampleFilter(field: "status", op: .notEquals, value: "excluded")]

        let metadata: [String: [String: String]] = [
            "S1": ["status": "active"],
            "S2": ["status": "excluded"],
            "S3": ["status": "pending"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S1", "S3"])
    }

    func testContainsFilter() {
        var state = SampleDisplayState()
        state.filters = [SampleFilter(field: "population", op: .contains, value: "EUR")]

        let metadata: [String: [String: String]] = [
            "S1": ["population": "EUR_West"],
            "S2": ["population": "AFR_South"],
            "S3": ["population": "EUR_East"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S1", "S3"])
    }

    func testMultipleFiltersApplied() {
        var state = SampleDisplayState()
        state.filters = [
            SampleFilter(field: "sex", op: .equals, value: "male"),
            SampleFilter(field: "age", op: .contains, value: "adult"),
        ]

        let metadata: [String: [String: String]] = [
            "S1": ["sex": "male", "age": "adult"],
            "S2": ["sex": "male", "age": "juvenile"],
            "S3": ["sex": "female", "age": "adult"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S1"])
    }

    func testFilterMissingMetadataField() {
        var state = SampleDisplayState()
        state.filters = [SampleFilter(field: "sex", op: .equals, value: "male")]

        // S2 has no metadata at all
        let metadata: [String: [String: String]] = [
            "S1": ["sex": "male"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2"], metadata: metadata)
        XCTAssertEqual(visible, ["S1"])
    }

    // MARK: - Sorting

    func testSortByMetadataFieldAscending() {
        var state = SampleDisplayState()
        state.sortFields = [SortField(field: "population", ascending: true)]

        let metadata: [String: [String: String]] = [
            "S1": ["population": "EUR"],
            "S2": ["population": "AFR"],
            "S3": ["population": "CHN"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S2", "S3", "S1"])
    }

    func testSortByMetadataFieldDescending() {
        var state = SampleDisplayState()
        state.sortFields = [SortField(field: "population", ascending: false)]

        let metadata: [String: [String: String]] = [
            "S1": ["population": "EUR"],
            "S2": ["population": "AFR"],
            "S3": ["population": "CHN"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S1", "S3", "S2"])
    }

    func testMultiLevelSort() {
        var state = SampleDisplayState()
        state.sortFields = [
            SortField(field: "group", ascending: true),
            SortField(field: "id", ascending: true),
        ]

        let metadata: [String: [String: String]] = [
            "S1": ["group": "B", "id": "2"],
            "S2": ["group": "A", "id": "1"],
            "S3": ["group": "B", "id": "1"],
            "S4": ["group": "A", "id": "2"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3", "S4"], metadata: metadata)
        XCTAssertEqual(visible, ["S2", "S4", "S3", "S1"])
    }

    func testSortWithMissingMetadata() {
        var state = SampleDisplayState()
        state.sortFields = [SortField(field: "population", ascending: true)]

        let metadata: [String: [String: String]] = [
            "S1": ["population": "EUR"],
            // S2 has no metadata
            "S3": ["population": "AFR"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        // S2 has empty string for population, sorts before "AFR" and "EUR"
        XCTAssertEqual(visible, ["S2", "S3", "S1"])
    }

    // MARK: - Combined Operations

    func testFilterThenSort() {
        var state = SampleDisplayState()
        state.filters = [SampleFilter(field: "sex", op: .equals, value: "male")]
        state.sortFields = [SortField(field: "age", ascending: true)]

        let metadata: [String: [String: String]] = [
            "S1": ["sex": "male", "age": "30"],
            "S2": ["sex": "female", "age": "25"],
            "S3": ["sex": "male", "age": "20"],
        ]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S3", "S1"])
    }

    func testHiddenAndFilterCombined() {
        var state = SampleDisplayState()
        state.hiddenSamples = ["S1"]
        state.filters = [SampleFilter(field: "sex", op: .equals, value: "male")]

        let metadata: [String: [String: String]] = [
            "S1": ["sex": "male"],
            "S2": ["sex": "female"],
            "S3": ["sex": "male"],
        ]
        // S1 hidden, S2 filtered out, only S3 remains
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"], metadata: metadata)
        XCTAssertEqual(visible, ["S3"])
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        var state = SampleDisplayState()
        state.sortFields = [SortField(field: "population", ascending: false)]
        state.filters = [SampleFilter(field: "sex", op: .equals, value: "male")]
        state.hiddenSamples = ["S2", "S5"]
        state.showGenotypeRows = false
        state.rowHeight = 10
        state.summaryBarHeight = 40
        state.sampleOrder = ["S1", "S3", "S2"]
        state.displayNameField = "alias"

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SampleDisplayState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.sortFields.count, 1)
        XCTAssertEqual(decoded.sortFields[0].field, "population")
        XCTAssertFalse(decoded.sortFields[0].ascending)
        XCTAssertEqual(decoded.filters.count, 1)
        XCTAssertEqual(decoded.filters[0].op, .equals)
        XCTAssertEqual(decoded.hiddenSamples, ["S2", "S5"])
        XCTAssertFalse(decoded.showGenotypeRows)
        XCTAssertEqual(decoded.rowHeight, 10)
        XCTAssertEqual(decoded.summaryBarHeight, 40)
        XCTAssertEqual(decoded.sampleOrder, ["S1", "S3", "S2"])
        XCTAssertEqual(decoded.displayNameField, "alias")
    }

    func testCodableLegacyMigration() throws {
        // Simulate old format with rowHeightMode instead of rowHeight
        let json = """
        {"showGenotypeRows":true,"rowHeightMode":"squished","sortFields":[],"filters":[],"hiddenSamples":[]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SampleDisplayState.self, from: data)
        XCTAssertEqual(decoded.rowHeight, 2, "Legacy 'squished' should migrate to 2px")
        XCTAssertEqual(decoded.summaryBarHeight, 20, "Missing summaryBarHeight should default to 20")
    }

    func testCodableLegacyExpandedMigration() throws {
        let json = """
        {"showGenotypeRows":true,"rowHeightMode":"expanded","sortFields":[],"filters":[],"hiddenSamples":[]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SampleDisplayState.self, from: data)
        XCTAssertEqual(decoded.rowHeight, 10, "Legacy 'expanded' should migrate to 10px")
    }

    func testCodableLegacyAutomaticMigration() throws {
        let json = """
        {"showGenotypeRows":true,"rowHeightMode":"automatic","sortFields":[],"filters":[],"hiddenSamples":[]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SampleDisplayState.self, from: data)
        XCTAssertEqual(decoded.rowHeight, 12, "Legacy 'automatic' should migrate to 12px (default)")
    }

    func testCodableClampsOutOfRangeHeights() throws {
        let json = """
        {"showGenotypeRows":true,"rowHeight":999,"summaryBarHeight":-4,"sortFields":[],"filters":[],"hiddenSamples":[]}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SampleDisplayState.self, from: data)
        XCTAssertEqual(decoded.rowHeight, SampleDisplayState.maxRowHeight)
        XCTAssertEqual(decoded.summaryBarHeight, SampleDisplayState.minSummaryBarHeight)
    }

    // MARK: - SampleFilter.matches

    func testFilterMatchesEquals() {
        let filter = SampleFilter(field: "x", op: .equals, value: "test")
        XCTAssertTrue(filter.matches("test"))
        XCTAssertTrue(filter.matches("TEST"))
        XCTAssertTrue(filter.matches("Test"))
        XCTAssertFalse(filter.matches("testing"))
        XCTAssertFalse(filter.matches(""))
    }

    func testFilterMatchesNotEquals() {
        let filter = SampleFilter(field: "x", op: .notEquals, value: "excluded")
        XCTAssertTrue(filter.matches("active"))
        XCTAssertTrue(filter.matches(""))
        XCTAssertFalse(filter.matches("excluded"))
        XCTAssertFalse(filter.matches("Excluded"))
    }

    func testFilterMatchesContains() {
        let filter = SampleFilter(field: "x", op: .contains, value: "eur")
        XCTAssertTrue(filter.matches("EUR_West"))
        XCTAssertTrue(filter.matches("european"))
        XCTAssertFalse(filter.matches("AFR_South"))
        XCTAssertFalse(filter.matches(""))
    }

    // MARK: - GenotypeDisplayCall

    func testGenotypeCallColors() {
        // Modern theme colors (default)
        let homRef = GenotypeDisplayCall.homRef.color
        XCTAssertEqual(homRef.r, 0xD0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(homRef.g, 0xD0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(homRef.b, 0xD0 / 255.0, accuracy: 0.01)

        let het = GenotypeDisplayCall.het.color
        XCTAssertEqual(het.r, 0x3B / 255.0, accuracy: 0.01)
        XCTAssertEqual(het.g, 0x82 / 255.0, accuracy: 0.01)
        XCTAssertEqual(het.b, 0xC4 / 255.0, accuracy: 0.01)

        let homAlt = GenotypeDisplayCall.homAlt.color
        XCTAssertEqual(homAlt.r, 0x5B / 255.0, accuracy: 0.01)
        XCTAssertEqual(homAlt.g, 0x4B / 255.0, accuracy: 0.01)
        XCTAssertEqual(homAlt.b, 0xA8 / 255.0, accuracy: 0.01)

        let noCall = GenotypeDisplayCall.noCall.color
        XCTAssertEqual(noCall.r, 0xF0 / 255.0, accuracy: 0.01)
    }

    func testGenotypeCallIGVColors() {
        // IGV classic theme colors
        let igv = VariantColorTheme.igvClassic
        let homRef = GenotypeDisplayCall.homRef.themeColor(from: igv)
        XCTAssertEqual(homRef.r, 200/255, accuracy: 0.01)

        let het = GenotypeDisplayCall.het.themeColor(from: igv)
        XCTAssertEqual(het.r, 34/255, accuracy: 0.01)
        XCTAssertEqual(het.b, 253/255, accuracy: 0.01)

        let homAlt = GenotypeDisplayCall.homAlt.themeColor(from: igv)
        XCTAssertEqual(homAlt.g, 248/255, accuracy: 0.01)
    }

    func testGenotypeCallAllCases() {
        XCTAssertEqual(GenotypeDisplayCall.allCases.count, 4)
    }

    // MARK: - Row Height Defaults

    func testRowHeightDefaults() {
        let state = SampleDisplayState()
        XCTAssertEqual(state.rowHeight, 12)
        XCTAssertEqual(state.summaryBarHeight, 20)
    }

    func testRowHeightCustom() {
        let state = SampleDisplayState(rowHeight: 5, summaryBarHeight: 30)
        XCTAssertEqual(state.rowHeight, 5)
        XCTAssertEqual(state.summaryBarHeight, 30)
    }

    func testInitializerClampsRowAndSummaryHeight() {
        let state = SampleDisplayState(rowHeight: 0, summaryBarHeight: 200)
        XCTAssertEqual(state.rowHeight, SampleDisplayState.minRowHeight)
        XCTAssertEqual(state.summaryBarHeight, SampleDisplayState.maxSummaryBarHeight)
    }

    // MARK: - Sample Order

    func testSampleOrderApplied() {
        var state = SampleDisplayState()
        state.sampleOrder = ["S3", "S1", "S2"]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"])
        XCTAssertEqual(visible, ["S3", "S1", "S2"])
    }

    func testSampleOrderWithNewSamples() {
        var state = SampleDisplayState()
        state.sampleOrder = ["S2", "S1"]
        // S3 is new and not in sampleOrder — appended at end
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"])
        XCTAssertEqual(visible, ["S2", "S1", "S3"])
    }

    func testSampleOrderWithRemovedSamples() {
        var state = SampleDisplayState()
        state.sampleOrder = ["S3", "S99", "S1"]
        // S99 doesn't exist in allSamples — silently skipped
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"])
        XCTAssertEqual(visible, ["S3", "S1", "S2"])
    }

    func testSampleOrderNilUsesDefault() {
        let state = SampleDisplayState()
        XCTAssertNil(state.sampleOrder)
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"])
        XCTAssertEqual(visible, ["S1", "S2", "S3"])
    }

    // MARK: - Display Name Field

    func testDisplayNameFieldDefault() {
        let state = SampleDisplayState()
        XCTAssertNil(state.displayNameField)
    }

    func testDisplayNameFieldCodable() throws {
        let state = SampleDisplayState(displayNameField: "alias")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SampleDisplayState.self, from: data)
        XCTAssertEqual(decoded.displayNameField, "alias")
    }

    // MARK: - FilterOp

    func testFilterOpAllCases() {
        XCTAssertEqual(FilterOp.allCases.count, 3)
    }

    func testFilterOpRawValues() {
        XCTAssertEqual(FilterOp.equals.rawValue, "equals")
        XCTAssertEqual(FilterOp.notEquals.rawValue, "notEquals")
        XCTAssertEqual(FilterOp.contains.rawValue, "contains")
    }

    // MARK: - Empty Input

    func testEmptySampleList() {
        let state = SampleDisplayState()
        let visible = state.visibleSamples(from: [])
        XCTAssertTrue(visible.isEmpty)
    }

    func testEmptyMetadata() {
        var state = SampleDisplayState()
        state.sortFields = [SortField(field: "population", ascending: true)]
        let visible = state.visibleSamples(from: ["S1", "S2", "S3"])
        // Without metadata, sort is stable (all empty strings equal)
        XCTAssertEqual(visible.count, 3)
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = SampleDisplayState()
        let b = SampleDisplayState()
        XCTAssertEqual(a, b)

        var c = SampleDisplayState()
        c.showGenotypeRows = false
        XCTAssertNotEqual(a, c)
    }

    // MARK: - VariantSite

    func testVariantSiteInit() {
        let site = VariantSite(
            position: 100,
            ref: "A",
            alt: "G",
            variantType: "SNP",
            genotypes: [
                "S1": .het,
                "S2": .homAlt,
            ]
        )
        XCTAssertEqual(site.position, 100)
        XCTAssertEqual(site.ref, "A")
        XCTAssertEqual(site.alt, "G")
        XCTAssertEqual(site.variantType, "SNP")
        XCTAssertEqual(site.genotypes.count, 2)
        XCTAssertEqual(site.genotypes["S1"], .het)
    }

    // MARK: - GenotypeDisplayData

    func testGenotypeDisplayDataInit() {
        let data = GenotypeDisplayData(
            sampleNames: ["S1", "S2"],
            sites: [
                VariantSite(position: 100, ref: "A", alt: "G", variantType: "SNP", genotypes: [:])
            ],
            region: GenomicRegion(chromosome: "chr1", start: 0, end: 1000)
        )
        XCTAssertEqual(data.sampleNames.count, 2)
        XCTAssertEqual(data.sites.count, 1)
        XCTAssertEqual(data.region.chromosome, "chr1")
    }
}
