// FASTQImportSheetRecipeOption.swift - Recipe presentation model of the Import FASTQ sheet
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// One switch of a recipe as the sheet's checkbox shows it: the recipe's label, and the value the chosen preset gives
/// it (the recipe default when the option names no preset). The checkbox starts at ``presetValue``.
public struct FASTQImportSheetSwitch: Sendable, Equatable {
    /// The switch id, such as `removeDuplicates`. The CLI option is its kebab-case form.
    public let id: String
    /// The checkbox title, such as "Remove duplicate reads".
    public let label: String
    public let presetValue: Bool

    public init(id: String, label: String, presetValue: Bool) {
        self.id = id
        self.label = label
        self.presetValue = presetValue
    }
}

/// Recipe presentation model used by the shared FASTQ import sheet.
public struct FASTQImportSheetRecipeOption: Sendable, Equatable {
    /// What `--recipe` receives: a preset's id for a preset of a recipe, otherwise the recipe's id.
    public let id: String
    public let name: String
    public let presentationText: String
    public let requiresBarcodeDefinition: Bool
    public let usesDemultiplexOutputFolder: Bool
    /// Whether the recipe writes merged reads beside read pairs in one file,
    /// which Trim Galore cannot store.
    public let outputMixesMergedReadsAndPairs: Bool
    /// The checkboxes the sheet shows under the picker, in the recipe's order. Empty for a recipe without switches.
    public let switches: [FASTQImportSheetSwitch]
    /// The recipe the option runs, kept so the Workflow line can follow the checkboxes (``descriptionText(switchValues:)``).
    private let switchRecipe: Recipe?

    public init(
        id: String,
        name: String,
        presentationText: String,
        requiresBarcodeDefinition: Bool = false,
        usesDemultiplexOutputFolder: Bool = false,
        outputMixesMergedReadsAndPairs: Bool = false
    ) {
        self.init(
            id: id,
            name: name,
            presentationText: presentationText,
            requiresBarcodeDefinition: requiresBarcodeDefinition,
            usesDemultiplexOutputFolder: usesDemultiplexOutputFolder,
            outputMixesMergedReadsAndPairs: outputMixesMergedReadsAndPairs,
            switches: [],
            switchRecipe: nil
        )
    }

    private init(
        id: String,
        name: String,
        presentationText: String,
        requiresBarcodeDefinition: Bool,
        usesDemultiplexOutputFolder: Bool,
        outputMixesMergedReadsAndPairs: Bool,
        switches: [FASTQImportSheetSwitch],
        switchRecipe: Recipe?
    ) {
        self.id = id
        self.name = name
        self.presentationText = presentationText
        self.requiresBarcodeDefinition = requiresBarcodeDefinition
        self.usesDemultiplexOutputFolder = usesDemultiplexOutputFolder
        self.outputMixesMergedReadsAndPairs = outputMixesMergedReadsAndPairs
        self.switches = switches
        self.switchRecipe = switchRecipe
    }

    /// The option for a recipe. A recipe the resolver resolved to a preset is that preset's option: it carries the
    /// preset's id, name and description, and its checkboxes start at the preset's values.
    public init(recipe: Recipe) {
        let preset = recipe.resolution?.preset
        let purpose = preset?.description ?? recipe.description
        let switches = recipe.switches.isEmpty ? [] : recipe.switchSettings.map {
            FASTQImportSheetSwitch(id: $0.id, label: $0.label, presetValue: $0.value)
        }
        self.init(
            id: preset?.id ?? recipe.id,
            name: preset?.name ?? recipe.name,
            presentationText: Self.makeDescription(purpose: purpose, recipe: recipe),
            requiresBarcodeDefinition: false,
            usesDemultiplexOutputFolder: false,
            outputMixesMergedReadsAndPairs: recipe.outputMixesMergedReadsAndPairs,
            switches: switches,
            switchRecipe: switches.isEmpty ? nil : recipe
        )
    }

    /// The picker's entries for a recipe: one for each preset of a recipe that has presets, named by the preset and
    /// passing its id to `--recipe`, and one for the recipe itself otherwise.
    public static func options(for recipe: Recipe) -> [FASTQImportSheetRecipeOption] {
        let presetOptions = recipe.presets
            .compactMap { try? RecipeResolver.resolve($0.id, in: [recipe]) }
            .map { FASTQImportSheetRecipeOption(recipe: $0) }
        return presetOptions.isEmpty ? [FASTQImportSheetRecipeOption(recipe: recipe)] : presetOptions
    }

    /// The description when the switches have `values` (switch id to value, and a switch not named keeps the preset's
    /// value). At the preset's own values it is ``presentationText``. When a switch differs, the preset's sentence no
    /// longer says what runs, so a plain "<name>, with <switch label> on." sentence takes its place above the Workflow
    /// line of the steps that run. The sheet shows this while the checkboxes change.
    public func descriptionText(switchValues values: [String: Bool]) -> String {
        guard let switchRecipe, !values.isEmpty,
              let resolved = try? RecipeResolver.resolve(id, in: [switchRecipe], switchOptions: values) else {
            return presentationText
        }
        let changed = switches.filter { gate in values[gate.id].map { $0 != gate.presetValue } ?? false }
        guard !changed.isEmpty else { return presentationText }
        let changes = changed.map { "\($0.label) \(values[$0.id] == true ? "on" : "off")" }
        return Self.makeDescription(purpose: "\(name), with \(changes.joined(separator: " and ")).", recipe: resolved)
    }

    private static func makeDescription(purpose: String?, recipe: Recipe) -> String {
        var lines: [String] = []
        if let purpose = purpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty {
            lines.append(purpose)
        }

        // The steps that run, so the line agrees with the description beside it (a switch that is off leaves its step out).
        let workflow = recipe.activeSteps
            .compactMap { $0.label ?? $0.type }
            .joined(separator: " \u{2192} ")
        lines.append("Workflow: \(workflow)")

        switch recipe.requiredInput {
        case .paired: lines.append("Input: paired-end reads")
        case .single: lines.append("Input: single-end reads")
        case .any: break
        }
        return lines.joined(separator: "\n")
    }

    public static let ontFluidigmSampleSplit = FASTQImportSheetRecipeOption(
        id: "ont-fluidigm-sample-split",
        name: "Split by Fluidigm sample barcodes",
        presentationText: [
            "Creates one counted .lungfishfastq bundle per sample using a Fluidigm barcode sample sheet.",
            "Workflow: detect CS1-CS2 insert \u{2192} assign Fluidigm sample barcode \u{2192} write counted sample FASTQ bundles",
            "Input: ONT run folder"
        ].joined(separator: "\n"),
        requiresBarcodeDefinition: true,
        usesDemultiplexOutputFolder: true
    )

    public static let ontPacBioBarcodeDemux = FASTQImportSheetRecipeOption(
        id: "ont-pacbio-barcode-demux",
        name: "Demultiplex full-length MHC ONT amplicons with PacBio barcodes",
        presentationText: [
            "Splits ONT FASTQ chunks with a PacBio barcode-pair sample sheet.",
            "Workflow: validate PacBio bc* pairs \u{2192} exact barcode demux \u{2192} write per-sample FASTQ bundles",
            "Input: ONT run folder"
        ].joined(separator: "\n"),
        requiresBarcodeDefinition: true,
        usesDemultiplexOutputFolder: true
    )
}
