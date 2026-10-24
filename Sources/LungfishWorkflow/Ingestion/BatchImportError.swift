// BatchImportError.swift - Errors thrown by the batch FASTQ importer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Errors thrown by the batch importer.
public enum BatchImportError: Error, LocalizedError {
    case noFASTQFilesFound(URL)
    case unknownRecipe(String)
    case unsupportedRecipe(String, reason: String)
    case unsupportedRecipeStep(recipe: String, step: String)
    case projectNotFound(URL)
    case recipeNotApplicable(recipe: String, sample: String, reason: String)
    case outputBundleAlreadyExists(URL)
    case statisticsUnavailable(String)
    case recipeArtifactMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .noFASTQFilesFound(let url):
            return "No FASTQ or BAM read files found in \(url.lastPathComponent)"
        case .unknownRecipe(let name):
            let valid = Self.resolvableRecipeNames().joined(separator: ", ")
            return "Unknown recipe '\(name)'. Valid names: \(valid), or none"
        case .unsupportedRecipe(let name, let reason):
            return "Unsupported recipe '\(name)': \(reason)"
        case .unsupportedRecipeStep(let recipe, let step):
            return "Legacy batch import cannot execute recipe '\(recipe)' because it contains unsupported step '\(step)'."
        case .projectNotFound(let url):
            return "No .lungfish project found at or above \(url.path)"
        case .recipeNotApplicable(let recipe, let sample, let reason):
            return "Recipe '\(recipe)' cannot be applied to sample '\(sample)': \(reason)"
        case .outputBundleAlreadyExists(let url):
            return "Output FASTQ bundle already exists: \(url.path). Use --force to replace it."
        case .statisticsUnavailable(let reason):
            return "FASTQ statistics could not be computed: \(reason)"
        case .recipeArtifactMissing(let url):
            return "Recipe step artifact is missing and cannot be retained: \(url.path)"
        }
    }
}

extension BatchImportError {
    /// The legacy recipes `--recipe` accepts when no recipe file matches the name.
    public static let legacyRecipeNames: [String] = ["wgs", "hifi"]

    /// Every `--recipe` value that resolves, in the order `import fastq --help` lists them: the recipe files' own
    /// IDs, then their presets' IDs, then the presets' aliases, then the legacy names. An alias is listed only while
    /// the recipe file that holds it is loaded. `none`, which skips the recipe, is not in the list. The help and the
    /// unknown-recipe error both read this list, so neither can go stale when a recipe file is added.
    public static func resolvableRecipeNames(recipes: [Recipe] = RecipeRegistryV2.allRecipes()) -> [String] {
        var names = RecipeResolver.resolvableNames(in: recipes)
        for legacy in legacyRecipeNames where !names.contains(legacy) {
            names.append(legacy)
        }
        return names
    }
}
