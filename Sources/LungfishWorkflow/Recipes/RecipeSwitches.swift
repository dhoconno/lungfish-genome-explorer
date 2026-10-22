// RecipeSwitches.swift - The switches and presets of a formatVersion 2 recipe, and the resolver that picks them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

// MARK: - RecipeSwitch

/// A switch of a ``Recipe`` turns the one step whose `type` it names on or off (formatVersion 2, ruling BIO-PRESET
/// P3). A step no switch names always runs.
public struct RecipeSwitch: Codable, Sendable, Equatable {
    /// Stable identifier, such as `removeDuplicates`. The CLI option is its kebab-case form (``optionName``).
    public let id: String
    /// The words the sheet's checkbox, the record and the run's info line use.
    public let label: String
    /// The value when neither a preset nor an option sets the switch.
    public let defaultValue: Bool
    /// The `type` of the step the switch turns on or off.
    public let gates: String

    private enum CodingKeys: String, CodingKey {
        case id, label, defaultValue = "default", gates
    }

    public init(id: String, label: String, defaultValue: Bool, gates: String) {
        self.id = id
        self.label = label
        self.defaultValue = defaultValue
        self.gates = gates
    }

    /// The CLI option a switch reads, without its dashes: `removeRibosomalRNA` gives `remove-ribosomal-rna`, passed
    /// as `--remove-ribosomal-rna` or `--no-remove-ribosomal-rna`.
    public static func optionName(for switchID: String) -> String {
        var name = ""
        var previous: Character?
        for character in switchID {
            if character.isUppercase, let previous, previous.isLowercase {
                name.append("-")
            }
            name.append(contentsOf: character.lowercased())
            previous = character
        }
        return name
    }
}

// MARK: - RecipePreset

/// A named set of switch values of one ``Recipe``, such as `wastewater-metagenomics`. A switch the preset does not
/// name keeps the recipe default.
public struct RecipePreset: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public var description: String?
    /// Other ids that resolve to this preset, such as `vsp2`.
    public var aliases: [String]
    /// Switch id to value.
    public let switches: [String: Bool]

    private enum CodingKeys: String, CodingKey {
        case id, name, description, aliases, switches
    }

    public init(id: String, name: String, description: String? = nil, aliases: [String] = [], switches: [String: Bool]) {
        self.id = id
        self.name = name
        self.description = description
        self.aliases = aliases
        self.switches = switches
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        switches = try container.decodeIfPresent([String: Bool].self, forKey: .switches) ?? [:]
    }
}

// MARK: - RecipeResolution

/// What a `--recipe` name resolved to: the name as passed, the preset it named, and each switch's value with its
/// source. ``RecipeResolver`` sets it on the recipe it returns, and the record copies it.
public struct RecipeResolution: Sendable, Equatable {
    public let requestedName: String
    public let preset: RecipePreset?
    public let switchSettings: [RecipeSwitchSetting]

    public init(requestedName: String, preset: RecipePreset?, switchSettings: [RecipeSwitchSetting]) {
        self.requestedName = requestedName
        self.preset = preset
        self.switchSettings = switchSettings
    }
}

/// A file the registry read and refused, so that a name it holds reads as refused rather than unknown (QA review
/// point 6).
public struct RefusedRecipeFile: Sendable, Equatable {
    public let fileName: String
    /// The `id` the file holds, when it holds one.
    public let recipeID: String?
    public let formatVersion: Int?
    public let reason: String

    public init(fileName: String, recipeID: String?, formatVersion: Int?, reason: String) {
        self.fileName = fileName
        self.recipeID = recipeID
        self.formatVersion = formatVersion
        self.reason = reason
    }
}

// MARK: - Switch values of a recipe

extension Recipe {
    /// Each switch's value for this run, from ``resolution`` when the resolver set one and otherwise the recipe
    /// defaults.
    public var switchSettings: [RecipeSwitchSetting] {
        if let resolution { return resolution.switchSettings }
        return switches.map {
            RecipeSwitchSetting(id: $0.id, label: $0.label, value: $0.defaultValue, source: .recipeDefault)
        }
    }

    /// The setting that turns `step` off, or nil when the step runs.
    public func turnedOffSetting(for step: RecipeStep) -> RecipeSwitchSetting? {
        guard let gate = switches.first(where: { $0.gates == step.type }),
              let setting = switchSettings.first(where: { $0.id == gate.id }),
              !setting.value else {
            return nil
        }
        return setting
    }

    /// The steps that run, in order. A switch that is off leaves its step out.
    public var activeSteps: [RecipeStep] {
        steps.filter { turnedOffSetting(for: $0) == nil }
    }

    /// The steps a switch turned off, in recipe order, each with its setting and the number of steps that run
    /// before it, so a run records the step where it would have run (QA review point 9).
    var turnedOffSteps: [(activeStepsBefore: Int, step: RecipeStep, setting: RecipeSwitchSetting)] {
        var result: [(activeStepsBefore: Int, step: RecipeStep, setting: RecipeSwitchSetting)] = []
        var active = 0
        for step in steps {
            if let setting = turnedOffSetting(for: step) {
                result.append((active, step, setting))
            } else {
                active += 1
            }
        }
        return result
    }

    /// The options a replay passes after `--recipe` so the run's switches read the same: one for each switch an
    /// option set, never one for a preset's or the recipe's own value.
    public var switchOptionArguments: [String] {
        switchSettings.filter { $0.source == .option }.map {
            ($0.value ? "--" : "--no-") + RecipeSwitch.optionName(for: $0.id)
        }
    }

    /// The `--recipe` value a replay passes, the name the run was given.
    public var requestedName: String {
        resolution?.requestedName ?? id
    }

    /// The provenance parameters of the name passed, its preset and each switch, such as
    /// `recipeSwitch.removeDuplicates` = "on (preset)".
    var resolutionParameters: [String: ParameterValue] {
        var parameters: [String: ParameterValue] = [
            "recipeRequestedName": .string(requestedName),
            "recipePreset": resolution?.preset.map { .string($0.id) } ?? .null,
        ]
        for setting in switches.isEmpty ? [] : switchSettings {
            parameters["recipeSwitch.\(setting.id)"] = .string(
                "\(setting.value ? "on" : "off") (\(setting.source.displayName))"
            )
        }
        return parameters
    }

    /// The info lines a run prints: the preset a name resolved to, then one line per switch, such as
    /// "Remove ribosomal RNA reads: off (recipe default)" (UX review point 3).
    public var resolutionLines: [String] {
        var lines: [String] = []
        if let preset = resolution?.preset {
            lines.append("Recipe '\(requestedName)' runs \(id) with preset \(preset.id) (\(preset.name)).")
        }
        for setting in switchSettings {
            lines.append("\(setting.label): \(setting.value ? "on" : "off") (\(setting.source.displayName))")
        }
        return lines
    }

    /// Checks the switches and presets a decoded file holds, so a file whose switch names no step, or whose preset
    /// names no switch, is refused instead of running every step.
    func validateSwitches() throws {
        guard formatVersion >= 2 || (switches.isEmpty && presets.isEmpty) else {
            throw RecipeSwitchError("Recipe '\(id)' holds switches or presets, which need formatVersion 2.")
        }
        var seen = Set<String>()
        for gate in switches {
            guard seen.insert(gate.id).inserted else {
                throw RecipeSwitchError("Recipe '\(id)' declares switch '\(gate.id)' twice.")
            }
            guard steps.filter({ $0.type == gate.gates }).count == 1 else {
                throw RecipeSwitchError(
                    "Switch '\(gate.id)' of recipe '\(id)' must name exactly one step, and '\(gate.gates)' does not."
                )
            }
        }
        for preset in presets {
            for switchID in preset.switches.keys.sorted() where !seen.contains(switchID) {
                throw RecipeSwitchError("Preset '\(preset.id)' of recipe '\(id)' sets unknown switch '\(switchID)'.")
            }
        }
    }
}

/// Hands out the result of each step a switch turned off, where the step would have run, as a run records the steps
/// that ran (QA review point 9).
struct TurnedOffStepRecords {
    private let entries: [(activeStepsBefore: Int, result: RecipeStepResult)]
    private var next = 0
    private var activeStepsRecorded = 0

    init(recipe: Recipe, stepTypes: [String: any RecipeStepExecutor.Type]) {
        entries = recipe.turnedOffSteps.map { entry in
            let name = entry.step.label ?? stepTypes[entry.step.type]?.displayName ?? entry.step.type
            return (entry.activeStepsBefore, RecipeStepResult.turnedOff(stepName: name, by: entry.setting))
        }
    }

    /// The results that go before `plannedStep`'s record. A fused fastp call covers one recipe step per component.
    mutating func before(_ plannedStep: PlannedStep) -> [RecipeStepResult] {
        let results = taking(through: activeStepsRecorded)
        if case .fusedFastp(_, _, _, let components) = plannedStep {
            activeStepsRecorded += components.count
        } else {
            activeStepsRecorded += 1
        }
        return results
    }

    /// The results left after the last step that ran.
    mutating func remaining() -> [RecipeStepResult] {
        taking(through: .max)
    }

    private mutating func taking(through activeCount: Int) -> [RecipeStepResult] {
        var results: [RecipeStepResult] = []
        while next < entries.count, entries[next].activeStepsBefore <= activeCount {
            results.append(entries[next].result)
            next += 1
        }
        return results
    }
}

/// A recipe file whose switches or presets cannot be honoured.
public struct RecipeSwitchError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - RecipeResolver

/// Resolves a `--recipe` name to a recipe and its switch values (ruling BIO-PRESET P3).
///
/// A name matches by id only, in this order: a recipe's `id`, a preset's `id`, a preset's alias. A recipe's display
/// name never matches. An explicit switch option beats the preset, which beats the recipe default.
public enum RecipeResolver {

    /// - Parameters:
    ///   - name: The value passed, kept as given in the resolution.
    ///   - recipes: The recipes loaded.
    ///   - refused: The files the registry refused. A name that only a refused file holds throws
    ///     ``BatchImportError/unsupportedRecipe(_:reason:)`` with the refusal.
    ///   - switchOptions: Switch id to the value an option gave.
    /// - Returns: The recipe with ``Recipe/resolution`` set, or nil when no recipe or refused file holds the name.
    /// - Throws: ``RecipeResolutionError/unknownSwitch(_:recipeID:)`` for an option the recipe has no switch for.
    public static func resolve(
        _ name: String,
        in recipes: [Recipe],
        refused: [RefusedRecipeFile] = [],
        switchOptions: [String: Bool] = [:]
    ) throws -> Recipe? {
        let requested = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = requested.lowercased()
        guard let (recipe, preset) = match(key, in: recipes) else {
            if let refusal = refused.first(where: { $0.recipeID?.lowercased() == key }) {
                throw BatchImportError.unsupportedRecipe(requested, reason: refusal.reason)
            }
            return nil
        }
        for optionID in switchOptions.keys.sorted() where !recipe.switches.contains(where: { $0.id == optionID }) {
            throw RecipeResolutionError.unknownSwitch(optionID, recipeID: recipe.id)
        }
        let settings = recipe.switches.map { gate -> RecipeSwitchSetting in
            if let value = switchOptions[gate.id] {
                return RecipeSwitchSetting(id: gate.id, label: gate.label, value: value, source: .option)
            }
            if let value = preset?.switches[gate.id] {
                return RecipeSwitchSetting(id: gate.id, label: gate.label, value: value, source: .preset)
            }
            return RecipeSwitchSetting(id: gate.id, label: gate.label, value: gate.defaultValue, source: .recipeDefault)
        }
        var resolved = recipe
        resolved.resolution = RecipeResolution(requestedName: requested, preset: preset, switchSettings: settings)
        return resolved
    }

    /// Every name that resolves, in the order the help lists them: each recipe's id, then its presets' ids, then
    /// their aliases.
    public static func resolvableNames(in recipes: [Recipe]) -> [String] {
        var names: [String] = []
        for name in recipes.map(\.id) + recipes.flatMap({ $0.presets.map(\.id) })
            + recipes.flatMap({ $0.presets.flatMap(\.aliases) }) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private static func match(_ key: String, in recipes: [Recipe]) -> (Recipe, RecipePreset?)? {
        if let recipe = recipes.first(where: { $0.id.lowercased() == key }) {
            return (recipe, nil)
        }
        for recipe in recipes {
            if let preset = recipe.presets.first(where: { $0.id.lowercased() == key }) {
                return (recipe, preset)
            }
        }
        for recipe in recipes {
            if let preset = recipe.presets.first(where: { $0.aliases.contains { $0.lowercased() == key } }) {
                return (recipe, preset)
            }
        }
        return nil
    }
}

/// A switch option the resolved recipe cannot honour. It is refused by name, never ignored (UX review point 6).
public enum RecipeResolutionError: Error, LocalizedError, Equatable {
    case unknownSwitch(String, recipeID: String)

    public var errorDescription: String? {
        switch self {
        case .unknownSwitch(let switchID, let recipeID):
            let option = RecipeSwitch.optionName(for: switchID)
            return "Recipe '\(recipeID)' has no \(switchID) switch, so --\(option) and --no-\(option) do not apply to it. Nothing was imported."
        }
    }
}
