// ProvenanceRunStatusDisplayTests.swift - The Run Summary says how a run ended, and the Runtime rows drop a Process ID no record holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

/// Plan decision P14, lane U3a. The coverage audit counts missing facts only, so a failed or cancelled
/// run whose record holds every fact read Complete and said nothing else about the run. The Run Summary
/// now has a Run Status row that reads the record's own `status`, and reads Not recorded when the record
/// states none and the reader derived one. The Runtime rows have no Process ID row for a record at version
/// 2 or later, which never holds one.
///
/// The cases load the committed `fastq trim` records of `Tests/Fixtures/provenance-display/Analyses`,
/// and edit their bytes where a case needs another record. Every case reads a copy in a temporary
/// project, and none changes the copy.
@MainActor
final class ProvenanceRunStatusDisplayTests: XCTestCase {

    // MARK: - The row

    func testACancelledRunReadsCancelledInTheCopyTextAndTheView() async throws {
        let model = try await loadedModel(try recordBytes("fastq-trim-cancelled"))

        XCTAssertEqual(model.summary.statusLabel, "Complete", "The audit label still says the record holds every fact.")
        XCTAssertEqual(model.summary.runStatus, .stated(.cancelled))
        XCTAssertTrue(model.copyableText.contains("Run Status: Cancelled"), model.copyableText)
        let texts = try summaryTexts(of: model)
        XCTAssertTrue(texts.contains("Run Status") && texts.contains("Cancelled"), "\(texts)")
    }

    func testAFailedRunReadsFailedInTheCopyTextAndTheView() async throws {
        let model = try await loadedModel(try recordBytes("fastq-trim-failed"))

        XCTAssertEqual(model.summary.statusLabel, "Complete")
        XCTAssertEqual(model.summary.runStatus, .stated(.failed))
        XCTAssertTrue(model.copyableText.contains("Run Status: Failed"), model.copyableText)
        let texts = try summaryTexts(of: model)
        XCTAssertTrue(texts.contains("Run Status") && texts.contains("Failed"), "\(texts)")
    }

    /// The row joins the two facts about how the run ended, so it sits just before the exit status in the
    /// Copy text and in the order the view lists the rows, which is the order VoiceOver reads them.
    func testTheRowSitsBetweenCreatedAndExitStatusInTheCopyTextAndTheView() async throws {
        let model = try await loadedModel(try recordBytes("fastq-trim-cancelled"))

        let copy = model.copyableText
        let created = try XCTUnwrap(copy.range(of: "Created: "), copy)
        let status = try XCTUnwrap(copy.range(of: "Run Status: "), copy)
        let exit = try XCTUnwrap(copy.range(of: "Exit Status: "), copy)
        XCTAssertLessThan(created.lowerBound, status.lowerBound)
        XCTAssertLessThan(status.lowerBound, exit.lowerBound)

        let texts = try summaryTexts(of: model)
        let positions = ["Created", "Run Status", "Cancelled", "Exit Status"].compactMap { texts.firstIndex(of: $0) }
        XCTAssertEqual(positions.count, 4, "\(texts)")
        XCTAssertEqual(positions, positions.sorted(), "\(texts)")
    }

    /// The reader derives a status from the exit status when the record states none, and a derived
    /// completed cannot tell a completed run from a cancelled one. The row reads Not recorded.
    func testAStatusTheRecordDoesNotStateReadsNotRecordedWhateverWordTheReaderDerived() async throws {
        let bytes = try recordBytes("fastq-trim-cancelled") { $0.removeValue(forKey: "status") }

        let model = try await loadedModel(bytes)

        XCTAssertEqual(model.resolvedEnvelope?.status, .completed, "The reader derives completed from the exit status 0.")
        XCTAssertTrue(model.copyableText.contains("Run Status: Not recorded"), model.copyableText)
        XCTAssertFalse(model.copyableText.contains("Run Status: Completed"), model.copyableText)
    }

    func testARecordThatStatesRunningReadsNotFinished() async throws {
        let bytes = try recordBytes("fastq-trim-cancelled") { $0["status"] = "running" }

        let model = try await loadedModel(bytes)

        XCTAssertTrue(model.copyableText.contains("Run Status: Not finished"), model.copyableText)
    }

    // MARK: - The Process ID row

    func testAVersion2RecordShowsNoProcessIDRow() async throws {
        for folder in ["fastq-trim-cancelled", "fastq-trim-failed"] {
            let model = try await loadedModel(try recordBytes(folder))

            XCTAssertEqual(
                model.runtimeRows.map(\.label), ["App Version", "Executable", "OS", "Architecture", "Dependency Set"],
                folder
            )
            XCTAssertFalse(model.copyableText.contains("Process ID"), model.copyableText)
        }
    }

    /// A record shows every fact it holds. A hand-edited version 2 record that names a process keeps the row.
    func testAVersion2RecordThatHoldsAProcessIDKeepsTheRow() async throws {
        let bytes = try recordBytes("fastq-trim-cancelled") { object in
            var runtime = object["runtimeIdentity"] as? [String: Any] ?? [:]
            runtime["processIdentifier"] = 4242
            object["runtimeIdentity"] = runtime
        }

        let model = try await loadedModel(bytes)

        XCTAssertEqual(processID(of: model), "4242")
    }

    /// Version 1 records recorded the process, and a version 1 record without one still says so.
    func testAVersion1RecordKeepsTheRowWhetherOrNotItHoldsAProcessID() async throws {
        let withoutOne = try await loadedModel(try recordBytes("fastq-trim-cancelled") { $0["schemaVersion"] = 1 })
        XCTAssertEqual(processID(of: withoutOne), "Not recorded")

        let withOne = try await loadedModel(try recordBytes("fastq-trim-cancelled") { object in
            var runtime = object["runtimeIdentity"] as? [String: Any] ?? [:]
            runtime["processIdentifier"] = 4242
            object["runtimeIdentity"] = runtime
            object["schemaVersion"] = 1
        })
        XCTAssertEqual(processID(of: withOne), "4242")
    }

    /// The rule reads the shape the reader decoded and the version the record states. It keeps a process ID
    /// a record holds, and it keeps the row of a bare run, whose envelope the reader builds at the current
    /// version although the bytes state none.
    func testTheProcessIDRowGoesOnlyWhereTheRecordCannotHoldOne() throws {
        let rows = [
            ProvenanceRuntimeRow(label: "Executable", value: "lungfish-cli"),
            ProvenanceRuntimeRow(label: "Process ID", value: "Not recorded"),
        ]
        func remaining(_ data: Data, passingTheReading: Bool = true) throws -> [String] {
            let reading = try ProvenanceEnvelopeReader.read(data)
            return ProvenanceInspectorViewModel
                .withoutUnrecordedProcessID(rows, in: reading.envelope, reading: passingTheReading ? reading : nil)
                .map(\.label)
        }
        let kept = ["Executable", "Process ID"]

        let version2 = try recordBytes("fastq-trim-cancelled")
        XCTAssertEqual(try remaining(version2), ["Executable"], "A version 2 envelope holds no process ID.")
        XCTAssertEqual(try remaining(version2, passingTheReading: false), ["Executable"], "A record a loader verified has no reading.")
        XCTAssertEqual(try remaining(try recordBytes("fastq-trim-cancelled") { $0["schemaVersion"] = 1 }), kept)
        XCTAssertEqual(try remaining(try recordBytes("fastq-trim-cancelled") { object in
            var runtime = object["runtimeIdentity"] as? [String: Any] ?? [:]
            runtime["processIdentifier"] = 4242
            object["runtimeIdentity"] = runtime
        }), kept, "A record shows a process ID it holds, whatever its version.")

        let bareRun = try Data(contentsOf: ProvenanceDisplayFixtures.sarscov2Directory
            .appendingPathComponent("MN908947.3.gff3.lungfish-provenance.json"))
        let bareReading = try ProvenanceEnvelopeReader.read(bareRun)
        XCTAssertEqual(bareReading.shape, .workflowRun)
        XCTAssertGreaterThanOrEqual(
            bareReading.envelope.schemaVersion, 2, "The reader builds a bare run's envelope at the current version."
        )
        XCTAssertEqual(try remaining(bareRun), kept, "The bytes of a bare run state no version, so its row stays.")
    }

    // MARK: - The words of the row

    func testEachStatedStatusReadsInPlainWords() {
        let words = [RunStatus.running, .completed, .failed, .cancelled].map {
            ProvenanceRunStatusDisplay($0, wasRecorded: true).label
        }

        XCTAssertEqual(words, ["Not finished", "Completed", "Failed", "Cancelled"])
    }

    func testAStatusTheReaderDerivedReadsNotRecordedWhateverTheWord() {
        for status in [RunStatus.running, .completed, .failed, .cancelled] {
            XCTAssertEqual(ProvenanceRunStatusDisplay(status, wasRecorded: false), .notRecorded)
        }
        XCTAssertEqual(ProvenanceRunStatusDisplay.notRecorded.label, "Not recorded")
    }

    // MARK: - VoiceOver

    /// VoiceOver reads the section's accessibility tree in the order the view lists its rows. The Run Status
    /// row and its value come between Created and Exit Status, as they do in the Copy text.
    func testVoiceOverReadsTheRowBetweenCreatedAndExitStatus() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.summary = ProvenanceRunSummary(
            workflowName: "lungfish fastq trim",
            createdAt: Date(timeIntervalSince1970: 1_791_609_019),
            statusLabel: "Complete",
            runStatus: .stated(.cancelled),
            exitStatus: 0,
            wallTimeSeconds: 12.4,
            stepCount: 1
        )
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: viewModel))
        defer { window.orderOut(nil) }
        func spoken() -> [String] {
            AccessibilityTreeProbe.all(in: window).flatMap { element in
                [AccessibilityTreeProbe.label(element), AccessibilityTreeProbe.value(element)].compactMap { $0 }
            }
        }

        AccessibilityTreeProbe.waitUntil { spoken().contains("Run Status") }
        let heard = spoken()
        let positions = ["Created", "Run Status", "Cancelled", "Exit Status"].compactMap { heard.firstIndex(of: $0) }
        XCTAssertEqual(positions.count, 4, "\(heard)\n" + AccessibilityTreeProbe.dump(window))
        XCTAssertEqual(positions, positions.sorted(), "\(heard)")
    }

    // MARK: - Reading writes nothing

    func testShowingTheRowsChangesNothingInTheProject() async throws {
        let (project, sidecar) = try makeProject(recordBytes("fastq-trim-failed"))
        let before = try projectSnapshot(project)

        _ = try await load(project: project)

        XCTAssertEqual(try projectSnapshot(project), before, "Reading a record never writes into the project.")
        XCTAssertEqual(try Data(contentsOf: sidecar), try recordBytes("fastq-trim-failed"))
    }

    // MARK: - Harness

    /// The committed record of `folder`, after `edit` changed its decoded JSON.
    private func recordBytes(
        _ folder: String,
        editing edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> Data {
        let url = ProvenanceDisplayFixtures.directory
            .appendingPathComponent("Analyses/\(folder)/.lungfish-provenance.json")
        let original = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func loadedModel(_ bytes: Data) async throws -> ProvenanceInspectorViewModel {
        let (project, _) = try makeProject(bytes)
        return try await load(project: project)
    }

    /// A temporary `.lungfish` project that holds `bytes` as the record of `Analyses/fastq-trim-run`.
    private func makeProject(_ bytes: Data) throws -> (project: URL, sidecar: URL) {
        let root = try TestTempDirectory.make(prefix: "provenance-run-status")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Runs.lungfish", isDirectory: true)
        let sidecar = project.appendingPathComponent("Analyses/fastq-trim-run/.lungfish-provenance.json")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: sidecar, options: .atomic)
        return (project, sidecar)
    }

    private func load(project: URL) async throws -> ProvenanceInspectorViewModel {
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: project.appendingPathComponent("Analyses/fastq-trim-run", isDirectory: true),
            sidebarType: .analysisResult,
            contentMode: .genomics,
            displayName: "fastq-trim-run"
        ))
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertNotNil(model.resolvedEnvelope, "The record was not found.")
        return model
    }

    /// The text of every label and value the section draws, in the order it draws them.
    private func summaryTexts(of model: ProvenanceInspectorViewModel) throws -> [String] {
        try ProvenanceSection(viewModel: model).inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    private func processID(of model: ProvenanceInspectorViewModel) -> String? {
        model.runtimeRows.first { $0.label == "Process ID" }?.value
    }

    /// Every path under `project` with the bytes of each file, so a write of any kind shows.
    private func projectSnapshot(_ project: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false
            snapshot[url.path] = isFile ? try Data(contentsOf: url) : Data()
        }
        return snapshot
    }
}
