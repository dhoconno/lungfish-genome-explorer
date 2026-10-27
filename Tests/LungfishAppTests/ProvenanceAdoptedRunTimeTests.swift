// ProvenanceAdoptedRunTimeTests.swift - The Run Summary of an adopted Linux run names the Linux run's time and shows no adopt row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

/// Walk finding WO-5 (UX-WALK row WO-5). The record an adopt writes holds the Mac's write of the record as its own wall
/// time, and the Linux run as its `lungfish-executor run` step. The Run Summary read `Wall Time <1s` for a run whose
/// executor step took 5m 46s, so it timed the write of the record and its words did not say so. The summary of an adopted
/// run now reads the run's own wall time as "Wall Time (Linux run)" and shows no row for the record's own time, which
/// times only the Mac's write of the record and not the adopt (UX review SF-1). Any other record keeps "Wall Time".
///
/// The record is the one the 2026-10-26 walk read, unchanged (`Tests/Fixtures/provenance-adopted-run/README.md`). Its
/// step 14 is the quality-count step that runs the `lungfish-executor` binary for 7.1 s, and its step 15 is the run
/// itself, `lungfish-executor run`, for 346.5 s. The run's time is the second.
@MainActor
final class ProvenanceAdoptedRunTimeTests: XCTestCase {
    private let linuxRunLabel = "Wall Time (Linux run)"
    private let adoptLabel = "Adopt Time (this Mac)"
    private let executorRunStep = "lungfish-executor run"

    // MARK: - Harness

    private var adoptedRecord: URL {
        ProvenanceDisplayFixtures.testsDirectory
            .appendingPathComponent("Fixtures/provenance-adopted-run/Imports/SRR24403534.lungfishfastq/.lungfish-provenance.json")
    }

    private var cancelledTrimRecord: URL {
        ProvenanceDisplayFixtures.directory
            .appendingPathComponent("Analyses/fastq-trim-cancelled/.lungfish-provenance.json")
    }

    private func makeProject() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "provenance-adopted-run-time")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Adopted Run.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func place(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func loadModel(_ url: URL, sidebar: SidebarItemType) async -> ProvenanceInspectorViewModel {
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: url, sidebarType: sidebar, contentMode: .genomics, displayName: url.lastPathComponent
        ))
        let finished = await waitUntil(budget: .lookup) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertNotNil(model.resolvedEnvelope, "A record was found for \(url.lastPathComponent).")
        return model
    }

    /// The adopted run's record placed as the sidecar of its bundle in a new project, after `edit` changed its JSON.
    private func loadAdopted(edit: ((inout [String: Any]) -> Void)? = nil) async throws -> ProvenanceInspectorViewModel {
        var bytes = try Data(contentsOf: adoptedRecord)
        if let edit {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            edit(&object)
            bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let bundle = try makeProject().appendingPathComponent("Imports/SRR24403534.lungfishfastq", isDirectory: true)
        try place(bytes, at: bundle.appendingPathComponent(".lungfish-provenance.json"))
        return await loadModel(bundle, sidebar: .fastqBundle)
    }

    private func loadCancelledTrim() async throws -> ProvenanceInspectorViewModel {
        let folder = try makeProject().appendingPathComponent("Analyses/fastq-trim-cancelled", isDirectory: true)
        try place(try Data(contentsOf: cancelledTrimRecord), at: folder.appendingPathComponent(".lungfish-provenance.json"))
        return await loadModel(folder, sidebar: .analysisResult)
    }

    /// Every text of the Run Summary in screen order, each label followed by its value.
    private func runSummaryTexts(_ model: ProvenanceInspectorViewModel) throws -> [String] {
        try ProvenanceSection(viewModel: model).inspect()
            .find(viewWithAccessibilityIdentifier: "provenance-run-summary")
            .findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    /// The value the Run Summary shows under `label`, or nil when no row has that label.
    private func value(of label: String, in texts: [String]) -> String? {
        guard let index = texts.firstIndex(of: label), index + 1 < texts.count else { return nil }
        return texts[index + 1]
    }

    /// The lines of the Copy text's Run Summary block, which ends at the first blank line.
    private func copiedRunSummary(_ model: ProvenanceInspectorViewModel) -> [String] {
        let lines = model.copyableText.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "Run Summary") else { return [] }
        return Array(lines[(start + 1)...].prefix { !$0.isEmpty })
    }

    // MARK: - An adopted run

    /// The summary reads the executor run step's 346.5 s under words that say whose time it is. A quality-count step of
    /// 7.1 s runs the same binary and must not be taken for the run. The record's own 0.08 s times only the Mac's write of
    /// the record, so no row shows it.
    func testTheRunSummaryOfAnAdoptedRunNamesTheLinuxRunsTime() async throws {
        let model = try await loadAdopted()
        let texts = try runSummaryTexts(model)

        XCTAssertEqual(value(of: linuxRunLabel, in: texts), "5m 46s", "\(texts)")
        XCTAssertNil(value(of: adoptLabel, in: texts), "The record's own time is not the adopt's. \(texts)")
        XCTAssertNil(value(of: "Wall Time", in: texts), "An adopted run has no row that says Wall Time and nothing more. \(texts)")
    }

    func testTheLinuxRunRowComesAfterTheExitStatusAndBeforeSteps() async throws {
        let model = try await loadAdopted()
        let texts = try runSummaryTexts(model)

        let exit = try XCTUnwrap(texts.firstIndex(of: "Exit Status"), "\(texts)")
        let run = try XCTUnwrap(texts.firstIndex(of: linuxRunLabel), "\(texts)")
        XCTAssertLessThan(exit, run)
        XCTAssertEqual(texts[run + 2], "Steps", "The Steps row follows the Linux run row. \(texts)")
    }

    func testTheCopyTextOfAnAdoptedRunNamesTheLinuxRunsTimeInSeconds() async throws {
        let model = try await loadAdopted()
        let lines = copiedRunSummary(model)

        XCTAssertTrue(lines.contains("\(linuxRunLabel): 346.52 s"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix(adoptLabel) }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("Wall Time:") }, "No bare Wall Time line. \(lines)")
    }

    /// A launcher record that lost the run's wall time says so in the run's row.
    func testAnAdoptedRunWhoseExecutorStepStatesNoWallTimeReadsNotRecorded() async throws {
        let model = try await loadAdopted { [executorRunStep] object in
            var steps = object["steps"] as? [[String: Any]] ?? []
            for index in steps.indices where steps[index]["toolName"] as? String == executorRunStep {
                steps[index].removeValue(forKey: "wallTimeSeconds")
            }
            object["steps"] = steps
        }
        let texts = try runSummaryTexts(model)

        XCTAssertEqual(value(of: linuxRunLabel, in: texts), "Not recorded", "\(texts)")
        XCTAssertTrue(copiedRunSummary(model).contains("\(linuxRunLabel): Not recorded"), "\(copiedRunSummary(model))")
    }

    // MARK: - Any other record

    func testARecordThatIsNotAnAdoptedRunKeepsWallTime() async throws {
        let model = try await loadCancelledTrim()
        let texts = try runSummaryTexts(model)

        XCTAssertEqual(value(of: "Wall Time", in: texts), "12s", "\(texts)")
        XCTAssertNil(value(of: linuxRunLabel, in: texts), "\(texts)")
        XCTAssertNil(value(of: adoptLabel, in: texts), "\(texts)")
        let lines = copiedRunSummary(model)
        XCTAssertTrue(lines.contains("Wall Time: 12.40 s"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix(linuxRunLabel) || $0.hasPrefix(adoptLabel) }, "\(lines)")
    }
}
