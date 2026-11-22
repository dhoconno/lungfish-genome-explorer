// FASTQOperationRNASeqQuantPane.swift - The settings of the quantify row of the FASTQ operations dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import Observation
import SwiftUI

/// A reference set under the storage root that the quantify pane can pick.
struct RNASeqQuantReferenceSetChoice: Identifiable, Equatable, Sendable {
    let id: String
    let species: String?

    var label: String {
        guard let species, !species.isEmpty else { return id }
        return "\(id) (\(species))"
    }
}

enum RNASeqQuantReferenceSets {
    /// The sets in `<storage root>/rnaseq-reference-sets`, by id. A folder a running build still holds starts with a dot
    /// and is not a set yet.
    static func choices(storageRoot: URL, fileManager: FileManager = .default) -> [RNASeqQuantReferenceSetChoice] {
        let folder = storageRoot.appendingPathComponent(ReferenceSetOwner.folderName, isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        let suffix = "." + ReferenceSetManifest.folderExtension
        return names
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(suffix) }
            .sorted()
            .map { name in
                let manifest = folder.appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(ReferenceSetManifest.filename)
                let species = (try? Data(contentsOf: manifest))
                    .flatMap { try? JSONDecoder().decode(ManifestSpecies.self, from: $0) }?.species
                return RNASeqQuantReferenceSetChoice(id: String(name.dropLast(suffix.count)), species: species)
            }
    }

    private struct ManifestSpecies: Decodable {
        var species: String?
    }
}

/// The options of `lungfish-cli rnaseq quant` as the CLI states them, so the pane shows the CLI's own defaults and a
/// test pins each line to the golden help (`Tests/Fixtures/golden/cli-help/lungfish-cli.rnaseq.quant.txt`).
enum RNASeqQuantDefaults {
    static let k = 31
    static let kHelp = "k-mer length of the index, an odd number up to 31 (default: 31)"
    static let decoysHelp = "genome (the default) for the index with the genome as decoys, or none"
    static let trimHelp = "Trim the reads with Trim Galore before salmon (default: not trimmed)"
    static let polyGHelp = "With --trim: on passes --poly_g to Trim Galore, off (the default) --no_poly_g"
    static let indexNote = "Lungfish counts on the reference set's own index and never builds one. A set without an index for these settings stops the run, and the Operations row says so."
}

/// The quantify row's settings, held beside the dialog state so the state file carries one property.
@MainActor
@Observable
final class RNASeqQuantDialogModel {
    var availableSets: [RNASeqQuantReferenceSetChoice] = []
    var referenceSetID: String?
    var k: Int = RNASeqQuantDefaults.k
    var decoys: RNASeqQuantRunRequest.Decoys = .genome
    var trim = false
    var polyGTrimming = false

    func refreshSets(storageRoot: URL = ManagedStorageConfigStore().currentLocation().rootURL) {
        availableSets = RNASeqQuantReferenceSets.choices(storageRoot: storageRoot)
        if let referenceSetID, !availableSets.contains(where: { $0.id == referenceSetID }) {
            self.referenceSetID = nil
        }
        if referenceSetID == nil, availableSets.count == 1 {
            referenceSetID = availableSets[0].id
        }
    }

    /// Each selection as the FASTQ bundle it names or lies in, once and in order. A file that lies in no bundle stays as
    /// it is and the readiness text refuses it.
    static func bundleURLs(from inputs: [URL]) -> [URL] {
        var seen = Set<String>()
        var bundles: [URL] = []
        for input in inputs {
            let bundle = isFASTQBundle(input) ? input : (SequenceInputResolver.enclosingFASTQBundleURL(for: input) ?? input)
            if seen.insert(bundle.standardizedFileURL.path).inserted { bundles.append(bundle) }
        }
        return bundles
    }

    static func isFASTQBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == FASTQBundle.directoryExtension
    }

    var kIsValid: Bool { k >= 1 && k <= 31 && k % 2 == 1 }

    /// The words that say why Run is off, or `nil` when the request can be made.
    func blockingMessage(inputs: [URL], projectURL: URL?) -> String? {
        if projectURL == nil { return "Open or create a project before counting RNA-seq reads." }
        let bundles = Self.bundleURLs(from: inputs)
        if bundles.isEmpty { return "Select at least one FASTQ bundle." }
        if !bundles.allSatisfy(Self.isFASTQBundle) {
            return "Quantification counts FASTQ bundles, one sample each. Import the reads as a FASTQ bundle first."
        }
        if availableSets.isEmpty { return "No reference set is installed under the storage root. Make one with lungfish-cli rnaseq reference-set and its index with lungfish-cli rnaseq index, then reopen this dialog." }
        if referenceSetID == nil { return "Choose a reference set." }
        if !kIsValid { return "k is an odd number up to 31." }
        return nil
    }

    func makeRequest(inputs: [URL], projectURL: URL?) -> RNASeqQuantRunRequest? {
        guard blockingMessage(inputs: inputs, projectURL: projectURL) == nil,
              let projectURL, let referenceSetID else { return nil }
        return RNASeqQuantRunRequest(
            bundleURLs: Self.bundleURLs(from: inputs), projectURL: projectURL, setID: referenceSetID,
            k: k, decoys: decoys, trim: trim, polyGTrimming: trim && polyGTrimming)
    }
}

struct RNASeqQuantPane: View {
    @Bindable var state: FASTQOperationDialogState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Inputs") {
                    Label(state.datasetLabel, systemImage: "doc.text").font(.body)
                }
                RNASeqQuantSettings(model: state.rnaSeqQuant)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .task { state.rnaSeqQuant.refreshSets() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RNASeqQuantSettings: View {
    @Bindable var model: RNASeqQuantDialogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Reference set") {
                Picker("Reference set", selection: $model.referenceSetID) {
                    Text("Choose a reference set").tag(String?.none)
                    ForEach(model.availableSets) { choice in
                        Text(choice.label).tag(String?.some(choice.id))
                    }
                }
                .accessibilityIdentifier("rnaseq-quant-reference-set")
                caption(RNASeqQuantDefaults.indexNote)
            }
            group("Index") {
                HStack {
                    Text("k-mer length")
                    TextField("k", value: $model.k, format: .number)
                        .frame(width: 60)
                        .accessibilityIdentifier("rnaseq-quant-k")
                }
                caption(RNASeqQuantDefaults.kHelp)
                Picker("Decoys", selection: $model.decoys) {
                    Text("Genome").tag(RNASeqQuantRunRequest.Decoys.genome)
                    Text("None").tag(RNASeqQuantRunRequest.Decoys.none)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("rnaseq-quant-decoys")
                caption(RNASeqQuantDefaults.decoysHelp)
            }
            group("Trimming") {
                Toggle("Trim with Trim Galore", isOn: $model.trim)
                    .accessibilityIdentifier("rnaseq-quant-trim")
                caption(RNASeqQuantDefaults.trimHelp)
                Picker("Poly-G trimming", selection: $model.polyGTrimming) {
                    Text("Off").tag(false)
                    Text("On").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!model.trim)
                .accessibilityIdentifier("rnaseq-quant-poly-g")
                caption(RNASeqQuantDefaults.polyGHelp)
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
