// ProvenanceRawJSONDisplayTests.swift - The Raw JSON pane says when it cuts, caps or substitutes the text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

/// The Provenance tab never shows an empty or unlabelled view of an existing record (UX
/// non-negotiable 2). The pane cuts a long record at 80 lines, says so, and says Copy takes the
/// whole record. These cases drive the real `ProvenanceSection` through ViewInspector, so they
/// need no window and run with the screen locked.
@MainActor
final class ProvenanceRawJSONDisplayTests: XCTestCase {
    // MARK: - The 80-line cut

    /// A record of `count` lines in the shape `ProvenanceJSON.encoder` writes, with no final newline.
    private func record(lines count: Int) -> String {
        (0..<count).map { index in
            switch index {
            case 0: return "{"
            case count - 1: return "}"
            default: return "  \"key-\(index)\" : \(index),"
            }
        }.joined(separator: "\n")
    }

    private func pane(of viewModel: ProvenanceInspectorViewModel) throws -> SelectableWrappingText {
        try ProvenanceSection(viewModel: viewModel).inspect()
            .find(ViewType.View<SelectableWrappingText>.self)
            .actualView()
    }

    /// The captions the pane lists above its text, in order. Each caption is a Text with the
    /// `provenance-raw-json-caption` identifier.
    private func captions(of viewModel: ProvenanceInspectorViewModel) -> [String] {
        guard let inspected = try? ProvenanceSection(viewModel: viewModel).inspect() else { return [] }
        return inspected
            .findAll(ViewType.Text.self, where: {
                (try? $0.accessibilityIdentifier()) == "provenance-raw-json-caption"
            })
            .compactMap { try? $0.string() }
    }

    func testARecordPastEightyLinesSaysHowManyLinesTheCutShowsAndThatCopyTakesAll() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.rawJSON = record(lines: 412)

        XCTAssertEqual(
            captions(of: viewModel),
            ["Showing the first 80 of 412 lines. Copy takes the whole record."]
        )
        let shown = try pane(of: viewModel).text
        XCTAssertEqual(shown.split(separator: "\n", omittingEmptySubsequences: false).count, 80)
        XCTAssertTrue(viewModel.rawJSON.hasPrefix(shown), "The pane shows the start of the record.")
        XCTAssertNil(
            try pane(of: viewModel).maximumNumberOfLines,
            "The cut is made on lines of the record, so the text view cuts nothing of its own."
        )
    }

    func testARecordOfEightyLinesOrFewerIsShownWholeWithoutACaption() throws {
        for count in [1, 79, 80] {
            let viewModel = ProvenanceInspectorViewModel()
            viewModel.rawJSON = record(lines: count)

            XCTAssertEqual(captions(of: viewModel), [], "\(count) lines are all shown.")
            XCTAssertEqual(try pane(of: viewModel).text, viewModel.rawJSON, "\(count) lines")
        }
    }

    func testAFinalNewlineIsNotACountedLine() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.rawJSON = record(lines: 80) + "\n"
        XCTAssertEqual(captions(of: viewModel), [], "80 lines and a final newline are 80 lines.")

        viewModel.rawJSON = record(lines: 81) + "\n"
        XCTAssertEqual(
            captions(of: viewModel),
            ["Showing the first 80 of 81 lines. Copy takes the whole record."]
        )
    }

    func testAnUnbrokenRecordPastTheCharacterLimitSaysHowMuchTheCutShows() throws {
        let viewModel = ProvenanceInspectorViewModel()
        let whole = "{\"stderr\":\"" + String(repeating: "x", count: 59_000) + "\"}"
        viewModel.rawJSON = whole

        XCTAssertEqual(
            captions(of: viewModel),
            ["Showing the first 20000 of \(whole.count) characters. Copy takes the whole record."]
        )
        XCTAssertEqual(try pane(of: viewModel).text.count, 20_000)
        XCTAssertTrue(whole.hasPrefix(try pane(of: viewModel).text))
    }

    func testCopyTakesTheWholeRecordNotTheLinesShown() throws {
        let viewModel = ProvenanceInspectorViewModel()
        let whole = record(lines: 412)
        viewModel.rawJSON = whole
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        viewModel.pasteboard = pasteboard

        try ProvenanceSection(viewModel: viewModel).inspect()
            .find(viewWithAccessibilityIdentifier: "provenance-copy-json")
            .button()
            .tap()

        XCTAssertEqual(pasteboard.string(forType: .string), whole)
        XCTAssertEqual(pasteboard.string(forType: .string)?.split(separator: "\n").count, 412)
    }

    // MARK: - Records past the display caps

    /// The sentences the pane shows in place of text it does not hold.
    private enum Message {
        static let tooLarge = "This record is too large to show here."
        static let noRecord = "No raw provenance JSON is available."
        static let notShown = "This record could not be shown as text."
    }

    /// Loads a record of `inputs` descriptors, with `stepInputs` of them on one step, through the
    /// view model's own lookup, the way a selection does.
    private func loadedModel(fileDescriptors count: Int, stepInputs: Int = 0) async throws -> ProvenanceInspectorViewModel {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-raw-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        func descriptor(_ index: Int, role: FileRole) -> ProvenanceFileDescriptor {
            ProvenanceFileDescriptor(
                path: folder.appendingPathComponent("file-\(index).fastq").path,
                checksumSHA256: String(repeating: "a", count: 64),
                fileSize: UInt64(index + 1),
                format: .fastq,
                role: role
            )
        }
        let files = (0..<count).map { descriptor($0, role: .input) }
        let step = ProvenanceStep(
            toolName: "bulk-import",
            toolVersion: "1.0",
            argv: ["bulk-import"],
            inputs: (0..<stepInputs).map { descriptor($0, role: .input) },
            outputs: [],
            exitStatus: 0,
            wallTimeSeconds: 2
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "Large FASTQ Import",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "0.5.0",
            argv: ["lungfish-cli", "fastq", "import-ont"],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: files,
            output: files.first,
            outputs: files.isEmpty ? [] : [files[0]],
            steps: [step],
            wallTimeSeconds: 2,
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: folder)

        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: folder, sidebarType: .analysisResult, contentMode: .genomics, displayName: "Large"
        ))
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        return model
    }

    private func texts(in viewModel: ProvenanceInspectorViewModel) throws -> [String] {
        try ProvenanceSection(viewModel: viewModel).inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
    }

    func testARecordPastTheFileRowCapSaysItIsTooLargeAndOffersRevealInFinder() async throws {
        let model = try await loadedModel(fileDescriptors: 650)

        XCTAssertNotNil(model.resolvedEnvelope)
        XCTAssertEqual(model.rawJSON, "", "The pane holds no text for a record past its caps.")
        let texts = try texts(in: model)
        XCTAssertTrue(texts.contains(Message.tooLarge), "\(texts)")
        XCTAssertFalse(texts.contains(Message.noRecord), "The record exists, so no JSON being available is false.")
        let reveal = try ProvenanceSection(viewModel: model).inspect()
            .find(viewWithAccessibilityIdentifier: "provenance-raw-json-reveal")
        XCTAssertNoThrow(try reveal.button())
        XCTAssertThrowsError(
            try ProvenanceSection(viewModel: model).inspect().find(viewWithAccessibilityIdentifier: "provenance-copy-json"),
            "There is no text to copy."
        )
    }

    func testARecordWithMoreThanTwoHundredPathsInAStepIsTooLarge() async throws {
        let model = try await loadedModel(fileDescriptors: 10, stepInputs: 250)

        XCTAssertEqual(model.rawJSON, "")
        XCTAssertTrue(try texts(in: model).contains(Message.tooLarge))
    }

    func testRevealInFinderRevealsTheSidecar() async throws {
        let model = try await loadedModel(fileDescriptors: 650)
        var revealed: [URL] = []
        model.revealer = { revealed.append($0) }

        try ProvenanceSection(viewModel: model).inspect()
            .find(viewWithAccessibilityIdentifier: "provenance-raw-json-reveal")
            .button()
            .tap()

        XCTAssertEqual(revealed, [try XCTUnwrap(model.resolvedSidecarURL)])
        XCTAssertEqual(revealed.first?.lastPathComponent, ".lungfish-provenance.json")
    }

    func testARecordThatFitsIsNotCalledTooLarge() async throws {
        let model = try await loadedModel(fileDescriptors: 20)

        XCTAssertFalse(model.rawJSON.isEmpty)
        XCTAssertFalse(try texts(in: model).contains(Message.tooLarge))
    }

    func testNoRecordStillSaysNoJSONIsAvailable() throws {
        let viewModel = ProvenanceInspectorViewModel()

        XCTAssertTrue(try texts(in: viewModel).contains(Message.noRecord))
        XCTAssertFalse(try texts(in: viewModel).contains(Message.tooLarge))
    }

    /// A record that exists never meets the no JSON message, whatever kept its text from the pane.
    func testARecordWithoutTextIsNeverSaidToHaveNoJSON() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.resolvedEnvelope = ProvenanceEnvelope.fixture()
        viewModel.rawJSON = ""

        let texts = try texts(in: viewModel)
        XCTAssertTrue(texts.contains(Message.notShown), "\(texts)")
        XCTAssertFalse(texts.contains(Message.noRecord))
    }
}
