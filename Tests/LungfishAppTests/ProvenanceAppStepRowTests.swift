// ProvenanceAppStepRowTests.swift - A step that ran inside the app shows its words with a note and offers no Copy Command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.64 (V1-7, R3 of BIO-Q-A2, UX 1 to 5). The Provenance tab shows the words of a step that ran
// inside the app, such as the merge of FASTQ bundles, in the Command row with a note, and turns off its Copy Command,
// since no Terminal can run those words. Copy Step and Copy All Steps still copy the step, without the note. The
// Operations panel offers Copy CLI Command only for a `lungfish-cli` command.

import AppKit
import LungfishCore
import LungfishKit
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp

@MainActor
final class ProvenanceAppStepRowTests: XCTestCase {
    private static let note = "This step ran inside the app and has no command to run in Terminal."
    private static let noteIdentifier = "provenance-step-command-app-step-note"
    private static let appArgv = [
        "lungfish-app", "fastq", "merge", "--requested-bundle-name", "Merged", "--output-bundle", "/tmp/Merged.lungfishfastq",
    ]
    private static let cliArgv = ["lungfish-cli", "fastq", "trim", "reads.fastq", "--output", "trimmed.fastq"]

    private var windows: [NSWindow] = []
    private var pasteboard: NSPasteboard?

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        pasteboard?.releaseGlobally()
        pasteboard = nil
        try await super.tearDown()
    }

    /// R3. The Lineage rows of a record with one step that ran inside the app and one `lungfish-cli` step.
    func testTheLineageRowsOfARecordMarkTheAppStepAndKeepTheCLIStepRunnable() async throws {
        let model = try await loadedModel()
        let run = try XCTUnwrap(model.lineageRuns.last)
        XCTAssertEqual(run.steps.count, 2)
        let app = run.steps[0]
        let cli = run.steps[1]
        XCTAssertTrue(app.displayCommand.contains("fastq merge"), "the app step keeps its words: \(app.displayCommand)")
        XCTAssertTrue(cli.displayCommand.contains("fastq trim"), cli.displayCommand)

        let appActions = model.stepCopyActions(app, in: run)
        XCTAssertFalse(try isEnabled("Copy Command", in: appActions), "an app step has no command to copy")
        XCTAssertTrue(try isEnabled("Copy Step", in: appActions), "Copy Step still copies the words")
        XCTAssertTrue(try isEnabled("Copy All Steps", in: appActions))
        let cliActions = model.stepCopyActions(cli, in: run)
        XCTAssertTrue(try isEnabled("Copy Command", in: cliActions), "a lungfish-cli step keeps its Copy Command")
        XCTAssertEqual(run.steps.map(\.ranInsideTheApp), [true, false], "only the first step carries the mark")
        XCTAssertEqual(app.appStepNote, Self.note, "the mark is the note")
        XCTAssertNil(cli.appStepNote)
    }

    /// UX 1 to 4. The note, its words, the actions of the step's label and the text Copy Step writes.
    func testAnAppStepShowsItsNoteAndTurnsOffCopyCommand() async throws {
        let model = try await loadedModel()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ProvenanceAppStepRowTests-\(UUID().uuidString)"))
        self.pasteboard = pasteboard
        model.pasteboard = pasteboard
        let run = try XCTUnwrap(model.lineageRuns.last)
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: model))
        windows.append(window)
        XCTAssertTrue(AccessibilityTreeProbe.press(try element("provenance-run-1", in: window)))

        // The lungfish-cli step opens first, so a note found afterwards belongs to the app step.
        let cliLabel = try element("provenance-run-1-step-2", in: window)
        XCTAssertTrue(AccessibilityTreeProbe.press(cliLabel))
        _ = try element("provenance-step-command", in: window)
        XCTAssertNil(
            AccessibilityTreeProbe.element(in: window, identifier: Self.noteIdentifier),
            "a lungfish-cli step has no note"
        )
        XCTAssertEqual(copyActions(of: cliLabel), ["Copy Step", "Copy Command", "Copy All Steps"])

        let appLabel = try element("provenance-run-1-step-1", in: window)
        XCTAssertTrue(AccessibilityTreeProbe.press(appLabel))
        let note = try element(Self.noteIdentifier, in: window)
        XCTAssertEqual(AccessibilityTreeProbe.label(note) ?? AccessibilityTreeProbe.value(note), Self.note)
        XCTAssertEqual(AccessibilityTreeProbe.help(note), Self.note, "the same words as its tooltip")
        XCTAssertEqual(copyActions(of: appLabel), ["Copy Step", "Copy All Steps"], "Copy Command is turned off")

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Step", on: appLabel))
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("Command: lungfish-app fastq merge"), "Copy Step copies the words:\n\(copied)")
        XCTAssertFalse(copied.contains(Self.note), "the note is never in the copied text:\n\(copied)")
        XCTAssertEqual(copied, model.stepClipboardText(of: run.steps[0]))
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy All Steps", on: appLabel))
        XCTAssertFalse(try XCTUnwrap(pasteboard.string(forType: .string)).contains(Self.note))
    }

    private func copyActions(of element: NSObject) -> [String] {
        AccessibilityTreeProbe.customActionNames(element).filter { $0.hasPrefix("Copy") }
    }

    private func isEnabled(_ title: String, in actions: [ContextAction]) throws -> Bool {
        let action = try XCTUnwrap(actions.first { $0.title == title }, title)
        guard case .command(_, let isEnabled, _) = action.kind else { return false }
        return isEnabled
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> NSObject {
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, identifier: identifier) != nil }
        return try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: identifier),
            "no \(identifier); tree:\n" + AccessibilityTreeProbe.dump(window)
        )
    }

    /// A record of two steps, the first one that ran inside the app and the second one that names `lungfish-cli`,
    /// placed in a project and loaded the way the Inspector loads it.
    private func loadedModel() async throws -> ProvenanceInspectorViewModel {
        let template = try Data(contentsOf: ProvenanceDisplayFixtures.directory
            .appendingPathComponent("Analyses/fastq-trim-cancelled/.lungfish-provenance.json"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: template) as? [String: Any])
        let templateStep = try XCTUnwrap((object["steps"] as? [[String: Any]])?.first)
        object["steps"] = [("lungfish-app", Self.appArgv), ("lungfish-cli", Self.cliArgv)]
            .map { toolName, argv -> [String: Any] in
                var step = templateStep
                step["id"] = UUID().uuidString
                step["toolName"] = toolName
                step["argv"] = argv
                step["reproducibleCommand"] = argv.joined(separator: " ")
                return step
            }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])

        let root = try TestTempDirectory.make(prefix: "provenance-app-step")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let sidecar = root.appendingPathComponent("Runs.lungfish/Analyses/merge-run/.lungfish-provenance.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sidecar, options: .atomic)

        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: sidecar.deletingLastPathComponent(),
            sidebarType: .analysisResult,
            contentMode: .genomics,
            displayName: "merge-run"
        ))
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading && !model.lineageRuns.isEmpty }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertNotNil(model.resolvedEnvelope, "The record was not found.")
        return model
    }
}

/// UX 5. The Operations panel offers Copy CLI Command only for a row whose command starts with `lungfish-cli `.
@MainActor
final class OperationRowActionCLICommandGateTests: XCTestCase {
    private func item(_ command: String?) -> OperationCenter.Item {
        OperationCenter.Item(
            title: "Merge FASTQ bundles",
            detail: "Done",
            progress: 1,
            state: .completed,
            operationType: .assembly,
            cliCommand: command
        )
    }

    func testCopyCLICommandIsOfferedOnlyForALungfishCLICommand() {
        let copy = OperationRowAction.copyCLICommand
        XCTAssertTrue(copy.isAvailable(for: item("lungfish-cli fastq merge a.lungfishfastq b.lungfishfastq")))
        XCTAssertFalse(
            copy.isAvailable(for: item("lungfish-app fastq merge --output-bundle /p/Merged.lungfishfastq")),
            "words that no Terminal can run are no CLI command"
        )
        XCTAssertFalse(copy.isAvailable(for: item("lungfish map reads.fastq")), "the old spelling of the executable")
        XCTAssertFalse(copy.isAvailable(for: item("lungfish-cli")), "the executable alone is no command")
        XCTAssertFalse(copy.isAvailable(for: item(nil)))
    }
}
