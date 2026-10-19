// MappingDocumentCommandDisplayTests.swift - The mapping Document tab's command as it shows and copies a record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishTestSupport
import SwiftUI
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.25 (CMD-DISPLAY), M2 (PF6 Q-U7) under UX's ruling on the lane after M1.
///
/// A mapping result here is saved as the managed pipeline saves one, with `mapping-result.json`,
/// `mapping-provenance.json` and `.lungfish-provenance.json` in `Analyses/minimap2-run` of a temporary project, and
/// its reads in `Analyses/m/reads.fastq`.
@MainActor
final class MappingDocumentCommandDisplayTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MappingDocumentCommandDisplayTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        pasteboard.releaseGlobally()
        pasteboard = nil
        try await super.tearDown()
    }

    // MARK: - A renamed mapping result (the pin at the base)

    /// The sidebar renames the folder that holds a mapping result. The pin records what the Document tab's Run Settings
    /// command shows and copies, whether the rename rewrote `mapping-provenance.json`, the record the tab reads, and
    /// what the Sorted BAM row names. At the base the row draws the step's command as it is (`Text(step.command)`).
    func testARenamedMappingResultsDocumentCommandAtTheBase() throws {
        let saved = try savedResult()
        let recordBytes = try Data(contentsOf: saved.folder.appendingPathComponent(MappingProvenance.filename))
        let renamed = saved.folder.deletingLastPathComponent().appendingPathComponent("minimap2-run renamed", isDirectory: true)
        try FileManager.default.moveItem(at: saved.folder, to: renamed)
        SidebarViewController().rehydrateScientificProvenance(from: saved.folder, to: renamed)
        let redact = ProvenanceDisplayRedaction(projectURL: saved.project)

        let result = try MappingResult.load(from: renamed)
        let provenance = try XCTUnwrap(MappingProvenance.load(from: renamed))
        let state = MappingDocumentStateBuilder.build(result: result, provenance: provenance, projectURL: saved.project)
        let window = hostSection(state)
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Command", on: try element("mapping-step-1", in: window)))

        let facts: [String: String] = [
            "shown": redact(state.steps[0].command),
            "copied": pasteboard.string(forType: .string).map { redact($0) } ?? "nil",
            "mappingRecordUnchanged": String(
                try Data(contentsOf: renamed.appendingPathComponent(MappingProvenance.filename)) == recordBytes
            ),
            "sortedBAMRow": state.artifactRows.first { $0.label == "Sorted BAM" }?.fileURL.map { redact($0.path) } ?? "nil",
        ]
        let mapper = "minimap2 -a -x sr -t 4 -o <project>/Analyses/minimap2-run/sample.raw.sam "
            + "<project>/References/ref.fa <project>/Analyses/m/reads.fastq"
        XCTAssertEqual(facts, [
            "shown": mapper,
            "copied": mapper,
            "mappingRecordUnchanged": "true",
            "sortedBAMRow": "<project>/Analyses/minimap2-run renamed/sample.sorted.bam",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.folder.path), "the folder the command names is gone")
    }

    // MARK: - Fixtures

    struct SavedResult {
        let project: URL
        let folder: URL
        let reads: URL
        let state: MappingDocumentState
    }

    /// A minimap2 run and two samtools steps, saved as `ManagedMappingPipeline` saves them, with every file on disk.
    func savedResult() throws -> SavedResult {
        let root = try TestTempDirectory.make(prefix: "mapping-document-command")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Commands.lungfish", isDirectory: true)
        let folder = project.appendingPathComponent("Analyses/minimap2-run", isDirectory: true)
        let reads = project.appendingPathComponent("Analyses/m/reads.fastq")
        let reference = project.appendingPathComponent("References/ref.fa")
        let rawSAM = folder.appendingPathComponent("sample.raw.sam")
        let sortedBAM = folder.appendingPathComponent("sample.sorted.bam")
        let bai = folder.appendingPathComponent("sample.sorted.bam.bai")
        for url in [folder, reads.deletingLastPathComponent(), reference.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: reads)
        try Data(">c\nACGT\n".utf8).write(to: reference)
        try Data("bam".utf8).write(to: sortedBAM)
        try Data("bai".utf8).write(to: bai)

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [reads],
            referenceFASTAURL: reference,
            sourceReferenceBundleURL: nil,
            projectURL: project,
            outputDirectory: folder,
            sampleName: "sample",
            pairedEnd: false,
            threads: 4,
            includeSecondary: false,
            includeSupplementary: false,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
        let result = MappingResult(
            mapper: .minimap2, modeID: request.modeID, sourceReferenceBundleURL: nil, viewerBundleURL: nil,
            bamURL: sortedBAM, baiURL: bai, totalReads: 1, mappedReads: 1, unmappedReads: 0, wallClockSeconds: 1, contigs: []
        )
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: MappingCommandInvocation(label: "minimap2", argv: [
                "minimap2", "-a", "-x", "sr", "-t", "4", "-o", rawSAM.path, reference.path, reads.path,
            ]),
            normalizationInvocations: [
                MappingCommandInvocation(label: "samtools sort", argv: ["samtools", "sort", "-o", sortedBAM.path, rawSAM.path]),
                MappingCommandInvocation(label: "samtools index", argv: ["samtools", "index", sortedBAM.path]),
            ],
            mapperVersion: "2.31",
            samtoolsVersion: "1.24"
        )
        try result.save(to: folder)
        try provenance.save(to: folder)
        try provenance.saveCanonicalEnvelope(
            to: folder, runCommand: ["lungfish-cli", "map", reads.path, "--reference", reference.path, "--output", folder.path]
        )
        let state = MappingDocumentStateBuilder.build(result: result, provenance: provenance, projectURL: project)
        return SavedResult(project: project, folder: folder, reads: reads, state: state)
    }

    func hostSection(_ state: MappingDocumentState) -> NSWindow {
        let viewModel = DocumentSectionViewModel()
        viewModel.mappingDocument = state
        let window = AccessibilityTreeProbe.host(
            ScrollView { MappingDocumentSection(viewModel: viewModel, pasteboard: pasteboard) },
            size: CGSize(width: 460, height: 720)
        )
        windows.append(window)
        return window
    }

    func element(_ identifier: String, in window: NSWindow) throws -> NSObject {
        AccessibilityTreeProbe.waitUntil(timeout: 10) { AccessibilityTreeProbe.element(in: window, identifier: identifier) != nil }
        return try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: identifier),
            "no \(identifier); tree:\n" + AccessibilityTreeProbe.dump(window)
        )
    }
}
