// PhylogeneticTreeInferenceSectionTests.swift - tree Inspector Inference section and rooting row (V2, V3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class PhylogeneticTreeInferenceSectionTests: XCTestCase {
    func testInferredTreeShowsTheInferenceSectionBeforeTreeSummary() throws {
        let bundle = try makeBundle(inference: sarcopterygianInference())
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.updatePhylogeneticTreeDocument(bundle)

        let state = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.phylogeneticTreeDocument)
        XCTAssertEqual(state.visibleSectionOrder, [.header, .inference, .treeSummary, .warnings, .sourceArtifacts])
        let rows = Dictionary(uniqueKeysWithValues: state.inferenceRows)
        XCTAssertEqual(state.inferenceRows.map(\.0), [
            "Program", "Model requested", "Best-fit model", "Model of substitution", "Sequence type", "Branch support",
            "Outgroup", "Outgroup warning", "Seed", "Threads", "Input", "Log-likelihood", "Branch lengths",
        ])
        XCTAssertEqual(rows["Program"], "IQ-TREE 3.1.3")
        XCTAssertEqual(rows["Model requested"], "MFP (ModelFinder)")
        XCTAssertEqual(rows["Best-fit model"], "TIM2+ASC (BIC)")
        XCTAssertEqual(rows["Model of substitution"], "TIM2+F+ASC")
        XCTAssertEqual(rows["Sequence type"], "DNA")
        XCTAssertEqual(rows["Branch support"], "SH-aLRT 1000, UFBoot 1000. Node labels read SH-aLRT/UFBoot.")
        XCTAssertEqual(rows["Outgroup"], "Danio rerio")
        XCTAssertEqual(rows["Outgroup warning"], "Outgroup is not monophyletic. The tree is left unrooted.")
        XCTAssertEqual(rows["Seed"], "12345")
        XCTAssertEqual(rows["Threads"], "1")
        XCTAssertEqual(rows["Input"], "sarcopterygians, 5 of 6 sequences, columns 1-48")
        XCTAssertEqual(rows["Log-likelihood"], "-173.4941 (s.e. 7.9018)")
        XCTAssertEqual(rows["Branch lengths"], "substitutions per site")
        XCTAssertEqual(state.inferenceArtifactRows.map(\.label), ["IQ-TREE Report", "IQ-TREE Log"])
        XCTAssertEqual(state.inferenceArtifactRows.map(\.fileURL), [
            bundle.url.appendingPathComponent("artifacts/iqtree/run.iqtree"),
            bundle.url.appendingPathComponent("artifacts/iqtree/run.log"),
        ])
    }

    func testUnrootedTreeRootingRowNamesTheArbitraryRoot() throws {
        let bundle = try makeBundle(inference: sarcopterygianInference())
        XCTAssertFalse(bundle.manifest.isRooted)

        let state = PhylogeneticTreeDocumentState(bundle: bundle)

        XCTAssertTrue(state.contextRows.contains { $0.0 == "Rooting" && $0.1 == "Unrooted (drawn root is arbitrary)" })
    }

    func testImportedTreeWithoutInferenceHasNoInferenceSection() throws {
        let bundle = try makeBundle(inference: nil, newick: "((A:0.1,B:0.2)90:0.3,C:0.4);\n")

        let state = PhylogeneticTreeDocumentState(bundle: bundle)

        XCTAssertTrue(state.inferenceRows.isEmpty)
        XCTAssertTrue(state.inferenceArtifactRows.isEmpty)
        XCTAssertEqual(state.visibleSectionOrder, [.header, .treeSummary, .warnings, .sourceArtifacts])
        XCTAssertTrue(state.contextRows.contains { $0.0 == "Rooting" && $0.1 == "Rooted" })
    }

    func testFixedModelAndAllColumnsWording() throws {
        let inference = PhylogeneticTreeInferenceSummary(
            program: "IQ-TREE",
            programVersion: "3.1.3",
            requestedModel: "HKY+F+G4",
            substitutionModel: "HKY+F+G4",
            sequenceType: "CODON2",
            selectedRowCount: 6,
            totalRowCount: 6,
            alignedLength: 48
        )
        let fixedRows = PhylogeneticTreeInferenceRows.rows(for: inference, manifest: try makeBundle(inference: inference).manifest)
        XCTAssertEqual(fixedRows.map(\.0).filter { $0.contains("model") || $0.contains("Model") }, ["Model requested", "Model of substitution"])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: fixedRows)["Model of substitution"], "HKY+F+G4")
        XCTAssertEqual(PhylogeneticTreeInferenceRows.requestedModelText("HKY+F+G4"), "HKY+F+G4")
        XCTAssertEqual(PhylogeneticTreeInferenceRows.sequenceTypeText("CODON2"), "Codon (Vertebrate mitochondrial)")
        XCTAssertEqual(PhylogeneticTreeInferenceRows.inputText(inference), "Alignment, 6 of 6 sequences, all columns")
        XCTAssertEqual(PhylogeneticTreeInferenceRows.branchSupportText([], inference: inference), "None")
        XCTAssertEqual(
            PhylogeneticTreeInferenceRows.branchSupportText(["SH-aLRT", "UFBoot"], inference: inference),
            "SH-aLRT, UFBoot. Node labels read SH-aLRT/UFBoot.")
        XCTAssertEqual(PhylogeneticTreeInferenceRows.accessibilityText(label: "Seed", value: "7"), "Seed, 7")
    }

    // MARK: - Fixtures

    private func sarcopterygianInference() -> PhylogeneticTreeInferenceSummary {
        PhylogeneticTreeInferenceSummary(
            program: "IQ-TREE",
            programVersion: "3.1.3",
            requestedModel: "MFP",
            bestFitModel: "TIM2+ASC",
            modelSelectionCriterion: "BIC",
            substitutionModel: "TIM2+F+ASC",
            logLikelihood: -173.4941,
            logLikelihoodStandardError: 7.9018,
            freeParameters: 15,
            ufBootReplicates: 1000,
            shALRTReplicates: 1000,
            sequenceType: "DNA",
            seed: 12345,
            threads: 1,
            outgroup: ["Danio rerio"],
            outgroupWarning: "Outgroup is not monophyletic. The tree is left unrooted.",
            sourceAlignmentName: "sarcopterygians",
            selectedRowCount: 5,
            totalRowCount: 6,
            selectedColumns: "1-48",
            alignedLength: 48
        )
    }

    private func makeBundle(
        inference: PhylogeneticTreeInferenceSummary?,
        newick: String = "(A:0.1,B:0.2,(C:0.3,(D:0.1,E:0.2)99.9/100:0.05)85/90:0.4);\n"
    ) throws -> PhylogeneticTreeBundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-inference-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("run.treefile")
        try newick.write(to: sourceURL, atomically: true, encoding: .utf8)
        return try PhylogeneticTreeBundleImporter.importTree(
            from: sourceURL,
            to: directory.appendingPathComponent("tree.lungfishtree", isDirectory: true),
            options: PhylogeneticTreeImportOptions(
                sourceFormat: "newick",
                supportLabels: inference == nil ? nil : ["SH-aLRT", "UFBoot"],
                branchLengthUnit: inference == nil ? nil : "substitutions per site",
                inference: inference
            )
        )
    }
}
