// FASTQImportSheetRecipeOption.swift - Recipe presentation model of the Import FASTQ sheet
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

/// Recipe presentation model used by the shared FASTQ import sheet.
public struct FASTQImportSheetRecipeOption: Sendable, Equatable {
    public let id: String
    public let name: String
    public let presentationText: String
    public let requiresBarcodeDefinition: Bool
    public let usesDemultiplexOutputFolder: Bool
    /// Whether the recipe writes merged reads beside read pairs in one file,
    /// which Trim Galore cannot store.
    public let outputMixesMergedReadsAndPairs: Bool

    public init(
        id: String,
        name: String,
        presentationText: String,
        requiresBarcodeDefinition: Bool = false,
        usesDemultiplexOutputFolder: Bool = false,
        outputMixesMergedReadsAndPairs: Bool = false
    ) {
        self.id = id
        self.name = name
        self.presentationText = presentationText
        self.requiresBarcodeDefinition = requiresBarcodeDefinition
        self.usesDemultiplexOutputFolder = usesDemultiplexOutputFolder
        self.outputMixesMergedReadsAndPairs = outputMixesMergedReadsAndPairs
    }

    public init(recipe: Recipe) {
        var lines: [String] = []
        if let purpose = recipe.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !purpose.isEmpty {
            lines.append(purpose)
        }

        let workflow = recipe.steps
            .compactMap { $0.label ?? $0.type }
            .joined(separator: " \u{2192} ")
        lines.append("Workflow: \(workflow)")

        switch recipe.requiredInput {
        case .paired: lines.append("Input: paired-end reads")
        case .single: lines.append("Input: single-end reads")
        case .any: break
        }

        self.init(
            id: recipe.id,
            name: recipe.name,
            presentationText: lines.joined(separator: "\n"),
            outputMixesMergedReadsAndPairs: recipe.outputMixesMergedReadsAndPairs
        )
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
