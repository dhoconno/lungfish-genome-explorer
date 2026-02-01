// PluginRegistry.swift - Plugin discovery and management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Plugin Architecture Lead (Role 15)

import Foundation

// MARK: - Plugin Registry

/// Central registry for all plugins in the application.
///
/// The registry discovers, loads, and manages plugins. It provides
/// access to plugins by category, capability, and ID.
///
/// ## Usage
/// ```swift
/// let registry = PluginRegistry.shared
///
/// // Get all analysis plugins
/// let analysisPlugins = registry.analysisPlugins
///
/// // Find a specific plugin
/// if let restriction = registry.plugin(withId: "com.lungfish.restriction-finder") {
///     // Use the plugin
/// }
///
/// // Get plugins for a category
/// let tools = registry.plugins(in: .sequenceAnalysis)
/// ```
@MainActor
public final class PluginRegistry: ObservableObject {

    // MARK: - Singleton

    /// Shared plugin registry instance.
    public static let shared = PluginRegistry()

    // MARK: - Published Properties

    /// All registered plugins
    @Published public private(set) var allPlugins: [any Plugin] = []

    /// Analysis plugins
    @Published public private(set) var analysisPlugins: [any SequenceAnalysisPlugin] = []

    /// Operation plugins
    @Published public private(set) var operationPlugins: [any SequenceOperationPlugin] = []

    /// Annotation generator plugins
    @Published public private(set) var annotationPlugins: [any AnnotationGeneratorPlugin] = []

    // MARK: - Storage

    /// Plugins indexed by ID
    private var pluginsById: [String: any Plugin] = [:]

    /// Plugins grouped by category
    private var pluginsByCategory: [PluginCategory: [any Plugin]] = [:]

    // MARK: - Initialization

    private init() {
        // Initialize category dictionary
        for category in PluginCategory.allCases {
            pluginsByCategory[category] = []
        }
    }

    // MARK: - Registration

    /// Registers a plugin with the registry.
    ///
    /// - Parameter plugin: The plugin to register
    /// - Throws: `RegistryError` if a plugin with the same ID is already registered
    public func register<P: Plugin>(_ plugin: P) throws {
        guard pluginsById[plugin.id] == nil else {
            throw RegistryError.duplicatePluginId(plugin.id)
        }

        pluginsById[plugin.id] = plugin
        allPlugins.append(plugin)
        pluginsByCategory[plugin.category, default: []].append(plugin)

        // Track by specific type
        if let analysis = plugin as? any SequenceAnalysisPlugin {
            analysisPlugins.append(analysis)
        }
        if let operation = plugin as? any SequenceOperationPlugin {
            operationPlugins.append(operation)
        }
        if let annotation = plugin as? any AnnotationGeneratorPlugin {
            annotationPlugins.append(annotation)
        }
    }

    /// Registers multiple plugins.
    public func register(_ plugins: [any Plugin]) throws {
        for plugin in plugins {
            try register(plugin)
        }
    }

    /// Unregisters a plugin by ID.
    public func unregister(id: String) {
        guard let plugin = pluginsById.removeValue(forKey: id) else { return }

        allPlugins.removeAll { $0.id == id }
        pluginsByCategory[plugin.category]?.removeAll { $0.id == id }

        // Remove from type-specific arrays
        analysisPlugins.removeAll { $0.id == id }
        operationPlugins.removeAll { $0.id == id }
        annotationPlugins.removeAll { $0.id == id }
    }

    // MARK: - Query

    /// Returns a plugin by its ID.
    public func plugin(withId id: String) -> (any Plugin)? {
        pluginsById[id]
    }

    /// Returns all plugins in a category.
    public func plugins(in category: PluginCategory) -> [any Plugin] {
        pluginsByCategory[category] ?? []
    }

    /// Returns plugins that have all specified capabilities.
    public func plugins(withCapabilities capabilities: PluginCapabilities) -> [any Plugin] {
        allPlugins.filter { $0.capabilities.contains(capabilities) }
    }

    /// Returns plugins that work with a specific alphabet.
    public func plugins(for alphabet: SequenceAlphabet) -> [any Plugin] {
        allPlugins.filter { plugin in
            guard let required = plugin.requiredAlphabet else { return true }
            return required == alphabet
        }
    }

    /// Returns plugins suitable for a given context.
    public func plugins(
        for alphabet: SequenceAlphabet,
        hasSelection: Bool,
        sequenceLength: Int
    ) -> [any Plugin] {
        allPlugins.filter { plugin in
            // Check alphabet
            if let required = plugin.requiredAlphabet, required != alphabet {
                return false
            }

            // Check minimum length
            if plugin.minimumSequenceLength > sequenceLength {
                return false
            }

            // Check selection capability
            if hasSelection && !plugin.capabilities.contains(.worksOnSelection) {
                return false
            }
            if !hasSelection && !plugin.capabilities.contains(.worksOnWholeSequence) {
                return false
            }

            return true
        }
    }

    // MARK: - Type-Safe Query

    /// Returns an analysis plugin by ID.
    public func analysisPlugin(withId id: String) -> (any SequenceAnalysisPlugin)? {
        analysisPlugins.first { $0.id == id }
    }

    /// Returns an operation plugin by ID.
    public func operationPlugin(withId id: String) -> (any SequenceOperationPlugin)? {
        operationPlugins.first { $0.id == id }
    }

    /// Returns an annotation plugin by ID.
    public func annotationPlugin(withId id: String) -> (any AnnotationGeneratorPlugin)? {
        annotationPlugins.first { $0.id == id }
    }

    // MARK: - Categories

    /// Returns all non-empty categories.
    public var activeCategories: [PluginCategory] {
        PluginCategory.allCases.filter { category in
            !(pluginsByCategory[category]?.isEmpty ?? true)
        }
    }

    /// Returns the count of plugins in each category.
    public var categoryCounts: [PluginCategory: Int] {
        var counts: [PluginCategory: Int] = [:]
        for category in PluginCategory.allCases {
            counts[category] = pluginsByCategory[category]?.count ?? 0
        }
        return counts
    }

    // MARK: - Built-in Plugin Loading

    /// Loads all built-in plugins.
    ///
    /// This method is called during app initialization to register
    /// all plugins that ship with the application.
    public func loadBuiltInPlugins() {
        // Clear existing plugins
        allPlugins.removeAll()
        analysisPlugins.removeAll()
        operationPlugins.removeAll()
        annotationPlugins.removeAll()
        pluginsById.removeAll()
        for category in PluginCategory.allCases {
            pluginsByCategory[category] = []
        }

        // Register built-in plugins
        do {
            // Sequence Operations
            try register(ReverseComplementPlugin())
            try register(TranslationPlugin())

            // Sequence Analysis
            try register(SequenceStatisticsPlugin())
            try register(PatternSearchPlugin())

            // Annotation Generators
            try register(ORFFinderPlugin())
            try register(RestrictionSiteFinderPlugin())

        } catch {
            // Log error but don't crash - some plugins may fail to load
            print("Warning: Failed to load built-in plugin: \(error)")
        }
    }
}

// MARK: - Registry Error

/// Errors that can occur during plugin registration.
public enum RegistryError: Error, LocalizedError {
    case duplicatePluginId(String)
    case pluginNotFound(String)
    case incompatiblePlugin(reason: String)

    public var errorDescription: String? {
        switch self {
        case .duplicatePluginId(let id):
            return "A plugin with ID '\(id)' is already registered"
        case .pluginNotFound(let id):
            return "Plugin with ID '\(id)' not found"
        case .incompatiblePlugin(let reason):
            return "Plugin is incompatible: \(reason)"
        }
    }
}

// MARK: - Plugin Descriptor

/// Describes a plugin for UI display.
public struct PluginDescriptor: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String
    public let category: PluginCategory
    public let capabilities: PluginCapabilities
    public let iconName: String

    public init(from plugin: any Plugin) {
        self.id = plugin.id
        self.name = plugin.name
        self.version = plugin.version
        self.description = plugin.description
        self.category = plugin.category
        self.capabilities = plugin.capabilities
        self.iconName = plugin.iconName
    }
}

// MARK: - Plugin Extensions

extension Plugin {
    /// Creates a descriptor for this plugin.
    public var descriptor: PluginDescriptor {
        PluginDescriptor(from: self)
    }
}
