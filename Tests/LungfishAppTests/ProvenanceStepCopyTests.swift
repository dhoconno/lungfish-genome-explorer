// ProvenanceStepCopyTests.swift - A Lineage step copies its own block of the Provenance Copy text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp

/// Copy Step on the Provenance tab writes the step's block of the header's Copy text, and Copy All Steps writes the
/// blocks of the step's run, from the step's label and from its Command row.
@MainActor
final class ProvenanceStepCopyTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var pasteboard: NSPasteboard?

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        pasteboard?.releaseGlobally()
        pasteboard = nil
        try await super.tearDown()
    }

    func testStepCopyTextEqualsItsBlockInTheCopyText() async throws {
        let model = try await loadedModel(exitStatuses: [0, nil])
        let run = try XCTUnwrap(model.lineageRuns.last)
        XCTAssertEqual(run.steps.count, 2)
        let texts = run.steps.map { model.stepCopyText(of: $0) }

        let blocks = texts.joined(separator: "\n")
        let copy = model.copyableText
        XCTAssertTrue(
            copy.contains("\n\(blocks)\n\n") || copy.hasSuffix("\n\(blocks)"),
            "each step's text is its whole block of the Copy text:\n\(copy)"
        )
        XCTAssertTrue(texts[0].hasPrefix("1. fastp"), texts[0])
        XCTAssertTrue(texts[0].contains("\nExit Status: 0"), texts[0])
        XCTAssertFalse(texts[1].contains("Exit Status"), "a step without an exit status has no Exit Status line:\n\(texts[1])")
        XCTAssertFalse(texts.contains { $0.hasSuffix("\n") })
        XCTAssertEqual(model.allStepsCopyText(of: run), texts.joined(separator: "\n\n"))
    }

    /// The single Copy Command item of the Command row became the three step commands, which the step's label also
    /// offers next to Expand.
    func testLineageStepOffersItsCopyCommandsFromItsLabelAndCommandRow() throws {
        let recorded = "minimap2 -a '/tmp/HG002 chr20.lungfish/Imports/reads.fq'"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ProvenanceStepCopyTests-\(UUID().uuidString)"))
        self.pasteboard = pasteboard
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.pasteboard = pasteboard
        let run = ProvenanceLineageRun(
            id: UUID(), title: "lungfish map", subtitle: "lungfish map (development build)",
            steps: [
                ProvenanceLineageStep(
                    id: UUID(), ordinal: 1, toolName: "minimap2", toolVersion: "v2.31",
                    command: recorded, commandLabel: "minimap2 -a Imports/reads.fq",
                    inputPaths: [], outputPaths: [],
                    exitStatus: 0, wallTimeSeconds: nil, stderr: nil, dependsOn: []
                ),
                ProvenanceLineageStep(
                    id: UUID(), ordinal: 2, toolName: "samtools", toolVersion: "v1.22",
                    command: "samtools sort", inputPaths: [], outputPaths: [],
                    exitStatus: nil, wallTimeSeconds: nil, stderr: nil, dependsOn: []
                ),
            ]
        )
        viewModel.lineageRuns = [run]
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: viewModel))
        windows.append(window)

        XCTAssertTrue(AccessibilityTreeProbe.press(try element("provenance-run-1", in: window)))
        let stepLabel = try element("provenance-run-1-step-1", in: window)
        let labelActions = AccessibilityTreeProbe.customActionNames(stepLabel)
        XCTAssertEqual(labelActions.filter { $0.hasPrefix("Copy") }, ["Copy Step", "Copy Command", "Copy All Steps"])
        XCTAssertTrue(labelActions.contains("Expand"), "\(labelActions)")
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy All Steps", on: stepLabel))
        XCTAssertEqual(pasteboard.string(forType: .string), viewModel.allStepsCopyText(of: run))

        XCTAssertTrue(AccessibilityTreeProbe.press(stepLabel))
        let command = try element("provenance-step-command", in: window)
        // The selectable value also carries a "show menu" action that SwiftUI adds on its own.
        XCTAssertEqual(
            AccessibilityTreeProbe.customActionNames(command).filter { $0.hasPrefix("Copy") },
            ["Copy Step", "Copy Command", "Copy All Steps"]
        )
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Command", on: command))
        XCTAssertEqual(pasteboard.string(forType: .string), recorded, "Copy Command keeps the recorded command whole")
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Step", on: command))
        XCTAssertEqual(pasteboard.string(forType: .string), "1. minimap2 v2.31\nCommand: \(recorded)\nExit Status: 0")
    }

    /// Q-U2 rules 1 and 7. A tool's stderr ends with a newline, and neither Copy Step nor Copy All Steps may.
    func testCopyStepAndCopyAllStepsEndWithoutANewlineWhenStderrDoes() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ProvenanceStepCopyTests-\(UUID().uuidString)"))
        self.pasteboard = pasteboard
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.pasteboard = pasteboard
        func step(_ ordinal: Int) -> ProvenanceLineageStep {
            ProvenanceLineageStep(
                id: UUID(), ordinal: ordinal, toolName: "kraken2", toolVersion: "v2.1.3",
                command: "kraken2 --db db reads.fq", inputPaths: [], outputPaths: [],
                exitStatus: 0, wallTimeSeconds: nil, stderr: "55 sequences processed\n", dependsOn: []
            )
        }
        let run = ProvenanceLineageRun(id: UUID(), title: "classify", subtitle: "lungfish classify", steps: [step(1), step(2)])
        viewModel.lineageRuns = [run]
        XCTAssertTrue(viewModel.stepCopyText(of: run.steps[0]).hasSuffix("processed\n"), "the header's block keeps its newline")
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: viewModel))
        windows.append(window)

        XCTAssertTrue(AccessibilityTreeProbe.press(try element("provenance-run-1", in: window)))
        let label = try element("provenance-run-1-step-1", in: window)
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Step", on: label))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "1. kraken2 v2.1.3\nCommand: kraken2 --db db reads.fq\nExit Status: 0\nstderr: 55 sequences processed"
        )
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy All Steps", on: label))
        let all = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertFalse(all.hasSuffix("\n"))
        XCTAssertFalse(all.contains("\n\n\n"), "one blank line between steps")
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> NSObject {
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, identifier: identifier) != nil }
        return try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: identifier),
            "no \(identifier); tree:\n" + AccessibilityTreeProbe.dump(window)
        )
    }

    /// The cancelled trim record with one step per exit status, nil leaving a step's exit status out, placed in a
    /// project and loaded the way the Inspector loads it.
    private func loadedModel(exitStatuses: [Int?]) async throws -> ProvenanceInspectorViewModel {
        let template = try Data(contentsOf: ProvenanceDisplayFixtures.directory
            .appendingPathComponent("Analyses/fastq-trim-cancelled/.lungfish-provenance.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: template) as? [String: Any])
        let templateStep = try XCTUnwrap((object["steps"] as? [[String: Any]])?.first)
        object["steps"] = exitStatuses.enumerated().map { index, exitStatus -> [String: Any] in
            var step = templateStep
            step["id"] = UUID().uuidString
            step["toolName"] = index == 0 ? "fastp" : "seqkit"
            if let exitStatus {
                step["exitStatus"] = exitStatus
            } else {
                step.removeValue(forKey: "exitStatus")
            }
            return step
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])

        let root = try TestTempDirectory.make(prefix: "provenance-step-copy")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let sidecar = root.appendingPathComponent("Runs.lungfish/Analyses/classify-run/.lungfish-provenance.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sidecar, options: .atomic)

        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: sidecar.deletingLastPathComponent(),
            sidebarType: .analysisResult,
            contentMode: .genomics,
            displayName: "classify-run"
        ))
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertNotNil(model.resolvedEnvelope, "The record was not found.")
        return model
    }
}
