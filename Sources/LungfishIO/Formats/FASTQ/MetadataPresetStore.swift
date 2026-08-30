// MetadataPresetStore.swift - Hierarchical preset suggestions for metadata fields
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: "com.lungfish.io", category: "MetadataPresetStore")

// MARK: - MetadataPresetStore

/// Provides autocomplete / combo-box suggestions for metadata fields.
///
/// Presets are merged from three tiers:
/// 1. **Built-in**: Common values shipped with the app (e.g., common organisms, hosts).
/// 2. **User-level**: Persisted in the identity-aware managed storage root.
/// 3. **Project-level**: Persisted as `.lungfish-metadata-presets.json` in the project folder.
///
/// Higher tiers override lower ones. Suggestions are deduped and sorted.
public struct MetadataPresetStore: Sendable {

    /// File name for user-level presets.
    public static let userPresetsFilename = "metadata-presets.json"

    /// File name for project-level presets.
    public static let projectPresetsFilename = ".lungfish-metadata-presets.json"

    /// The merged presets, keyed by field name, each containing an array of suggestions.
    public let presets: [String: [String]]

    // MARK: - Initialization

    /// Creates a preset store by merging built-in, user, and project presets.
    ///
    /// - Parameters:
    ///   - projectDirectory: The project folder containing `.lungfish-metadata-presets.json`.
    ///     Pass `nil` if no project is open.
    public init(projectDirectory: URL? = nil) {
        var merged = Self.builtInPresets

        // Merge user-level presets
        if let userPresets = Self.loadUserPresets() {
            for (key, values) in userPresets {
                var existing = merged[key] ?? []
                existing.append(contentsOf: values)
                merged[key] = existing
            }
        }

        // Merge project-level presets
        if let projectDir = projectDirectory,
           let projectPresets = Self.loadProjectPresets(from: projectDir) {
            for (key, values) in projectPresets {
                var existing = merged[key] ?? []
                existing.append(contentsOf: values)
                merged[key] = existing
            }
        }

        // Deduplicate and sort each field's suggestions
        var deduped: [String: [String]] = [:]
        for (key, values) in merged {
            let unique = Array(Set(values)).sorted()
            deduped[key] = unique
        }
        self.presets = deduped
    }

    /// Returns suggestions for a given field name.
    public func suggestions(for field: String) -> [String] {
        presets[field] ?? []
    }

    // MARK: - Built-in Presets

    /// Common values shipped with the app for frequently used fields.
    public static let builtInPresets: [String: [String]] = [
        "organism": [
            "Homo sapiens",
            "SARS-CoV-2",
            "Influenza A virus",
            "Influenza B virus",
            "Respiratory syncytial virus",
            "Mycobacterium tuberculosis",
            "Staphylococcus aureus",
            "Escherichia coli",
            "Klebsiella pneumoniae",
            "Pseudomonas aeruginosa",
            "Salmonella enterica",
            "Clostridioides difficile",
            "Candida auris",
            "Aspergillus fumigatus",
            "human gut metagenome",
            "wastewater metagenome",
            "air metagenome",
            "soil metagenome",
            "freshwater metagenome",
            "marine metagenome",
        ],
        "host": [
            "Homo sapiens",
            "Mus musculus",
            "Rattus norvegicus",
            "Gallus gallus",
            "Sus scrofa",
            "Bos taurus",
            "Canis lupus familiaris",
            "Felis catus",
            "not applicable",
            "not collected",
        ],
        "geo_loc_name": [
            "USA",
            "USA:California",
            "USA:New York",
            "USA:Texas",
            "USA:Georgia:Atlanta",
            "United Kingdom",
            "Canada",
            "Australia",
            "Germany",
            "France",
            "Japan",
            "China",
            "Brazil",
            "India",
            "South Africa",
        ],
        "sample_type": [
            "Nasopharyngeal swab",
            "Oropharyngeal swab",
            "Blood",
            "Serum",
            "Plasma",
            "Stool",
            "Urine",
            "Sputum",
            "Bronchoalveolar lavage",
            "Tissue biopsy",
            "Cerebrospinal fluid",
            "Wastewater",
            "Soil",
            "Water",
            "Air filter",
        ],
        "purpose_of_sequencing": [
            "Diagnostic",
            "Surveillance",
            "Research",
            "Outbreak investigation",
            "Antimicrobial resistance",
            "Baseline surveillance",
        ],
        "library_strategy": [
            "WGS",
            "AMPLICON",
            "RNA-Seq",
            "WXS",
            "Targeted-Capture",
            "RANDOM",
        ],
        "collection_site_type": [
            "WWTP influent",
            "WWTP effluent",
            "Manhole",
            "Pump station",
            "Combined sewer overflow",
            "Storm drain",
        ],
        "sampling_method": [
            "Impactor (Andersen)",
            "Impactor (cascade)",
            "Filter (PTFE)",
            "Filter (gelatin)",
            "Cyclone",
            "Bioaerosol sampler",
            "Impinger (liquid)",
            "Settling plate",
        ],
        "indoor_outdoor": [
            "Indoor",
            "Outdoor",
            "Semi-enclosed",
        ],
        "environmental_medium": [
            "Soil",
            "Freshwater",
            "Seawater",
            "Sediment",
            "Ice",
            "Biofilm",
        ],
        "biome": [
            "Tropical forest",
            "Temperate forest",
            "Grassland",
            "Desert",
            "Tundra",
            "Wetland",
            "Marine",
            "Freshwater",
            "Urban",
            "Agricultural",
        ],
        "composite_vs_grab": [
            "Composite (24-hour)",
            "Composite (12-hour)",
            "Grab",
            "Moore swab",
        ],
        "patient_sex": [
            "Male",
            "Female",
            "Non-binary",
            "Not collected",
            "Not applicable",
        ],
        "hospitalization_status": [
            "Hospitalized",
            "Not hospitalized",
            "ICU",
            "Emergency department",
            "Not collected",
        ],
    ]

    // MARK: - File I/O

    /// URL for the user-level presets directory for a home and app identity.
    public static func userPresetsDirectory(
        homeDirectory: URL,
        appIdentity: LungfishAppIdentity
    ) -> URL {
        ManagedStorageLocation.defaultLocation(
            homeDirectory: homeDirectory,
            appIdentity: appIdentity
        ).rootURL
    }

    private static var defaultUserPresetsDirectory: URL {
        userPresetsDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            appIdentity: .current
        )
    }

    /// URL for the user-level presets file.
    private static var userPresetsURL: URL {
        defaultUserPresetsDirectory.appendingPathComponent(userPresetsFilename)
    }

    /// Loads user-level presets from the runtime identity's managed storage root.
    private static func loadUserPresets() -> [String: [String]]? {
        loadPresetsFile(at: userPresetsURL)
    }

    /// Loads project-level presets from the given directory.
    private static func loadProjectPresets(from directory: URL) -> [String: [String]]? {
        let url = directory.appendingPathComponent(projectPresetsFilename)
        return loadPresetsFile(at: url)
    }

    /// Loads a presets JSON file.
    private static func loadPresetsFile(at url: URL) -> [String: [String]]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: [String]].self, from: data)
        } catch {
            logger.warning("Failed to load presets from \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves custom suggestions to the user-level presets file.
    ///
    /// Merges with existing user presets, deduplicating values.
    public static func saveUserPreset(field: String, value: String) {
        var existing = loadUserPresets() ?? [:]
        var values = existing[field] ?? []
        if !values.contains(value) {
            values.append(value)
            values.sort()
        }
        existing[field] = values

        do {
            try FileManager.default.createDirectory(
                at: defaultUserPresetsDirectory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(existing)
            try data.write(to: userPresetsURL, options: .atomic)
        } catch {
            logger.error("Failed to save user preset: \(error.localizedDescription)")
        }
    }

    /// Saves custom suggestions to a project-level presets file.
    public static func saveProjectPreset(field: String, value: String, projectDirectory: URL) {
        let url = projectDirectory.appendingPathComponent(projectPresetsFilename)
        var existing = loadPresetsFile(at: url) ?? [:]
        var values = existing[field] ?? []
        if !values.contains(value) {
            values.append(value)
            values.sort()
        }
        existing[field] = values

        do {
            let data = try JSONEncoder().encode(existing)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save project preset: \(error.localizedDescription)")
        }
    }
}
