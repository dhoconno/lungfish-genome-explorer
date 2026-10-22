// RecipeRegistry.swift
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import os.log
import LungfishCore

// MARK: - RecipeRegistryV2

/// Loads built-in and user-defined recipes.
///
/// Named `RecipeRegistryV2` to avoid collision with the legacy `RecipeRegistry`
/// enum in `LungfishIO/Formats/FASTQ/ProcessingRecipe.swift`.
public enum RecipeRegistryV2 {

    private static let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "RecipeRegistryV2"
    )

    // MARK: - Built-in recipes

    /// Load built-in recipes from bundled workflow resources.
    public static func builtinRecipes() -> [Recipe] {
        guard let recipesDir = RecipeBundleAccessor.recipesDirectoryURL() else {
            logger.error("RecipeRegistryV2: Recipes directory not found in LungfishWorkflow bundle")
            return []
        }

        return loadRecipes(from: recipesDir).recipes
    }

    // MARK: - User recipes

    /// Load user recipes from the current app identity's Application Support directory.
    public static func userRecipes(
        appIdentity: LungfishAppIdentity = .current,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) -> [Recipe] {
        let userRecipesDir = userRecipesDirectoryURL(
            appIdentity: appIdentity,
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: userRecipesDir.path) else {
            return []
        }
        return loadRecipes(from: userRecipesDir, fileManager: fileManager).recipes
    }

    /// The recipe files, bundled and the user's, that did not load: a newer `formatVersion`, a switch that names no
    /// step, or bytes that are not a recipe. A name such a file holds then reads as refused, never as unknown (QA
    /// review of ruling BIO-PRESET, point 6). A given `applicationSupportDirectory` reads only that folder.
    public static func refusedRecipeFiles(
        appIdentity: LungfishAppIdentity = .current,
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) -> [RefusedRecipeFile] {
        var refused: [RefusedRecipeFile] = []
        if applicationSupportDirectory == nil, let recipesDir = RecipeBundleAccessor.recipesDirectoryURL() {
            refused += loadRecipes(from: recipesDir).refused
        }
        let userRecipesDir = userRecipesDirectoryURL(
            appIdentity: appIdentity,
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: userRecipesDir.path) {
            refused += loadRecipes(from: userRecipesDir, fileManager: fileManager).refused
        }
        return refused
    }

    public static func userRecipesDirectoryURL(
        appIdentity: LungfishAppIdentity = .current,
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let appSupport = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return appSupport
            .appendingPathComponent(appIdentity.applicationSupportDirectoryName)
            .appendingPathComponent("recipes")
    }

    // MARK: - Combined access

    /// All recipes (built-in + user), optionally filtered by platform.
    ///
    /// - Parameter platform: When non-nil, only recipes that list this platform
    ///   are returned.
    public static func allRecipes(platform: IngestionPlatform? = nil) -> [Recipe] {
        var recipes = builtinRecipes() + userRecipes()
        if let platform {
            recipes = recipes.filter { $0.platforms.contains(platform) }
        }
        return recipes
    }

    /// Find a recipe by its unique ID.
    ///
    /// Searches both built-in and user recipes; user recipes shadow built-in
    /// ones if their IDs collide.
    public static func recipe(id: String) -> Recipe? {
        allRecipes().first { $0.id == id }
    }

    // MARK: - Private helpers

    private static func loadRecipes(
        from directory: URL,
        fileManager: FileManager = .default
    ) -> (recipes: [Recipe], refused: [RefusedRecipeFile]) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return ([], [])
        }

        let decoder = JSONDecoder()
        var recipes: [Recipe] = []
        var refused: [RefusedRecipeFile] = []

        // Sorted by file name, so the help and the sheet list the recipes in one order on every volume.
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            var data = Data()
            do {
                data = try Data(contentsOf: url)
                var recipe = try decoder.decode(Recipe.self, from: data)
                recipe.sourceSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                recipes.append(recipe)
            } catch {
                let refusal = refusal(of: url.lastPathComponent, data: data, error: error)
                logger.warning("RecipeRegistryV2: \(refusal.reason, privacy: .public)")
                refused.append(refusal)
            }
        }

        return (recipes, refused)
    }

    /// The words a refused file reads with: its version when that is what refused it, otherwise the decoder's reason.
    private static func refusal(of fileName: String, data: Data, error: any Error) -> RefusedRecipeFile {
        struct Header: Decodable {
            let formatVersion: Int?
            let id: String?
        }
        let header = try? JSONDecoder().decode(Header.self, from: data)
        let reason: String
        if let versionError = error as? RecipeFormatVersionError {
            let versions = Recipe.supportedFormatVersions
            let advice = versionError.formatVersion > versions.upperBound
                ? "Update the app." : "No version of it reads this file."
            reason = "Recipe file \(fileName) has formatVersion \(versionError.formatVersion). This version of "
                + "Lungfish Genome Explorer reads formatVersion \(versions.lowerBound) to \(versions.upperBound). \(advice)"
        } else {
            reason = "Recipe file \(fileName) could not be read: \(error.localizedDescription)"
        }
        return RefusedRecipeFile(
            fileName: fileName, recipeID: header?.id, formatVersion: header?.formatVersion, reason: reason
        )
    }
}
