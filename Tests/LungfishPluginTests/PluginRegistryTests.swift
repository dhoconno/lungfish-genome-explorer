// PluginRegistryTests.swift - Safety-net tests for PluginRegistry
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPlugin

/// Tests for the plugin registry, verifying registration, querying,
/// duplicate detection, and built-in plugin loading.
///
/// PluginRegistry is `@MainActor`, so the test class is also `@MainActor`.
@MainActor
final class PluginRegistryTests: XCTestCase {

    // MARK: - Helpers

    /// A minimal concrete plugin for testing registration and queries.
    struct StubPlugin: Plugin {
        let id: String
        let name: String
        let version: String = "1.0.0"
        let description: String
        let category: PluginCategory
        let capabilities: PluginCapabilities
        var requiredAlphabet: SequenceAlphabet? = nil
        var minimumSequenceLength: Int = 0
        var iconName: String = "puzzlepiece.extension"
        var keyboardShortcut: KeyboardShortcut? = nil
    }

    /// A stub analysis plugin for type-specific registration tests.
    struct StubAnalysisPlugin: SequenceAnalysisPlugin {
        let id: String
        let name: String
        let version: String = "1.0.0"
        let description: String = "Stub analysis"
        let category: PluginCategory = .sequenceAnalysis
        let capabilities: PluginCapabilities = .standardAnalysis

        func analyze(_ input: AnalysisInput) async throws -> AnalysisResult {
            AnalysisResult(summary: "stub")
        }
    }

    /// A stub operation plugin for type-specific registration tests.
    struct StubOperationPlugin: SequenceOperationPlugin {
        let id: String
        let name: String
        let version: String = "1.0.0"
        let description: String = "Stub operation"
        let category: PluginCategory = .sequenceOperations
        let capabilities: PluginCapabilities = [.worksOnWholeSequence, .producesSequence]

        func transform(_ input: OperationInput) async throws -> OperationResult {
            OperationResult(sequence: input.sequence)
        }
    }

    /// A stub annotation generator plugin for type-specific registration tests.
    struct StubAnnotationPlugin: AnnotationGeneratorPlugin {
        let id: String
        let name: String
        let version: String = "1.0.0"
        let description: String = "Stub annotation generator"
        let category: PluginCategory = .annotationTools
        let capabilities: PluginCapabilities = .nucleotideAnnotator

        func generateAnnotations(_ input: AnnotationInput) async throws -> [AnnotationResult] {
            []
        }
    }

    // MARK: - Registration

    /// Registering a plugin should make it queryable by ID.
    func testRegisterPluginMakesItQueryableById() throws {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let plugin = StubPlugin(
            id: "com.test.register-by-id",
            name: "Test Plugin",
            description: "For testing",
            category: .utility,
            capabilities: []
        )
        try registry.register(plugin)

        let found = registry.plugin(withId: "com.test.register-by-id")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "com.test.register-by-id")
        XCTAssertEqual(found?.name, "Test Plugin")
    }

    /// Registering a plugin increments allPlugins count.
    func testRegisterPluginIncrementsCount() throws {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()
        let countBefore = registry.allPlugins.count

        let plugin = StubPlugin(
            id: "com.test.count-check",
            name: "Count Check",
            description: "For testing",
            category: .utility,
            capabilities: []
        )
        try registry.register(plugin)

        XCTAssertEqual(registry.allPlugins.count, countBefore + 1)
    }

    // MARK: - Duplicate Registration

    /// Registering a plugin with a duplicate ID should throw RegistryError.duplicatePluginId.
    func testRegisterDuplicatePluginIdThrows() throws {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let plugin1 = StubPlugin(
            id: "com.test.duplicate",
            name: "First",
            description: "First plugin",
            category: .utility,
            capabilities: []
        )
        let plugin2 = StubPlugin(
            id: "com.test.duplicate",
            name: "Second",
            description: "Duplicate ID",
            category: .utility,
            capabilities: []
        )

        try registry.register(plugin1)

        XCTAssertThrowsError(try registry.register(plugin2)) { error in
            guard case RegistryError.duplicatePluginId(let id) = error else {
                XCTFail("Expected RegistryError.duplicatePluginId, got \(error)")
                return
            }
            XCTAssertEqual(id, "com.test.duplicate")
        }
    }

    // MARK: - Query by ID

    /// Querying for a nonexistent plugin ID returns nil.
    func testQueryByNonexistentIdReturnsNil() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let result = registry.plugin(withId: "com.nonexistent.plugin")
        XCTAssertNil(result, "Nonexistent plugin ID should return nil")
    }

    // MARK: - Query by Category

    /// After loading built-ins, querying by category returns only plugins in that category.
    func testQueryByCategoryReturnsCorrectPlugins() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let annotationPlugins = registry.plugins(in: .annotationTools)
        for plugin in annotationPlugins {
            XCTAssertEqual(
                plugin.category, .annotationTools,
                "Plugin '\(plugin.name)' should be in annotationTools category"
            )
        }
        XCTAssertGreaterThan(annotationPlugins.count, 0, "Should have annotation tool plugins")
    }

    /// Querying an empty category returns an empty array, not nil.
    func testQueryByEmptyCategoryReturnsEmptyArray() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        // Visualization has no built-in plugins
        let vizPlugins = registry.plugins(in: .visualization)
        XCTAssertTrue(vizPlugins.isEmpty, "Visualization category should be empty for built-ins")
    }

    // MARK: - Query by Capabilities

    /// Plugins with .generatesAnnotations capability should be found.
    func testQueryByCapabilitiesReturnsMatchingPlugins() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let annotatorPlugins = registry.plugins(withCapabilities: .generatesAnnotations)
        XCTAssertGreaterThan(annotatorPlugins.count, 0, "Should find plugins with generatesAnnotations")
        for plugin in annotatorPlugins {
            XCTAssertTrue(
                plugin.capabilities.contains(.generatesAnnotations),
                "Plugin '\(plugin.name)' should have generatesAnnotations capability"
            )
        }
    }

    /// Querying for a capability no plugin has returns an empty array.
    func testQueryByUnusedCapabilityReturnsEmptyArray() throws {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        // supportsMultipleSequences is not used by any built-in plugin
        let plugins = registry.plugins(withCapabilities: .supportsMultipleSequences)
        XCTAssertTrue(plugins.isEmpty, "No built-in plugin supports supportsMultipleSequences")
    }

    // MARK: - Built-in Plugins Loading

    /// loadBuiltInPlugins should register a nonzero number of plugins.
    func testLoadBuiltInPluginsRegistersPlugins() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()
        XCTAssertGreaterThan(registry.allPlugins.count, 0, "Should load at least one built-in plugin")
    }

    /// The expected number of built-in plugins is 6 (per source code).
    func testBuiltInPluginCountIsSix() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()
        XCTAssertEqual(
            registry.allPlugins.count, 6,
            "Expected 6 built-in plugins: ReverseComplement, Translation, "
            + "SequenceStatistics, PatternSearch, ORFFinder, RestrictionSiteFinder"
        )
    }

    /// All built-in plugins should have unique IDs.
    func testAllBuiltInPluginsHaveUniqueIds() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let ids = registry.allPlugins.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count, "All plugin IDs must be unique")
    }

    /// All built-in plugins should have non-empty names.
    func testAllBuiltInPluginsHaveNonEmptyNames() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        for plugin in registry.allPlugins {
            XCTAssertFalse(
                plugin.name.isEmpty,
                "Plugin '\(plugin.id)' should have a non-empty name"
            )
        }
    }

    /// All built-in plugins should have non-empty descriptions.
    func testAllBuiltInPluginsHaveNonEmptyDescriptions() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        for plugin in registry.allPlugins {
            XCTAssertFalse(
                plugin.description.isEmpty,
                "Plugin '\(plugin.id)' should have a non-empty description"
            )
        }
    }

    /// All built-in plugins should have valid semantic version strings.
    func testAllBuiltInPluginsHaveValidVersionStrings() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let semverPattern = #"^\d+\.\d+\.\d+$"#
        for plugin in registry.allPlugins {
            XCTAssertTrue(
                plugin.version.range(of: semverPattern, options: .regularExpression) != nil,
                "Plugin '\(plugin.id)' version '\(plugin.version)' should be valid semver"
            )
        }
    }

    // MARK: - Active Categories

    /// After loading built-ins, activeCategories should be non-empty.
    func testActiveCategoriesAfterLoadingBuiltIns() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let active = registry.activeCategories
        XCTAssertGreaterThan(active.count, 0, "Should have at least one active category")
    }

    /// sequenceOperations category should be active (has ReverseComplement, Translation).
    func testSequenceOperationsCategoryIsActive() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let active = registry.activeCategories
        XCTAssertTrue(
            active.contains(.sequenceOperations),
            "sequenceOperations should be an active category"
        )
    }

    /// annotationTools category should be active (has ORFFinder, RestrictionSiteFinder).
    func testAnnotationToolsCategoryIsActive() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let active = registry.activeCategories
        XCTAssertTrue(
            active.contains(.annotationTools),
            "annotationTools should be an active category"
        )
    }

    // MARK: - Type-Specific Plugin Arrays

    /// analysisPlugins should contain SequenceStatistics after loading built-ins.
    func testAnalysisPluginsArrayPopulated() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        XCTAssertGreaterThan(registry.analysisPlugins.count, 0, "Should have analysis plugins")
        let statisticsPlugin = registry.analysisPlugin(withId: "com.lungfish.sequence-statistics")
        XCTAssertNotNil(statisticsPlugin, "SequenceStatistics analysis plugin should be found")
    }

    /// operationPlugins should contain ReverseComplement and Translation.
    func testOperationPluginsArrayPopulated() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        XCTAssertGreaterThan(registry.operationPlugins.count, 0, "Should have operation plugins")
        let rcPlugin = registry.operationPlugin(withId: "com.lungfish.reverse-complement")
        XCTAssertNotNil(rcPlugin, "ReverseComplement operation plugin should be found")
        let translatePlugin = registry.operationPlugin(withId: "com.lungfish.translation")
        XCTAssertNotNil(translatePlugin, "Translation operation plugin should be found")
    }

    /// annotationPlugins should contain ORFFinder and RestrictionSiteFinder.
    func testAnnotationPluginsArrayPopulated() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        XCTAssertGreaterThan(registry.annotationPlugins.count, 0, "Should have annotation plugins")
        let orfPlugin = registry.annotationPlugin(withId: "com.lungfish.orf-finder")
        XCTAssertNotNil(orfPlugin, "ORFFinder annotation plugin should be found")
        let restrictionPlugin = registry.annotationPlugin(withId: "com.lungfish.restriction-finder")
        XCTAssertNotNil(restrictionPlugin, "RestrictionSiteFinder annotation plugin should be found")
    }

    // MARK: - Unregister

    /// Unregistering a plugin removes it from all query paths.
    func testUnregisterRemovesPluginFromAllQueries() throws {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let plugin = StubAnalysisPlugin(id: "com.test.unregister-me", name: "Unregister Me")
        try registry.register(plugin)
        XCTAssertNotNil(registry.plugin(withId: "com.test.unregister-me"))

        registry.unregister(id: "com.test.unregister-me")

        XCTAssertNil(registry.plugin(withId: "com.test.unregister-me"))
        XCTAssertFalse(
            registry.allPlugins.contains(where: { $0.id == "com.test.unregister-me" }),
            "allPlugins should not contain unregistered plugin"
        )
        XCTAssertNil(
            registry.analysisPlugin(withId: "com.test.unregister-me"),
            "analysisPlugins should not contain unregistered plugin"
        )
    }

    // MARK: - loadBuiltInPlugins Idempotency

    /// Calling loadBuiltInPlugins twice should reset and reload, not double the count.
    func testLoadBuiltInPluginsIsIdempotent() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()
        let countFirst = registry.allPlugins.count

        registry.loadBuiltInPlugins()
        let countSecond = registry.allPlugins.count

        XCTAssertEqual(countFirst, countSecond, "loadBuiltInPlugins should reset before reloading")
    }

    // MARK: - Category Counts

    /// categoryCounts should return correct values for known categories.
    func testCategoryCountsMatchActualCounts() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        let counts = registry.categoryCounts
        for category in PluginCategory.allCases {
            let byQuery = registry.plugins(in: category).count
            XCTAssertEqual(
                counts[category], byQuery,
                "categoryCounts[\(category.rawValue)] should match plugins(in:) count"
            )
        }
    }

    // MARK: - Contextual Query

    /// plugins(for:hasSelection:sequenceLength:) filters by alphabet and selection.
    func testContextualPluginQueryFiltersCorrectly() {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        // Query for DNA, no selection, length 1000
        let dnaPlugins = registry.plugins(for: .dna, hasSelection: false, sequenceLength: 1000)
        for plugin in dnaPlugins {
            XCTAssertTrue(
                plugin.capabilities.contains(.worksOnWholeSequence),
                "Plugin '\(plugin.name)' must support whole-sequence when queried without selection"
            )
            if let required = plugin.requiredAlphabet {
                XCTAssertEqual(required, .dna, "Plugin '\(plugin.name)' required alphabet mismatch")
            }
        }
    }

    /// Contextual query respects requiredAlphabet when explicitly set.
    /// Note: built-in plugins like ORFFinder use capabilities (.requiresNucleotide)
    /// rather than requiredAlphabet, so they are NOT filtered out by alphabet in
    /// plugins(for:hasSelection:sequenceLength:). They rely on runtime validation
    /// inside generateAnnotations(). This test verifies that plugins which DO set
    /// requiredAlphabet are properly excluded from incompatible alphabet queries.
    func testContextualQueryRespectsRequiredAlphabetWhenSet() throws {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        // Register a plugin that explicitly requires DNA
        let dnaOnly = StubPlugin(
            id: "com.test.dna-only-contextual",
            name: "DNA Only",
            description: "DNA only plugin",
            category: .utility,
            capabilities: [.worksOnWholeSequence],
            requiredAlphabet: .dna
        )
        try registry.register(dnaOnly)

        // Query for protein -- the DNA-only plugin should be excluded
        let proteinPlugins = registry.plugins(for: .protein, hasSelection: false, sequenceLength: 1000)
        let dnaOnlyInResults = proteinPlugins.contains(where: { $0.id == "com.test.dna-only-contextual" })
        XCTAssertFalse(
            dnaOnlyInResults,
            "Plugin with requiredAlphabet=.dna should not appear in protein query"
        )

        // Query for DNA -- the DNA-only plugin should be included
        let dnaPlugins = registry.plugins(for: .dna, hasSelection: false, sequenceLength: 1000)
        let dnaOnlyInDNA = dnaPlugins.contains(where: { $0.id == "com.test.dna-only-contextual" })
        XCTAssertTrue(
            dnaOnlyInDNA,
            "Plugin with requiredAlphabet=.dna should appear in DNA query"
        )
    }

    /// Contextual query filters by minimumSequenceLength.
    func testContextualQueryRespectsMinimumSequenceLength() throws {
        let registry = PluginRegistry.shared
        registry.loadBuiltInPlugins()

        // Register a plugin with a high minimum length
        let longOnly = StubPlugin(
            id: "com.test.long-only",
            name: "Long Only",
            description: "Requires long sequences",
            category: .utility,
            capabilities: [.worksOnWholeSequence],
            minimumSequenceLength: 5000
        )
        try registry.register(longOnly)

        // Short sequence -- plugin should be excluded
        let shortResult = registry.plugins(for: .dna, hasSelection: false, sequenceLength: 100)
        let inShort = shortResult.contains(where: { $0.id == "com.test.long-only" })
        XCTAssertFalse(inShort, "Plugin with minimumSequenceLength=5000 should not appear for length 100")

        // Long sequence -- plugin should be included
        let longResult = registry.plugins(for: .dna, hasSelection: false, sequenceLength: 10000)
        let inLong = longResult.contains(where: { $0.id == "com.test.long-only" })
        XCTAssertTrue(inLong, "Plugin with minimumSequenceLength=5000 should appear for length 10000")
    }
}
