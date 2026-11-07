// FASTQDemultiplexPlanLaunch.swift - The Demux tab's plan as the custom definition Demultiplex Barcodes runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.3 lane DEMUXPLAN (D1b, L8, ruling ARCH-DEMUX-PLAN-CONTROL). The Demux tab built a plan that no run read
// (DEMUX-PLAN-NO-RUN). Demultiplex… writes the plan's one step into the project as a custom definition that keeps the
// plan kit's platform (a `# kit:` line), and opens Demultiplex Barcodes on it, where the person presses Run. The layout
// is in `docs/formats/barcode-definition.md`.

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// A plan that cannot run as one definition, in words a person reads.
struct DemultiplexPlanRefusal: LocalizedError, Equatable {
    let words: String
    var errorDescription: String? { words }
}

/// The plan's one step written as a custom barcode definition. Each row's ID is its output name, and its sample name
/// column keeps the name as typed.
struct DemultiplexPlanDefinition {
    let csvText: String

    /// The typed name of a row, trimmed, or nil when it is empty (ruling C4).
    private static func typedName(of assignment: FASTQSampleBarcodeAssignment) -> String? {
        let typed = assignment.sampleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? nil : typed
    }

    /// The output a row makes: the one sample-name sanitizer applied to its typed name, or to its sample ID.
    static func outputName(for assignment: FASTQSampleBarcodeAssignment) -> String {
        ONTPacBioBarcodeSampleNameResolver.sanitizedSampleIdentifier(typedName(of: assignment) ?? assignment.sampleID)
    }

    init(step: DemultiplexStep, kit: BarcodeKitDefinition) throws {
        guard !step.sampleAssignments.isEmpty else {
            throw DemultiplexPlanRefusal(words: "The plan has no samples. Add your samples' barcodes to the table, or press Detect to find them, then press Demultiplex\u{2026} again.")
        }
        let hasSecondary = kit.barcodes.contains { $0.i5Sequence != nil }
        var lines = BarcodeKitRegistry.kit(byID: kit.id) == nil ? [] : ["# kit: \(kit.id)"]
        lines.append(hasSecondary ? "id,sequence,secondary_sequence,sample_name" : "id,sequence,sample_name")
        var outputs: [String: String] = [:]
        for row in step.sampleAssignments {
            let typed = Self.typedName(of: row)
            let label = typed.map { "The sample name \($0)" } ?? "The unnamed sample of barcode \(row.sampleID)"
            if let typed, typed.contains(where: \.isNewline) {
                throw DemultiplexPlanRefusal(words: "The sample name \(typed.replacingOccurrences(of: "\n", with: " ")) holds a line break. Type the name on one line.")
            }
            if let forward = row.forwardBarcodeID, let reverse = row.reverseBarcodeID, forward != reverse {
                throw DemultiplexPlanRefusal(words: "\(label) pairs barcode \(forward) with \(reverse). Demultiplex\u{2026} runs samples that each carry one barcode. Give each sample one barcode, or run the kit from Demultiplex Barcodes, which names its outputs by barcode and not by the names in this table.")
            }
            let output = Self.outputName(for: row)
            if output.lowercased() == "unassigned" {
                throw DemultiplexPlanRefusal(words: "\(label) makes the output name \(output), the output that holds reads with no barcode. Choose another name.")
            }
            if let other = outputs[output.lowercased()] {
                throw DemultiplexPlanRefusal(words: "\(other) and \(label.prefix(1).lowercased() + label.dropFirst()) both make the output name \(output), so two samples would share one output. Change one of the names.")
            }
            outputs[output.lowercased()] = label
            let barcode = (row.forwardBarcodeID ?? row.reverseBarcodeID).flatMap { id in kit.barcodes.first { $0.id == id } }
            guard let sequence = barcode?.i7Sequence ?? row.forwardSequence, !sequence.isEmpty else {
                throw DemultiplexPlanRefusal(words: "\(label) has no barcode sequence. Choose its barcode in the table.")
            }
            var fields = [output, sequence]
            if hasSecondary {
                guard let secondary = barcode?.i5Sequence else {
                    throw DemultiplexPlanRefusal(words: "\(label) has no second index in \(kit.displayName). Choose one of the kit's barcodes in the table.")
                }
                fields.append(secondary)
            }
            fields.append(typed ?? "")
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        csvText = lines.joined(separator: "\n") + "\n"
    }

    /// A CSV field, quoted as RFC 4180 quotes one when it holds a comma, a quote or a tab.
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\t" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// What Demultiplex… opens: the plan's definition in the project and the dataset it splits.
@MainActor
struct FASTQDemultiplexPlanLaunch {
    let definitionURL: URL
    let inputURLs: [URL]
    let step: DemultiplexStep

    /// Writes the plan's definition into `<project>/Barcode Definitions/` only after every check passes. The file name
    /// carries the first 12 hex digits of the definition's SHA-256, so a definition is never rewritten: two datasets
    /// with one name get two files, and the same plan reuses its file (ruling C2).
    static func make(
        plan: DemultiplexPlan, kits: [BarcodeKitDefinition], datasetURL: URL?, projectURL: URL?
    ) throws -> Self {
        let steps = plan.steps.sorted { $0.ordinal < $1.ordinal }
        guard steps.count <= 1 else {
            throw DemultiplexPlanRefusal(words: "This dataset's saved plan holds \(steps.count) steps, and the Demux tab shows only the first. Demultiplex\u{2026} runs a plan of one step, so run each step from Demultiplex Barcodes with its own kit.")
        }
        guard plan.compositeSampleNames.isEmpty else {
            throw DemultiplexPlanRefusal(words: "This dataset's saved plan names samples across steps, which the Demux tab cannot show. Demultiplex\u{2026} runs a plan of one step, so run each step from Demultiplex Barcodes with its own kit.")
        }
        guard let step = steps.first, let datasetURL else {
            throw DemultiplexPlanRefusal(words: "There is no plan or dataset to demultiplex. Open a FASTQ dataset, set its plan in the Demux tab, then press Demultiplex\u{2026} again.")
        }
        guard let projectURL else {
            throw DemultiplexPlanRefusal(words: "This dataset is outside a project, so there is no project folder to keep the plan's barcode definition in. Add the dataset to a project, then press Demultiplex\u{2026} again.")
        }
        guard let kit = kits.first(where: { $0.id == step.barcodeKitID }) else {
            throw DemultiplexPlanRefusal(words: "The plan's kit \(step.barcodeKitID) is not a kit this version knows. Choose a kit in the Demux tab.")
        }
        let data = Data(try DemultiplexPlanDefinition(step: step, kit: kit).csvText.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12)
        let folder = projectURL.appendingPathComponent("Barcode Definitions", isDirectory: true)
        let name = "\(datasetURL.deletingPathExtension().lastPathComponent) demux plan \(digest).csv"
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DurableReplace.replace(data, named: name, in: folder)
        }
        return Self(definitionURL: url, inputURLs: [datasetURL], step: step)
    }

    /// Sets Demultiplex Barcodes to the plan's definition, location, error rate, distances and trim. The engine stays
    /// at the dialog's default, which writes no `--engine`, so the route owner chooses the route (L4, ruling C5).
    func configure(_ state: FASTQOperationDialogState) {
        state.demultiplexBarcodeSource = .customDefinition
        state.setAuxiliaryInput(definitionURL, for: .barcodeDefinition)
        switch step.barcodeLocation {
        case .fivePrime: state.demultiplexLocation = "5prime"
        case .threePrime: state.demultiplexLocation = "3prime"
        case .bothEnds: state.demultiplexLocation = "bothends"
        }
        state.demultiplexErrorRate = step.errorRate
        state.demultiplexMaxDistanceFrom5Prime = step.maxSearchDistance5Prime
        state.demultiplexMaxDistanceFrom3Prime = step.maxSearchDistance3Prime
        state.demultiplexTrimBarcodes = step.trimBarcodes
    }
}
