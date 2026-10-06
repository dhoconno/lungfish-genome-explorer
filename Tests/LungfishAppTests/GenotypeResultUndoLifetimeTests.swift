// GenotypeResultUndoLifetimeTests.swift - Undo never reaches a genotype viewport the viewer dropped
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
@testable import LungfishIO

/// Review finding B1. The window's undo manager does not retain its targets,
/// and the viewer builds a new `GenotypeResultViewController` for every result
/// and drops the old one. Hiding the genotype viewport must therefore remove
/// every Undo that targets the controller, such as the sample status and
/// colour Undo it registers.
@MainActor
final class GenotypeResultUndoLifetimeTests: XCTestCase {
    func testHidingTheGenotypeViewportRemovesItsUndoActions() throws {
        let host = makeHostedSplit()
        defer { host.window.close() }
        let controller = host.split.viewerController.displayGenotypeResult(Self.makeResult())
        let undoManager = try XCTUnwrap(controller.view.window?.undoManager)
        registerReviewUndo(on: undoManager, target: controller)
        XCTAssertTrue(undoManager.canUndo)

        host.split.viewerController.hideGenotypeResultView()

        XCTAssertNil(host.split.viewerController.genotypeResultViewController)
        XCTAssertFalse(undoManager.canUndo, "no Undo may target a controller the viewer dropped")
    }

    func testShowingAnotherGenotypeResultRemovesTheFirstControllersUndoActions() throws {
        let host = makeHostedSplit()
        defer { host.window.close() }
        let first = host.split.viewerController.displayGenotypeResult(Self.makeResult())
        let undoManager = try XCTUnwrap(first.view.window?.undoManager)
        registerReviewUndo(on: undoManager, target: first)

        let second = host.split.viewerController.displayGenotypeResult(Self.makeResult())

        XCTAssertFalse(first === second, "the viewer builds a new controller for every result")
        XCTAssertFalse(undoManager.canUndo, "the first controller's Undo went with it")
    }

    func testUndoForTheControllerOnScreenSurvives() throws {
        let host = makeHostedSplit()
        defer { host.window.close() }
        let controller = host.split.viewerController.displayGenotypeResult(Self.makeResult())
        let undoManager = try XCTUnwrap(controller.view.window?.undoManager)
        var undone = false
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: controller) { _ in undone = true }
        undoManager.endUndoGrouping()

        undoManager.undo()

        XCTAssertTrue(undone, "only a dropped controller loses its Undo")
    }

    // MARK: - Helpers

    private func makeHostedSplit() -> (window: NSWindow, split: MainSplitViewController) {
        let split = MainSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        return (window, split)
    }

    /// Registers an Undo the way a review command does, in a group of its own.
    private func registerReviewUndo(on undoManager: UndoManager, target: GenotypeResultViewController) {
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: target) { _ in
            XCTFail("Undo reached a genotype controller the viewer had dropped")
        }
        undoManager.setActionName("Mark Sample Confirmed")
        undoManager.endUndoGrouping()
    }

    private static func makeResult() -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/undo-lifetime.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "undo-lifetime",
                analysisName: "undo-lifetime",
                primaryWorkbookPath: "undo-lifetime.xlsx",
                longSummaryCSVPath: "undo-lifetime.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "undo-lifetime.retained-demux-samples.csv",
                statsJSONPath: "undo-lifetime.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json",
                haplotypeAnalysisPath: "undo-lifetime-haplotype-analysis.json",
                haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/undo-lifetime.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/undo-lifetime.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/undo-lifetime.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/undo-lifetime.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1, retainedUniqueReads: 1),
            calls: [],
            samples: [],
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "MHC-exon2-miSeq",
                definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
                definitionSetName: "Mauritian cynomolgus macaques",
                speciesName: "Mauritian cynomolgus macaques",
                samples: []
            )
        )
    }
}
