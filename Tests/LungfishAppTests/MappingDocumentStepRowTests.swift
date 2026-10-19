// MappingDocumentStepRowTests.swift - The step rows of a mapping result's Run Settings on the Document tab
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Hosts the real mapping Document section with a record whose project
/// folder name has a space and whose mapper command is longer than 600
/// characters, and reads it the way VoiceOver and AX automation do.
@MainActor
final class MappingDocumentStepRowTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    /// The fixture's read path, which lies in the spaced project folder.
    private var readsPath = ""

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingDocumentStepRowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MappingDocumentStepRowTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        pasteboard.releaseGlobally()
        pasteboard = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - Display

    /// The defect of 2026-10-17. Selecting a step's truncated command drew the
    /// whole command over the rows below. An expanded step now lays out its
    /// whole command in a row that grows, and the next step moves down.
    func testExpandedStepGrowsAndClearsTheNextRow() throws {
        let window = hostSection(try fixtureState(), width: 320)
        AccessibilityTreeProbe.waitUntil { self.frame(of: "mapping-step-2-toggle", in: window) != nil }
        let toggle = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "mapping-step-1-toggle"),
            "no step disclosure control; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        let collapsed = try XCTUnwrap(frame(of: "mapping-step-1-command", in: window), "no step command")

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Expand", on: toggle))
        AccessibilityTreeProbe.waitUntil {
            (self.frame(of: "mapping-step-1-command", in: window)?.height ?? 0) > collapsed.height
        }

        let expanded = try XCTUnwrap(frame(of: "mapping-step-1-command", in: window))
        let nextRow = try XCTUnwrap(frame(of: "mapping-step-2-toggle", in: window))
        XCTAssertGreaterThan(expanded.height, collapsed.height, "the expanded command shows every line")
        XCTAssertGreaterThanOrEqual(
            expanded.minY, nextRow.maxY,
            "the expanded command must end above the next step, expanded \(expanded), next \(nextRow)"
        )
    }

    /// Q-U3 "Other rows". A long Run Settings value shows whole, and the next row sits below it.
    func testLongRunSettingsValueShowsWholeAndClearsTheNextRow() throws {
        let long = Array(repeating: "--max-intron-len 5000", count: 20).joined(separator: " ")
        let state = MappingDocumentState(
            title: "Mapping", subtitle: nil, summary: nil, sourceData: [],
            contextRows: [("Extra arguments", long), ("Mapper Version", "2.31")], artifactRows: []
        )
        let window = hostSection(state, width: 320)
        func frame(ofValue value: String) -> NSRect? {
            AccessibilityTreeProbe.all(in: window).first { AccessibilityTreeProbe.value($0) == value }
                .map { AccessibilityTreeProbe.frame($0) }
        }
        AccessibilityTreeProbe.waitUntil { frame(ofValue: "2.31") != nil }
        let longRow = try XCTUnwrap(frame(ofValue: long), "tree:\n" + AccessibilityTreeProbe.dump(window))
        let nextRow = try XCTUnwrap(frame(ofValue: "2.31"))
        XCTAssertGreaterThan(longRow.height, 3 * nextRow.height, "more than three lines show")
        XCTAssertGreaterThanOrEqual(longRow.minY, nextRow.maxY, "the next row sits below the whole value")
    }

    func testStepDisclosureReportsAndChangesItsState() throws {
        let state = try fixtureState()
        let window = hostSection(state)
        AccessibilityTreeProbe.waitUntil { self.value(of: "mapping-step-1-toggle", in: window) != nil }
        let toggle = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "mapping-step-1-toggle"),
            "no step disclosure control; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertEqual(AccessibilityTreeProbe.label(toggle), "minimap2 command")
        XCTAssertEqual(AccessibilityTreeProbe.value(toggle), "Collapsed")
        XCTAssertEqual(AccessibilityTreeProbe.customActionNames(toggle), ["Expand"])
        XCTAssertEqual(
            value(of: "mapping-step-1-command", in: window), state.steps[0].command,
            "the collapsed command's value is the whole command"
        )

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Expand", on: toggle))
        AccessibilityTreeProbe.waitUntil { self.value(of: "mapping-step-1-toggle", in: window) == "Expanded" }

        XCTAssertEqual(value(of: "mapping-step-1-toggle", in: window), "Expanded")
        let expandedToggle = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: "mapping-step-1-toggle"))
        XCTAssertEqual(AccessibilityTreeProbe.customActionNames(expandedToggle), ["Collapse"])
        XCTAssertEqual(
            value(of: "mapping-step-1-command", in: window), state.steps[0].command,
            "the expanded command's value is the whole command"
        )
        XCTAssertEqual(value(of: "mapping-step-2-toggle", in: window), "Collapsed", "the other steps stay collapsed")
    }

    // MARK: - Copy

    func testCopyStepWritesTheTitleRecordedAndTheWholeCommand() throws {
        let state = try fixtureState()
        let window = hostSection(state)

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Step", on: try stepRow(1, in: window)))

        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(copied, try expectedStepText(state.steps[0], in: state))
        XCTAssertTrue(copied.hasPrefix("minimap2 2.31\nRecorded: "), copied)
        XCTAssertFalse(copied.contains("\u{2026}"), "the copy is never truncated")
        XCTAssertFalse(copied.hasSuffix("\n"))
    }

    func testCopyCommandWritesOnlyTheCommand() throws {
        let state = try fixtureState()
        let window = hostSection(state)

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Command", on: try stepRow(1, in: window)))

        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(copied, state.steps[0].command)
        XCTAssertTrue(readsPath.contains(" "), "the project folder name has a space")
        XCTAssertTrue(copied.hasSuffix(" '\(readsPath)'"), "the spaced path is one single-quoted word")
        XCTAssertFalse(copied.contains("\n"))
    }

    /// PF6 Q-U7 under UX's ruling. The row shows the command project-relative, and Copy Command still copies the
    /// recorded command with every path in full, so a pasted command runs outside the project.
    func testCopyCommandStaysWholeWhenTheRowIsProjectRelative() throws {
        let project = tempRoot.appendingPathComponent("Runs.lungfish", isDirectory: true)
        let step = MappingDocumentStep(
            label: "minimap2", command: "minimap2 -a " + project.path + "/Analyses/m/reads.fastq", version: "2.31", recorded: "Oct 18"
        )
        let board = pasteboard!
        let row = MappingDocumentStepRow(
            step: step,
            shownCommand: "minimap2 -a Analyses/m/reads.fastq",
            number: 1,
            isExpanded: .constant(false),
            copyText: InspectorStepCopyText.mappingStep(step),
            copy: { text in
                board.clearContents()
                board.setString(text, forType: .string)
            },
            allStepsText: { InspectorStepCopyText.mappingSteps([step]) }
        )
        let window = AccessibilityTreeProbe.host(row)
        windows.append(window)

        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Command", on: try stepRow(1, in: window)))

        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(copied, step.command)
        XCTAssertTrue(copied.contains(project.path + "/Analyses/m/reads.fastq"), copied)
    }

    func testCopyAllStepsJoinsEveryStepWithOneBlankLine() throws {
        let state = try fixtureState()
        let window = hostSection(state)
        var stepTexts: [String] = []
        for number in 1...state.steps.count {
            XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Step", on: try stepRow(number, in: window)))
            stepTexts.append(try XCTUnwrap(pasteboard.string(forType: .string)))
        }
        XCTAssertEqual(Set(stepTexts).count, 5, "each of the five steps copies its own text")

        let button = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "mapping-steps-copy-all"),
            "no Copy All Steps button; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertEqual(AccessibilityTreeProbe.label(button), "Copy all steps")
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityTreeProbe.press(button))
        XCTAssertEqual(pasteboard.string(forType: .string), stepTexts.joined(separator: "\n\n"))

        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy All Steps", on: try stepRow(3, in: window)))
        XCTAssertEqual(
            pasteboard.string(forType: .string), stepTexts.joined(separator: "\n\n"),
            "the menu command copies the same text from any step"
        )
    }

    func testStepRowOffersItsCopyCommandsInMenuOrder() throws {
        let window = hostSection(try fixtureState())
        XCTAssertEqual(
            AccessibilityTreeProbe.customActionNames(try stepRow(1, in: window)),
            ["Copy Step", "Copy Command", "Copy All Steps"]
        )

        let withoutCommand = MappingDocumentState(
            title: "Mapping", subtitle: nil, summary: nil, sourceData: [], contextRows: [],
            steps: [MappingDocumentStep(label: "minimap2", command: "", version: "2.31", recorded: "Oct 16, 2026")],
            artifactRows: []
        )
        let otherWindow = hostSection(withoutCommand)
        XCTAssertEqual(
            AccessibilityTreeProbe.customActionNames(try stepRow(1, in: otherWindow)),
            ["Copy Step", "Copy All Steps"],
            "a step without a command offers no Copy Command"
        )
    }

    func testCopyIconCopiesTheStep() throws {
        let state = try fixtureState()
        let window = hostSection(state)
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, identifier: "mapping-step-1-copy") != nil }
        let icon = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "mapping-step-1-copy"),
            "no copy icon; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertEqual(AccessibilityTreeProbe.label(icon), "Copy minimap2 step")
        XCTAssertEqual(AccessibilityTreeProbe.help(icon), "Copy this step")

        XCTAssertTrue(AccessibilityTreeProbe.press(icon))

        XCTAssertEqual(pasteboard.string(forType: .string), try expectedStepText(state.steps[0], in: state))
    }

    /// A version's trailing white space is trimmed from the title, a fact the
    /// record does not hold is left out, and the text never ends in a newline.
    func testStepTextLeavesOutWhatTheRecordDoesNotHold() {
        XCTAssertEqual(
            InspectorStepCopyText.mappingStep(
                MappingDocumentStep(label: "minimap2", command: "minimap2 -a", version: "2.31 \n", recorded: "Oct 16")
            ),
            "minimap2 2.31\nRecorded: Oct 16\nCommand: minimap2 -a"
        )
        XCTAssertEqual(
            InspectorStepCopyText.mappingStep(
                MappingDocumentStep(label: "portable-bam-header", command: "lungfish-cli portable-bam-header a.bam", version: nil, recorded: "Oct 16")
            ),
            "portable-bam-header\nRecorded: Oct 16\nCommand: lungfish-cli portable-bam-header a.bam"
        )
        XCTAssertEqual(
            InspectorStepCopyText.mappingStep(MappingDocumentStep(label: "minimap2", command: "", version: "", recorded: "Oct 16")),
            "minimap2\nRecorded: Oct 16"
        )
    }

    // MARK: - Fixture

    private func stepRow(_ number: Int, in window: NSWindow) throws -> NSObject {
        let identifier = "mapping-step-\(number)"
        AccessibilityTreeProbe.waitUntil { AccessibilityTreeProbe.element(in: window, identifier: identifier) != nil }
        return try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: identifier),
            "no step row \(number); tree:\n" + AccessibilityTreeProbe.dump(window)
        )
    }

    /// The Copy Step text Q-U2 sets for a Document tab step, with the
    /// Recorded text the builder wrote rather than a typed date.
    private func expectedStepText(_ step: MappingDocumentStep, in state: MappingDocumentState) throws -> String {
        let recorded = try XCTUnwrap(state.contextRows.first { $0.0 == "Recorded" }?.1)
        let version = try XCTUnwrap(step.version)
        return "\(step.label) \(version)\nRecorded: \(recorded)\nCommand: \(step.command)"
    }

    private func value(of identifier: String, in window: NSWindow) -> String? {
        AccessibilityTreeProbe.element(in: window, identifier: identifier).flatMap { AccessibilityTreeProbe.value($0) }
    }

    private func hostSection(_ state: MappingDocumentState, width: CGFloat = 460) -> NSWindow {
        let viewModel = DocumentSectionViewModel()
        viewModel.mappingDocument = state
        let window = AccessibilityTreeProbe.host(
            ScrollView { MappingDocumentSection(viewModel: viewModel, pasteboard: pasteboard) },
            size: CGSize(width: width, height: 720)
        )
        windows.append(window)
        return window
    }

    private func frame(of identifier: String, in window: NSWindow) -> NSRect? {
        AccessibilityTreeProbe.element(in: window, identifier: identifier).map { AccessibilityTreeProbe.frame($0) }
    }

    /// The screenshot's run of 2026-10-16, moved into a project folder whose
    /// name has a space: minimap2, then four samtools invocations.
    private func fixtureState() throws -> MappingDocumentState {
        let projectURL = tempRoot.appendingPathComponent("HG002 chr20.lungfish", isDirectory: true)
        let outputDirectory = projectURL.appendingPathComponent("Analyses/minimap2-2026-10-16T20-46-08", isDirectory: true)
        let sample = "SRR35517702-lengthFilter-subsampleCount"
        let reads = projectURL.appendingPathComponent("Analyses/\(sample).lungfishfastq/subsampleCount.fastq.gz")
        readsPath = reads.path
        let reference = projectURL.appendingPathComponent(
            ".tmp/mapping-reference-stage-41B36A8C-9FC1-49ED-82AD-F8D0F393B10B/reference.fa"
        )
        let rawSAM = outputDirectory.appendingPathComponent("\(sample).raw.sam")
        let filteredBAM = outputDirectory.appendingPathComponent("\(sample).filtered.bam")
        let sortedBAM = outputDirectory.appendingPathComponent("\(sample).sorted.bam")
        let readGroup = "@RG\\tID:\(sample)\\tSM:\(sample)\\tLB:\(sample)\\tPL:ILLUMINA\\tPU:\(sample)"

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [reads],
            referenceFASTAURL: reference,
            sourceReferenceBundleURL: projectURL.appendingPathComponent("References/HG002.lungfishref", isDirectory: true),
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: sample,
            pairedEnd: false,
            threads: 14,
            includeSecondary: false,
            includeSupplementary: false,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            sourceReferenceBundleURL: request.sourceReferenceBundleURL,
            viewerBundleURL: outputDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true),
            bamURL: sortedBAM,
            baiURL: outputDirectory.appendingPathComponent("\(sample).sorted.bam.bai"),
            totalReads: 100,
            mappedReads: 91,
            unmappedReads: 9,
            wallClockSeconds: 59.68,
            contigs: []
        )
        let mapper = MappingCommandInvocation(label: "minimap2", argv: [
            "minimap2", "-a", "-x", "sr", "-t", "14", "-R", readGroup, "--secondary=no",
            "-o", rawSAM.path, reference.path, reads.path,
        ])
        XCTAssertGreaterThan(mapper.commandLine.count, 600, "the fixture's mapper command is longer than 600 characters")
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: mapper,
            normalizationInvocations: [
                MappingCommandInvocation(label: "samtools view", argv: ["samtools", "view", "-b", "-o", filteredBAM.path, rawSAM.path]),
                MappingCommandInvocation(label: "samtools sort", argv: ["samtools", "sort", "-@", "7", "-o", sortedBAM.path, filteredBAM.path]),
                MappingCommandInvocation(label: "samtools index", argv: ["samtools", "index", sortedBAM.path]),
                MappingCommandInvocation(label: "samtools flagstat", argv: ["samtools", "flagstat", sortedBAM.path]),
            ],
            mapperVersion: "2.31",
            samtoolsVersion: "1.24"
        )
        return MappingDocumentStateBuilder.build(result: result, provenance: provenance, projectURL: projectURL)
    }
}
