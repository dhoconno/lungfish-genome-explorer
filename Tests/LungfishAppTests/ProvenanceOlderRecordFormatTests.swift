// ProvenanceOlderRecordFormatTests.swift - The Provenance tab labels bare runs and primitive records, and nothing else
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow

/// Plan decisions V6 and S4, UX P-L7. A record that decodes as a bare run or through the primitive
/// adapter is in the Older record format, and no envelope of any version is, nor is a typed record
/// such as `mapping-provenance.json`. A fact that format never held reads Not recorded and does not
/// make the record Incomplete, a fact it could hold and lacks still does, and the label never hides
/// Incomplete. A date the reader invented reads Not recorded.
@MainActor
final class ProvenanceOlderRecordFormatTests: XCTestCase {
    private let olderTitle = "Older record format"
    private let olderMessage = "This record was written in an older format. "
        + "It shows every fact it holds, and a fact that format never recorded reads Not recorded."

    // MARK: - Harness

    private func makeProject() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "provenance-older-format")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Older Records.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func place(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func loadModel(
        _ url: URL,
        sidebar: SidebarItemType = .analysisResult,
        mode: ViewportContentMode = .genomics
    ) async -> ProvenanceInspectorViewModel {
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: url, sidebarType: sidebar, contentMode: mode, displayName: url.lastPathComponent
        ))
        let finished = await waitUntil(budget: .lookup) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertNotNil(model.resolvedEnvelope, "A record was found for \(url.lastPathComponent).")
        return model
    }

    /// A record placed as the sidecar of a new bundle folder of the project, and the model that loaded it.
    private func loadedRecord(_ bytes: Data, bundle: String, sidecar: String = ".lungfish-provenance.json") async throws -> ProvenanceInspectorViewModel {
        let project = try makeProject()
        let folder = project.appendingPathComponent("Analyses/\(bundle)", isDirectory: true)
        try place(bytes, at: folder.appendingPathComponent(sidecar))
        return await loadModel(folder)
    }

    private func titles(_ model: ProvenanceInspectorViewModel) -> [String] {
        model.warnings.map(\.title)
    }

    // MARK: - The bare run

    /// The real record `lungfish-cli` 0.4.0-alpha.11 wrote beside a fetched GFF3. It lists an NCBI address
    /// with no checksum or size, which a bare run could have held, so it is Incomplete, and it is also
    /// the Older record format. The label never hides the gap.
    func testABareRunIsOlderRecordFormatAndStaysIncomplete() async throws {
        let project = try makeProject()
        let name = "MN908947.3.gff3"
        let gff3 = project.appendingPathComponent("Imports/\(name)")
        try place(
            try Data(contentsOf: ProvenanceDisplayFixtures.sarscov2Directory.appendingPathComponent(name)), at: gff3
        )
        try place(
            try Data(contentsOf: ProvenanceDisplayFixtures.sarscov2Directory.appendingPathComponent("\(name).lungfish-provenance.json")),
            at: project.appendingPathComponent("Imports/\(name).lungfish-provenance.json")
        )

        let model = await loadModel(gff3, sidebar: .annotation)

        XCTAssertEqual(model.audit.status, .incomplete)
        XCTAssertTrue(model.audit.isBlocking)
        XCTAssertTrue(model.audit.isOlderRecordFormat)
        XCTAssertEqual(model.summary.statusLabel, "Incomplete record")
        XCTAssertEqual(titles(model), ["File metadata incomplete", olderTitle])
        XCTAssertEqual(model.warnings.last?.message, olderMessage)
    }

    // MARK: - The primitive adapter

    func testAPrimitiveRecordHoldingEveryFactItCouldHoldIsOlderRecordFormat() async throws {
        let model = try await loadedRecord(ProvenanceLegacyRecords.msa, bundle: "Aligned.lungfishmsa")

        XCTAssertEqual(model.audit.status, .legacy)
        XCTAssertFalse(model.audit.isBlocking, "The Older record format is a label and not a failure.")
        XCTAssertTrue(model.audit.isOlderRecordFormat)
        XCTAssertEqual(model.summary.statusLabel, olderTitle)
        XCTAssertEqual(titles(model), [olderTitle])
        XCTAssertEqual(model.warnings.first?.message, olderMessage)
        XCTAssertEqual(model.summary.exitStatus, 0)
        XCTAssertFalse(model.summary.exitStatusNotRecorded, "This record states its exit status.")
    }

    /// An assembler's own record never held an exit status, so the fact reads Not recorded and the record
    /// is not Incomplete for lacking it.
    func testAPrimitiveRecordWithNoExitStatusReadsNotRecordedAndIsNotIncomplete() async throws {
        let model = try await loadedRecord(
            ProvenanceLegacyRecords.assembly, bundle: "assembly-output.lungfishref", sidecar: "assembly/provenance.json"
        )

        XCTAssertEqual(model.audit.status, .legacy)
        XCTAssertNil(model.summary.exitStatus)
        XCTAssertTrue(model.summary.exitStatusNotRecorded)
        XCTAssertFalse(model.summary.wallTimeNotRecorded, "The assembler's record holds its wall time.")
        XCTAssertEqual(titles(model), [olderTitle])
        XCTAssertFalse(model.warnings.contains { $0.message.contains("Exit status") })
        XCTAssertEqual(model.summary.statusLabel, olderTitle)
    }

    /// A fact the format could hold and the record lacks still makes it Incomplete, beside the label.
    func testAPrimitiveRecordMissingAFactItCouldHoldIsStillIncomplete() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ProvenanceLegacyRecords.msa) as? [String: Any])
        object.removeValue(forKey: "wallTimeSeconds")
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let model = try await loadedRecord(bytes, bundle: "Aligned.lungfishmsa")

        XCTAssertEqual(model.audit.status, .incomplete)
        XCTAssertTrue(model.audit.isBlocking)
        XCTAssertTrue(model.audit.isOlderRecordFormat)
        XCTAssertEqual(model.summary.statusLabel, "Incomplete record")
        XCTAssertEqual(titles(model), ["Incomplete record", olderTitle])
        XCTAssertEqual(model.warnings.first?.message, "Wall time is missing.")
        // The shape decides Incomplete and never whether a row shows, so the gap also reads in its row.
        XCTAssertNil(model.summary.wallTimeSeconds)
        XCTAssertTrue(model.summary.wallTimeNotRecorded)
        XCTAssertTrue(model.copyableText.contains("Wall Time: Not recorded"), model.copyableText)
        let inspected = try ProvenanceSection(viewModel: model).inspect()
        XCTAssertTrue(inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }.contains("Wall Time"))
        let values = inspected.findAll(ViewType.Text.self, where: {
            (try? $0.accessibilityIdentifier()) == "provenance-summary-value"
        }).compactMap { try? $0.string() }
        XCTAssertTrue(values.contains("Not recorded"), "\(values)")
    }

    // MARK: - Envelopes and typed records

    /// A version 1 envelope is never the Older record format, and its gaps read as they always did.
    func testAVersion1EnvelopeIsNeverOlderRecordFormat() async throws {
        let incomplete = ProvenanceEnvelope(
            workflowName: "Incomplete",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "0.4.0",
            argv: [],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [],
            output: nil,
            outputs: [],
            steps: [],
            wallTimeSeconds: nil,
            exitStatus: nil,
            stderr: nil
        )
        let model = try await loadedRecord(try ProvenanceJSON.encoder.encode(incomplete), bundle: "Envelope.lungfishmsa")

        XCTAssertEqual(model.audit.status, .incomplete)
        XCTAssertFalse(model.audit.isOlderRecordFormat)
        XCTAssertFalse(titles(model).contains(olderTitle))
        XCTAssertTrue(
            model.warnings.contains { $0.message == "Exit status is missing." },
            "An envelope states its exit status, so a missing one is a gap."
        )
        // The gap is a warning and its row reads Not recorded too, since the shape decides whether it
        // is Incomplete and never whether the row shows.
        XCTAssertTrue(model.summary.exitStatusNotRecorded)
        XCTAssertTrue(model.summary.wallTimeNotRecorded)
    }

    func testACompleteEnvelopeStaysCompleteWithNoOlderRecordFormatNotice() async throws {
        let model = try await loadedRecord(
            try ProvenanceJSON.encoder.encode(ProvenanceEnvelope.fixture()), bundle: "Envelope.lungfishmsa"
        )

        XCTAssertNotEqual(model.audit.status, .legacy)
        XCTAssertFalse(model.audit.isOlderRecordFormat)
        XCTAssertFalse(titles(model).contains(olderTitle))
        XCTAssertNotEqual(model.summary.statusLabel, olderTitle)
    }

    /// `mapping-provenance.json` keeps its own schema and is a typed record, so it is never the Older
    /// record format whatever it lacks.
    func testATypedMappingRecordIsNeverOlderRecordFormat() async throws {
        let project = try makeProject()
        let analysis = project.appendingPathComponent("Analyses/minimap2-2026-07-14T15-20-00", isDirectory: true)
        try place(ProvenanceLegacyRecords.mappingSchema3, at: analysis.appendingPathComponent("mapping-provenance.json"))

        let model = await loadModel(analysis, sidebar: .analysisResult, mode: .mapping)

        XCTAssertEqual(model.resolvedSidecarURL?.lastPathComponent, "mapping-provenance.json")
        XCTAssertFalse(model.audit.isOlderRecordFormat)
        XCTAssertNotEqual(model.audit.status, .legacy)
        XCTAssertFalse(titles(model).contains(olderTitle))
    }

    // MARK: - Every corpus record

    /// Over all ten frozen records the label follows the shape the reader reports and nothing else.
    func testTheLabelFollowsTheShapeOfEveryCorpusRecord() async throws {
        var older = 0
        for item in try ProvenanceCompatCorpus.cases() {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            guard let selection = materialized.selection else { continue }
            let shape = try XCTUnwrap(try ProvenanceEnvelopeReader.read(fromSidecar: materialized.sidecar)).shape
            let model = await loadModel(selection)
            let isOlder = shape == .workflowRun || shape == .primitive

            XCTAssertEqual(model.audit.isOlderRecordFormat, isOlder, "\(item.id) is a \(shape)")
            if isOlder {
                older += 1
                XCTAssertTrue([.legacy, .incomplete].contains(model.audit.status), "\(item.id): \(model.audit.status)")
                XCTAssertTrue(titles(model).contains(olderTitle), "\(item.id) says it is older")
                if model.audit.status == .incomplete {
                    XCTAssertTrue(model.audit.isBlocking, "\(item.id): the label does not hide Incomplete")
                }
            } else {
                XCTAssertNotEqual(model.audit.status, .legacy, "\(item.id) is not older")
                XCTAssertFalse(titles(model).contains(olderTitle), "\(item.id) is not older")
            }
            XCTAssertEqual(model.audit, ProvenanceCoverageMonitor().audit(model.currentItem!), "\(item.id): audit and lookup agree")
            XCTAssertFalse(titles(model).contains("Legacy provenance"), "\(item.id)")
        }
        XCTAssertEqual(older, 5, "The corpus holds three bare runs and two primitive records.")
    }

    // MARK: - Not recorded

    /// A tree record with no `createdAt` was dated by the reader with the sidecar's modification date.
    /// The date is not a fact the record holds, so the Run Summary says Not recorded.
    func testADateTheReaderInventedReadsNotRecorded() async throws {
        let project = try makeProject()
        let folder = project.appendingPathComponent("Analyses/Tree.lungfishtree", isDirectory: true)
        let sidecar = folder.appendingPathComponent(".lungfish-provenance.json")
        try place(ProvenanceLegacyRecords.tree, at: sidecar)
        let fileDate = Date(timeIntervalSince1970: 1_777_777_776)
        try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: sidecar.path)

        let model = await loadModel(folder)

        XCTAssertNil(model.summary.createdAt, "Neither 1970 nor the file's date is shown as if recorded.")
        XCTAssertTrue(model.summary.createdAtNotRecorded)
        XCTAssertEqual(model.audit.status, .legacy)
        XCTAssertTrue(model.copyableText.contains("Created: Not recorded"), model.copyableText)
        let texts = try ProvenanceSection(viewModel: model).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(texts.contains("Created"), "\(texts)")
        let fileDateText = fileDate.formatted(date: .abbreviated, time: .shortened)
        // The Sidecar row's help and accessibility value hold the absolute path, whose random
        // temporary folder name can contain "1970". Look for a date in every other text.
        let folderName = project.deletingLastPathComponent().lastPathComponent
        let shown = texts.filter { !$0.contains(folderName) }
        XCTAssertFalse(shown.contains { $0.contains("1970") || $0.contains(fileDateText) }, "No date is shown. \(texts)")
    }

    func testARecordThatHoldsItsDateShowsIt() async throws {
        let model = try await loadedRecord(ProvenanceLegacyRecords.msa, bundle: "Aligned.lungfishmsa")

        XCTAssertNotNil(model.summary.createdAt)
        XCTAssertFalse(model.summary.createdAtNotRecorded)
    }

    func testTheRunSummaryRowsReadNotRecordedInsteadOfBeingLeftOut() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.summary.createdAtNotRecorded = true
        viewModel.summary.exitStatusNotRecorded = true
        viewModel.summary.wallTimeNotRecorded = true

        let inspected = try ProvenanceSection(viewModel: viewModel).inspect()
        let values = inspected.findAll(ViewType.Text.self, where: {
            (try? $0.accessibilityIdentifier()) == "provenance-summary-value"
        }).compactMap { try? $0.string() }
        XCTAssertEqual(values.filter { $0 == "Not recorded" }.count, 3, "\(values)")
        let labels = inspected.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(
            labels.contains("Created") && labels.contains("Exit Status") && labels.contains("Wall Time"), "\(labels)"
        )
    }

    func testARunSummaryWithNothingMissingLeavesTheseRowsOut() throws {
        let viewModel = ProvenanceInspectorViewModel()
        let labels = try ProvenanceSection(viewModel: viewModel).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertFalse(labels.contains("Created"))
        XCTAssertFalse(labels.contains("Exit Status"))
        XCTAssertFalse(labels.contains("Wall Time"))
    }

    func testEmptyRuntimeRowsReadNotRecordedInPlaceOfTheOldMessage() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.runtimeRows = []

        let texts = try ProvenanceSection(viewModel: viewModel).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertTrue(texts.contains("Not recorded"), "\(texts)")
        XCTAssertFalse(texts.contains("No runtime identity fields are available."))
    }

    func testRuntimeRowsThatAreFilteredOutAreNotCalledNotRecorded() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.runtimeRows = [ProvenanceRuntimeRow(label: "Executable", value: "lungfish-cli")]
        viewModel.searchText = "nothing matches this"

        let texts = try ProvenanceSection(viewModel: viewModel).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertFalse(texts.contains("Not recorded"), "The record holds the row, the filter hides it. \(texts)")
    }
}
