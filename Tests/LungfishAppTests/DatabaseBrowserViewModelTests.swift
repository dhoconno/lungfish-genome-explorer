// DatabaseBrowserViewModelTests.swift - Unit tests for DatabaseBrowserViewModel
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// Unit tests for ``DatabaseBrowserViewModel``.
///
/// Tests cover:
/// - Initialization and default state
/// - Active filter count computation (Entrez vs virus)
/// - Clear filters resets all filter state
/// - Search term validation
/// - Virus completeness filter enum
/// - Filtered results (local text filtering with virus metadata)
/// - buildSearchTerm composition (via performSearch URL inspection)
@MainActor
final class DatabaseBrowserViewModelTests: XCTestCase {

    private var viewModel: DatabaseBrowserViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = DatabaseBrowserViewModel(source: .ncbi)
        // Clear any residual search history from UserDefaults to isolate tests
        viewModel.clearSearchHistory()
    }

    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
    }

    // MARK: - Initialization

    func testInitializationDefaults() {
        XCTAssertEqual(viewModel.ncbiSearchType, .nucleotide)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.searchScope, .all)
        XCTAssertFalse(viewModel.isAdvancedExpanded)
        XCTAssertEqual(viewModel.organismFilter, "")
        XCTAssertEqual(viewModel.locationFilter, "")
        XCTAssertEqual(viewModel.geneFilter, "")
        XCTAssertEqual(viewModel.authorFilter, "")
        XCTAssertEqual(viewModel.journalFilter, "")
        XCTAssertEqual(viewModel.minLength, "")
        XCTAssertEqual(viewModel.maxLength, "")
        XCTAssertFalse(viewModel.refseqOnly)
        XCTAssertEqual(viewModel.moleculeType, .any)
        XCTAssertEqual(viewModel.pubDateFrom, "")
        XCTAssertEqual(viewModel.pubDateTo, "")
        XCTAssertTrue(viewModel.propertyFilters.isEmpty)
    }

    func testVirusFilterDefaults() {
        XCTAssertEqual(viewModel.virusHostFilter, "")
        XCTAssertEqual(viewModel.virusGeoLocationFilter, "")
        XCTAssertEqual(viewModel.virusCompletenessFilter, .any)
        XCTAssertEqual(viewModel.virusReleasedSinceFilter, "")
        XCTAssertFalse(viewModel.virusAnnotatedOnly)
        XCTAssertNil(viewModel.virusNextPageToken)
    }

    func testResultDefaults() {
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertEqual(viewModel.totalResultCount, 0)
        XCTAssertFalse(viewModel.hasMoreResults)
        XCTAssertNil(viewModel.selectedRecord)
        XCTAssertTrue(viewModel.selectedRecords.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSourceIsPreserved() {
        let ncbiVM = DatabaseBrowserViewModel(source: .ncbi)
        XCTAssertTrue(ncbiVM.isNCBISearch)

        let enaVM = DatabaseBrowserViewModel(source: .ena)
        XCTAssertFalse(enaVM.isNCBISearch)
    }

    // MARK: - Search Text Validation

    func testSearchTextValidationEmpty() {
        viewModel.searchText = ""
        XCTAssertFalse(viewModel.isSearchTextValid)
    }

    func testSearchTextValidationWhitespace() {
        viewModel.searchText = "   "
        XCTAssertFalse(viewModel.isSearchTextValid)
    }

    func testSearchTextValidationNonEmpty() {
        viewModel.searchText = "SARS-CoV-2"
        XCTAssertTrue(viewModel.isSearchTextValid)
    }

    func testPathoplexusAllowsEmptySearchTextForBrowseMode() {
        let pathoplexusViewModel = DatabaseBrowserViewModel(source: .pathoplexus)
        pathoplexusViewModel.searchText = ""
        XCTAssertTrue(pathoplexusViewModel.isSearchTextValid)
    }

    func testSearchTextValidationWithLeadingSpaces() {
        viewModel.searchText = "  ebola  "
        XCTAssertTrue(viewModel.isSearchTextValid)
    }

    // MARK: - Active Filter Count (Entrez Mode)

    func testActiveFilterCountZeroByDefault() {
        viewModel.ncbiSearchType = .nucleotide
        XCTAssertEqual(viewModel.activeFilterCount, 0)
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    func testActiveFilterCountOrganismFilter() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.organismFilter = "Homo sapiens"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    func testActiveFilterCountLocationFilter() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.locationFilter = "USA"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountGeneFilter() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.geneFilter = "BRCA1"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountAuthorFilter() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.authorFilter = "Smith"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountJournalFilter() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.journalFilter = "Nature"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountLengthFilter() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.minLength = "100"
        XCTAssertEqual(viewModel.activeFilterCount, 1)

        viewModel.minLength = ""
        viewModel.maxLength = "50000"
        XCTAssertEqual(viewModel.activeFilterCount, 1)

        // Both min and max still count as 1 filter
        viewModel.minLength = "100"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountRefseqOnlyNucleotide() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.refseqOnly = true
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountMoleculeType() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.moleculeType = .genomicDNA
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountPubDateRange() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.pubDateFrom = "2024/01/01"
        XCTAssertEqual(viewModel.activeFilterCount, 1)

        viewModel.pubDateFrom = ""
        viewModel.pubDateTo = "2024/12/31"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountMultipleEntrezFilters() {
        viewModel.ncbiSearchType = .nucleotide
        viewModel.organismFilter = "Homo sapiens"
        viewModel.geneFilter = "TP53"
        viewModel.authorFilter = "Smith"
        viewModel.minLength = "1000"
        viewModel.refseqOnly = true
        XCTAssertEqual(viewModel.activeFilterCount, 5)
    }

    // MARK: - Active Filter Count (Virus Mode)

    func testActiveFilterCountVirusZeroByDefault() {
        viewModel.ncbiSearchType = .virus
        XCTAssertEqual(viewModel.activeFilterCount, 0)
    }

    func testActiveFilterCountVirusHostFilter() {
        viewModel.ncbiSearchType = .virus
        viewModel.virusHostFilter = "Homo sapiens"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountVirusGeoLocationFilter() {
        viewModel.ncbiSearchType = .virus
        viewModel.virusGeoLocationFilter = "USA"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountVirusCompletenessFilter() {
        viewModel.ncbiSearchType = .virus
        viewModel.virusCompletenessFilter = .complete
        XCTAssertEqual(viewModel.activeFilterCount, 1)

        viewModel.virusCompletenessFilter = .partial
        XCTAssertEqual(viewModel.activeFilterCount, 1)

        viewModel.virusCompletenessFilter = .any
        XCTAssertEqual(viewModel.activeFilterCount, 0)
    }

    func testActiveFilterCountVirusReleasedSince() {
        viewModel.ncbiSearchType = .virus
        viewModel.virusReleasedSinceFilter = "2024-01-01"
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountVirusAnnotatedOnly() {
        viewModel.ncbiSearchType = .virus
        viewModel.virusAnnotatedOnly = true
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountVirusRefseqOnly() {
        viewModel.ncbiSearchType = .virus
        viewModel.refseqOnly = true
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    func testActiveFilterCountVirusMultipleFilters() {
        viewModel.ncbiSearchType = .virus
        viewModel.virusHostFilter = "Homo sapiens"
        viewModel.virusGeoLocationFilter = "USA"
        viewModel.virusCompletenessFilter = .complete
        viewModel.virusReleasedSinceFilter = "2024-01-01"
        viewModel.virusAnnotatedOnly = true
        viewModel.refseqOnly = true
        XCTAssertEqual(viewModel.activeFilterCount, 6)
    }

    func testActiveFilterCountVirusIgnoresEntrezFilters() {
        // In virus mode, Entrez-specific filters should NOT be counted
        viewModel.ncbiSearchType = .virus
        viewModel.organismFilter = "Homo sapiens"
        viewModel.geneFilter = "TP53"
        viewModel.authorFilter = "Smith"
        XCTAssertEqual(viewModel.activeFilterCount, 0)
    }

    func testActiveFilterCountEntrezIgnoresVirusFilters() {
        // In nucleotide mode, virus-specific filters should NOT be counted
        viewModel.ncbiSearchType = .nucleotide
        viewModel.virusHostFilter = "Homo sapiens"
        viewModel.virusCompletenessFilter = .complete
        XCTAssertEqual(viewModel.activeFilterCount, 0)
    }

    // MARK: - Clear Filters

    func testClearFiltersResetsEntrezFilters() {
        viewModel.organismFilter = "Homo sapiens"
        viewModel.locationFilter = "USA"
        viewModel.geneFilter = "TP53"
        viewModel.authorFilter = "Smith"
        viewModel.journalFilter = "Nature"
        viewModel.minLength = "100"
        viewModel.maxLength = "50000"
        viewModel.refseqOnly = true
        viewModel.pubDateFrom = "2024/01/01"
        viewModel.pubDateTo = "2024/12/31"

        viewModel.clearFilters()

        XCTAssertEqual(viewModel.organismFilter, "")
        XCTAssertEqual(viewModel.locationFilter, "")
        XCTAssertEqual(viewModel.geneFilter, "")
        XCTAssertEqual(viewModel.authorFilter, "")
        XCTAssertEqual(viewModel.journalFilter, "")
        XCTAssertEqual(viewModel.minLength, "")
        XCTAssertEqual(viewModel.maxLength, "")
        XCTAssertFalse(viewModel.refseqOnly)
        XCTAssertEqual(viewModel.moleculeType, .any)
        XCTAssertEqual(viewModel.pubDateFrom, "")
        XCTAssertEqual(viewModel.pubDateTo, "")
        XCTAssertTrue(viewModel.propertyFilters.isEmpty)
    }

    func testClearFiltersResetsVirusFilters() {
        viewModel.virusHostFilter = "Homo sapiens"
        viewModel.virusGeoLocationFilter = "USA"
        viewModel.virusCompletenessFilter = .complete
        viewModel.virusReleasedSinceFilter = "2024-01-01"
        viewModel.virusAnnotatedOnly = true

        viewModel.clearFilters()

        XCTAssertEqual(viewModel.virusHostFilter, "")
        XCTAssertEqual(viewModel.virusGeoLocationFilter, "")
        XCTAssertEqual(viewModel.virusCompletenessFilter, .any)
        XCTAssertEqual(viewModel.virusReleasedSinceFilter, "")
        XCTAssertFalse(viewModel.virusAnnotatedOnly)
    }

    func testClearFiltersResetsAllFiltersCount() {
        viewModel.ncbiSearchType = .virus
        viewModel.virusHostFilter = "Homo sapiens"
        viewModel.virusCompletenessFilter = .complete
        viewModel.refseqOnly = true
        XCTAssertEqual(viewModel.activeFilterCount, 3)

        viewModel.clearFilters()
        XCTAssertEqual(viewModel.activeFilterCount, 0)
    }

    // MARK: - VirusCompletenessFilter

    func testVirusCompletenessFilterAllCases() {
        let allCases = VirusCompletenessFilter.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.any))
        XCTAssertTrue(allCases.contains(.complete))
        XCTAssertTrue(allCases.contains(.partial))
    }

    func testVirusCompletenessFilterRawValues() {
        XCTAssertEqual(VirusCompletenessFilter.any.rawValue, "Any")
        XCTAssertEqual(VirusCompletenessFilter.complete.rawValue, "Complete")
        XCTAssertEqual(VirusCompletenessFilter.partial.rawValue, "Partial")
    }

    func testVirusCompletenessFilterIdentifiable() {
        XCTAssertEqual(VirusCompletenessFilter.any.id, "Any")
        XCTAssertEqual(VirusCompletenessFilter.complete.id, "Complete")
        XCTAssertEqual(VirusCompletenessFilter.partial.id, "Partial")
    }

    func testVirusCompletenessFilterAPIValues() {
        XCTAssertNil(VirusCompletenessFilter.any.apiValue)
        XCTAssertEqual(VirusCompletenessFilter.complete.apiValue, "COMPLETE")
        XCTAssertEqual(VirusCompletenessFilter.partial.apiValue, "PARTIAL")
    }

    // MARK: - Filtered Results (Local Text Filtering)

    func testFilteredResultsReturnsAllWhenNoLocalFilter() {
        let records = [
            SearchResultRecord(id: "1", accession: "NC_045512.2", title: "SARS-CoV-2", source: .ncbi),
            SearchResultRecord(id: "2", accession: "NC_002549.1", title: "Ebola virus", source: .ncbi),
        ]
        viewModel.results = records
        viewModel.localFilterText = ""

        XCTAssertEqual(viewModel.filteredResults.count, 2)
    }

    func testFilteredResultsFiltersByAccession() {
        let records = [
            SearchResultRecord(id: "1", accession: "NC_045512.2", title: "SARS-CoV-2", source: .ncbi),
            SearchResultRecord(id: "2", accession: "NC_002549.1", title: "Ebola virus", source: .ncbi),
        ]
        viewModel.results = records
        viewModel.localFilterText = "045512"

        XCTAssertEqual(viewModel.filteredResults.count, 1)
        XCTAssertEqual(viewModel.filteredResults[0].accession, "NC_045512.2")
    }

    func testFilteredResultsFiltersByTitle() {
        let records = [
            SearchResultRecord(id: "1", accession: "NC_045512.2", title: "SARS-CoV-2", source: .ncbi),
            SearchResultRecord(id: "2", accession: "NC_002549.1", title: "Ebola virus", source: .ncbi),
        ]
        viewModel.results = records
        viewModel.localFilterText = "ebola"

        XCTAssertEqual(viewModel.filteredResults.count, 1)
        XCTAssertEqual(viewModel.filteredResults[0].title, "Ebola virus")
    }

    func testFilteredResultsFiltersByOrganism() {
        let records = [
            SearchResultRecord(id: "1", accession: "NC_045512.2", title: "Test", organism: "Severe acute respiratory syndrome coronavirus 2", source: .ncbi),
            SearchResultRecord(id: "2", accession: "NC_002549.1", title: "Test", organism: "Zaire ebolavirus", source: .ncbi),
        ]
        viewModel.results = records
        viewModel.localFilterText = "ebolavirus"

        XCTAssertEqual(viewModel.filteredResults.count, 1)
        XCTAssertEqual(viewModel.filteredResults[0].accession, "NC_002549.1")
    }

    func testFilteredResultsFiltersByHost() {
        let records = [
            SearchResultRecord(id: "1", accession: "A", title: "Test1", source: .ncbi, host: "Homo sapiens"),
            SearchResultRecord(id: "2", accession: "B", title: "Test2", source: .ncbi, host: "Gallus gallus"),
        ]
        viewModel.results = records
        viewModel.localFilterText = "gallus"

        XCTAssertEqual(viewModel.filteredResults.count, 1)
        XCTAssertEqual(viewModel.filteredResults[0].accession, "B")
    }

    func testFilteredResultsFiltersByGeoLocation() {
        let records = [
            SearchResultRecord(id: "1", accession: "A", title: "Test1", source: .ncbi, geoLocation: "USA: Minnesota"),
            SearchResultRecord(id: "2", accession: "B", title: "Test2", source: .ncbi, geoLocation: "China: Wuhan"),
        ]
        viewModel.results = records
        viewModel.localFilterText = "minnesota"

        XCTAssertEqual(viewModel.filteredResults.count, 1)
        XCTAssertEqual(viewModel.filteredResults[0].accession, "A")
    }

    func testFilteredResultsFiltersByIsolateName() {
        let records = [
            SearchResultRecord(id: "1", accession: "A", title: "Test1", source: .ncbi, isolateName: "Wuhan-Hu-1"),
            SearchResultRecord(id: "2", accession: "B", title: "Test2", source: .ncbi, isolateName: "Delta-variant-123"),
        ]
        viewModel.results = records
        viewModel.localFilterText = "delta"

        XCTAssertEqual(viewModel.filteredResults.count, 1)
        XCTAssertEqual(viewModel.filteredResults[0].accession, "B")
    }

    func testFilteredResultsFiltersByPangolinClassification() {
        let records = [
            SearchResultRecord(id: "1", accession: "A", title: "Test1", source: .ncbi, pangolinClassification: "B.1.1.7"),
            SearchResultRecord(id: "2", accession: "B", title: "Test2", source: .ncbi, pangolinClassification: "XFG.14.1.1"),
        ]
        viewModel.results = records
        viewModel.localFilterText = "xfg"

        XCTAssertEqual(viewModel.filteredResults.count, 1)
        XCTAssertEqual(viewModel.filteredResults[0].accession, "B")
    }

    func testFilteredResultsCaseInsensitive() {
        let records = [
            SearchResultRecord(id: "1", accession: "NC_045512.2", title: "SARS-CoV-2", source: .ncbi),
        ]
        viewModel.results = records
        viewModel.localFilterText = "SARS"

        XCTAssertEqual(viewModel.filteredResults.count, 1)

        viewModel.localFilterText = "sars"
        XCTAssertEqual(viewModel.filteredResults.count, 1)
    }

    // MARK: - Search History

    func testSaveSearchTermAddsToHistory() {
        viewModel.saveSearchTerm("SARS-CoV-2")

        XCTAssertEqual(viewModel.searchHistory.first, "SARS-CoV-2")
    }

    func testSaveSearchTermMovesExistingToFront() {
        viewModel.saveSearchTerm("Ebola")
        viewModel.saveSearchTerm("Influenza")
        viewModel.saveSearchTerm("Ebola")

        XCTAssertEqual(viewModel.searchHistory[0], "Ebola")
        XCTAssertEqual(viewModel.searchHistory[1], "Influenza")
        XCTAssertEqual(viewModel.searchHistory.count, 2)
    }

    func testSaveSearchTermIgnoresEmptyString() {
        viewModel.saveSearchTerm("")
        XCTAssertTrue(viewModel.searchHistory.isEmpty)

        viewModel.saveSearchTerm("   ")
        XCTAssertTrue(viewModel.searchHistory.isEmpty)
    }

    func testClearSearchHistory() {
        viewModel.saveSearchTerm("Test")
        XCTAssertFalse(viewModel.searchHistory.isEmpty)

        viewModel.clearSearchHistory()
        XCTAssertTrue(viewModel.searchHistory.isEmpty)
    }

    // MARK: - Autocomplete Suggestions

    func testAutocompleteSuggestionsWithNoInput() {
        viewModel.saveSearchTerm("SARS-CoV-2")
        viewModel.searchText = ""

        XCTAssertTrue(viewModel.autocompleteSuggestions.isEmpty)
    }

    func testAutocompleteSuggestionsWithMatchingPrefix() {
        viewModel.saveSearchTerm("SARS-CoV-2")
        viewModel.saveSearchTerm("SARS-CoV")
        viewModel.searchText = "SAR"

        XCTAssertEqual(viewModel.autocompleteSuggestions.count, 2)
    }

    func testAutocompleteSuggestionsExcludesExactMatch() {
        viewModel.saveSearchTerm("SARS-CoV-2")
        viewModel.searchText = "SARS-CoV-2"

        XCTAssertTrue(viewModel.autocompleteSuggestions.isEmpty)
    }

    // MARK: - Search Phase / Status

    func testIsSearchingReflectsSearchPhase() {
        XCTAssertFalse(viewModel.isSearching)
    }

    func testPerformSearchSetsErrorForEmptyText() {
        viewModel.searchText = ""
        viewModel.performSearch()

        XCTAssertEqual(viewModel.errorMessage, "Please enter a search term")
    }

    // MARK: - Cancel Search

    func testCancelSearchResetsPhase() {
        viewModel.cancelSearch()
        XCTAssertFalse(viewModel.isSearching)
    }

    // MARK: - Search Type Switching

    func testSwitchingSearchTypePreservesSearchText() {
        viewModel.searchText = "SARS-CoV-2"
        viewModel.ncbiSearchType = .virus

        XCTAssertEqual(viewModel.searchText, "SARS-CoV-2")
    }

    func testFilterCountRecomputesOnSearchTypeSwitch() {
        viewModel.virusHostFilter = "Homo sapiens"
        viewModel.organismFilter = "Homo sapiens"

        viewModel.ncbiSearchType = .virus
        XCTAssertEqual(viewModel.activeFilterCount, 1)

        viewModel.ncbiSearchType = .nucleotide
        XCTAssertEqual(viewModel.activeFilterCount, 1)
    }

    // MARK: - New Search Scopes

    func testSearchScopeIncludesBioProject() {
        XCTAssertNotNil(SearchScope.allCases.first(where: { $0 == .bioProject }))
        XCTAssertEqual(SearchScope.bioProject.rawValue, "BioProject")
    }

    func testSearchScopeIncludesAuthor() {
        XCTAssertNotNil(SearchScope.allCases.first(where: { $0 == .author }))
        XCTAssertEqual(SearchScope.author.rawValue, "Author")
    }

    func testBioProjectScopeHasIcon() {
        XCTAssertFalse(SearchScope.bioProject.icon.isEmpty)
    }

    func testAuthorScopeHasIcon() {
        XCTAssertFalse(SearchScope.author.icon.isEmpty)
    }

    func testBioProjectScopeHasHelpText() {
        XCTAssertFalse(SearchScope.bioProject.helpText.isEmpty)
    }

    func testAuthorScopeHasHelpText() {
        XCTAssertFalse(SearchScope.author.helpText.isEmpty)
    }

    func testAllScopesCount() {
        // all, accession, organism, title, bioProject, author = 6
        XCTAssertEqual(SearchScope.allCases.count, 6)
    }

    // MARK: - SRA Filter Properties

    func testSRAFilterDefaults() {
        let enaViewModel = DatabaseBrowserViewModel(source: .ena)
        XCTAssertEqual(enaViewModel.sraPlatformFilter, .any)
        XCTAssertEqual(enaViewModel.sraStrategyFilter, .any)
        XCTAssertEqual(enaViewModel.sraLayoutFilter, .any)
        XCTAssertEqual(enaViewModel.sraMinMbases, "")
        XCTAssertEqual(enaViewModel.sraPubDateFrom, "")
        XCTAssertEqual(enaViewModel.sraPubDateTo, "")
    }

    func testSRAFilterCountPlatform() {
        let enaViewModel = DatabaseBrowserViewModel(source: .ena)
        enaViewModel.sraPlatformFilter = .illumina
        XCTAssertEqual(enaViewModel.activeFilterCount, 1)
    }

    func testSRAFilterCountMultiple() {
        let enaViewModel = DatabaseBrowserViewModel(source: .ena)
        enaViewModel.sraPlatformFilter = .illumina
        enaViewModel.sraStrategyFilter = .wgs
        enaViewModel.sraLayoutFilter = .paired
        XCTAssertEqual(enaViewModel.activeFilterCount, 3)
    }

    func testClearFiltersClearsSRAFilters() {
        let enaViewModel = DatabaseBrowserViewModel(source: .ena)
        enaViewModel.sraPlatformFilter = .illumina
        enaViewModel.sraStrategyFilter = .wgs
        enaViewModel.sraLayoutFilter = .paired
        enaViewModel.sraMinMbases = "100"
        enaViewModel.clearFilters()
        XCTAssertEqual(enaViewModel.sraPlatformFilter, .any)
        XCTAssertEqual(enaViewModel.sraStrategyFilter, .any)
        XCTAssertEqual(enaViewModel.sraLayoutFilter, .any)
        XCTAssertEqual(enaViewModel.sraMinMbases, "")
    }
}
