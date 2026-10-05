// PhylogeneticTreeInferenceSection.swift - the tree Inspector's Inference section and state builder (V2, V3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishPhylogeneticsUI
import SwiftUI

extension PhylogeneticTreeDocumentState {
    /// The Document inspector state for a tree bundle.
    init(bundle: PhylogeneticTreeBundle) {
        let manifest = bundle.manifest
        let rootedText = manifest.isRooted ? "rooted" : "unrooted"
        self.init(
            title: manifest.name,
            subtitle: "\(manifest.sourceFormat) • \(rootedText)",
            summary: "\(manifest.tipCount) tips • \(manifest.internalNodeCount) internal nodes",
            contextRows: [
                ("Tips", "\(manifest.tipCount)"),
                ("Internal Nodes", "\(manifest.internalNodeCount)"),
                ("Rooting", PhylogeneticTreeSupportPresentation.rootingText(isRooted: manifest.isRooted)),
                ("Source Format", manifest.sourceFormat),
                ("Primary Tree", manifest.primaryTreeID),
                ("Branch Unit", manifest.branchLengthUnit ?? "unspecified"),
                ("Source File", manifest.sourceFileName),
                ("Capabilities", manifest.capabilities.joined(separator: ", ")),
            ],
            warningRows: manifest.warnings,
            artifactRows: [
                ("Primary Newick", "tree/primary.nwk"),
                ("Normalized Tree", "tree/primary.normalized.json"),
                ("Tree Index", "cache/tree-index.sqlite"),
                ("Provenance", ".lungfish-provenance.json"),
            ].map { PhylogeneticTreeDocumentArtifactRow(label: $0.0, fileURL: bundle.url.appendingPathComponent($0.1)) },
            inferenceRows: manifest.inference.map {
                PhylogeneticTreeInferenceRows.rows(for: $0, manifest: manifest)
            } ?? [],
            inferenceArtifactRows: manifest.inference == nil ? [] : [
                PhylogeneticTreeDocumentArtifactRow(
                    label: "IQ-TREE Report",
                    fileURL: bundle.url.appendingPathComponent("artifacts/iqtree/run.iqtree")
                ),
                PhylogeneticTreeDocumentArtifactRow(
                    label: "IQ-TREE Log",
                    fileURL: bundle.url.appendingPathComponent("artifacts/iqtree/run.log")
                ),
            ]
        )
    }
}

/// The label and value rows of the Inference section, read from the manifest's inference summary.
enum PhylogeneticTreeInferenceRows {
    static func rows(
        for inference: PhylogeneticTreeInferenceSummary,
        manifest: PhylogeneticTreeManifest
    ) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Program", "\(inference.program) \(inference.programVersion)"),
            ("Model requested", requestedModelText(inference.requestedModel)),
            ("Best-fit model", bestFitModelText(inference)),
            ("Sequence type", sequenceTypeText(inference.sequenceType)),
            ("Branch support", branchSupportText(manifest.supportLabels ?? [])),
            ("Outgroup", inference.outgroup.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") } ?? "None"),
        ]
        if let warning = inference.outgroupWarning, !warning.isEmpty {
            rows.append(("Outgroup warning", warning))
        }
        rows.append(("Seed", inference.seed.map(String.init) ?? "Not recorded"))
        rows.append(("Threads", inference.threads.map(String.init) ?? "Not recorded"))
        rows.append(("Input", inputText(inference)))
        if let logLikelihood = inference.logLikelihood {
            var text = String(format: "%.4f", logLikelihood)
            if let standardError = inference.logLikelihoodStandardError {
                text += String(format: " (s.e. %.4f)", standardError)
            }
            rows.append(("Log-likelihood", text))
        }
        rows.append(("Branch lengths", manifest.branchLengthUnit ?? "unspecified"))
        return rows
    }

    static func requestedModelText(_ model: String) -> String {
        model.uppercased().hasPrefix("MFP") ? "\(model) (ModelFinder)" : model
    }

    /// The fitted model with its criterion, "Fixed" for a fixed model.
    static func bestFitModelText(_ inference: PhylogeneticTreeInferenceSummary) -> String {
        let usedModelFinder = inference.requestedModel.uppercased().hasPrefix("MFP")
        guard usedModelFinder else { return "Fixed" }
        guard let model = inference.substitutionModel ?? inference.bestFitModel else { return "Not recorded" }
        guard let criterion = inference.modelSelectionCriterion, !criterion.isEmpty else { return model }
        return "\(model) (\(criterion))"
    }

    static func sequenceTypeText(_ sequenceType: String) -> String {
        switch sequenceType.uppercased() {
        case "", "AUTO": return "Detected automatically"
        case "AA": return "Protein"
        case "CODON", "CODON1": return "Codon (Standard)"
        case "CODON2": return "Codon (Vertebrate mitochondrial)"
        default: return sequenceType
        }
    }

    static func branchSupportText(_ labels: [String]) -> String {
        guard !labels.isEmpty else { return "None" }
        return "\(labels.joined(separator: ", ")), labels read \(labels.joined(separator: "/"))"
    }

    static func inputText(_ inference: PhylogeneticTreeInferenceSummary) -> String {
        let name = inference.sourceAlignmentName ?? "Alignment"
        let columns: String
        if let selected = inference.selectedColumns, !selected.isEmpty {
            columns = selected.lowercased().hasPrefix("column") ? selected : "columns \(selected)"
        } else {
            columns = "all columns"
        }
        return "\(name), \(inference.selectedRowCount) of \(inference.totalRowCount) sequences, \(columns)"
    }

    /// What VoiceOver reads for one row.
    static func accessibilityText(label: String, value: String) -> String {
        "\(label), \(value)"
    }
}

struct PhylogeneticTreeInferenceSection: View {
    let rows: [(String, String)]
    let artifactRows: [PhylogeneticTreeDocumentArtifactRow]

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Inference", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    inferenceRow(label: row.0, value: row.1)
                }
                ForEach(Array(artifactRows.enumerated()), id: \.offset) { _, row in
                    PhylogeneticTreeArtifactRowView(row: row)
                }
            }
            .padding(.top, 4)
        }
        .font(LungfishInspectorStyle.controlFont.weight(.semibold))
    }

    private func inferenceRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(LungfishInspectorStyle.controlFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 112, alignment: .trailing)
            Text(value)
                .font(LungfishInspectorStyle.controlFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PhylogeneticTreeInferenceRows.accessibilityText(label: label, value: value))
    }
}

/// One tree artifact link. A present file reveals in Finder, a missing one reads as plain text.
struct PhylogeneticTreeArtifactRowView: View {
    let row: PhylogeneticTreeDocumentArtifactRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fileURL = row.fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                Button(row.label) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .buttonStyle(.link)
                .font(LungfishInspectorStyle.controlFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Reveal in Finder")
                pathCaption(fileURL.path)
            } else {
                Text(row.label)
                    .font(LungfishInspectorStyle.controlFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pathCaption(row.fileURL?.path ?? "Missing")
            }
        }
    }

    private func pathCaption(_ text: String) -> some View {
        Text(text)
            .font(LungfishInspectorStyle.controlFont)
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
