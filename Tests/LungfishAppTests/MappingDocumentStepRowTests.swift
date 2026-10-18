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

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingDocumentStepRowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
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

    // MARK: - Fixture

    private func value(of identifier: String, in window: NSWindow) -> String? {
        AccessibilityTreeProbe.element(in: window, identifier: identifier).flatMap { AccessibilityTreeProbe.value($0) }
    }

    private func hostSection(_ state: MappingDocumentState, width: CGFloat = 460) -> NSWindow {
        let viewModel = DocumentSectionViewModel()
        viewModel.mappingDocument = state
        let window = AccessibilityTreeProbe.host(
            ScrollView { MappingDocumentSection(viewModel: viewModel) },
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
