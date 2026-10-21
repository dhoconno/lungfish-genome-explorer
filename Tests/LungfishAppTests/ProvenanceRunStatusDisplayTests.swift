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
/// run whose record holds every fact read Complete record and said nothing else about the run. The Run Summary
/// now has a Run Status row that reads the record's own `status`, and reads Not recorded when the record
/// states none and the reader derived one. The Runtime rows have no Process ID row for a record whose format
/// never holds one. That is an envelope at version 2 or later, a typed record, and a version 1 envelope that
/// states its own status and holds no process ID, which is the shape of the alignment and tree records of
/// Phase 2.7 that hold `createdAt` (alignment export, discriminating sites, subtree export, derived trees and
/// tree import).
///
/// The cases load the committed `fastq trim` records of `Tests/Fixtures/provenance-display/Analyses`,
/// and edit their bytes where a case needs another record. Every case reads a copy in a temporary
/// project, and none changes the copy.
@MainActor
final class ProvenanceRunStatusDisplayTests: XCTestCase {

    // MARK: - The row

    func testACancelledRunReadsCancelledInTheCopyTextAndTheView() async throws {
        let model = try await loadedModel(try recordBytes("fastq-trim-cancelled"))

        XCTAssertEqual(model.summary.statusLabel, "Complete record", "The audit label still says the record holds every fact.")
        XCTAssertEqual(model.summary.runStatus, .stated(.cancelled))
        XCTAssertTrue(model.copyableText.contains("Run Status: Cancelled"), model.copyableText)
        let texts = try summaryTexts(of: model)
        XCTAssertTrue(texts.contains("Run Status") && texts.contains("Cancelled"), "\(texts)")
    }

    func testAFailedRunReadsFailedInTheCopyTextAndTheView() async throws {
        let model = try await loadedModel(try recordBytes("fastq-trim-failed"))

        XCTAssertEqual(model.summary.statusLabel, "Complete record")
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

    /// A version 1 envelope that states its own status and holds no process ID shows no row. The alignment and
    /// tree records of Phase 2.7 that hold `createdAt` (alignment export, discriminating sites, subtree export,
    /// derived trees and tree import) have that shape and record no process ID (plan decision P13), so the row
    /// could only read Not recorded beside a record that reads Complete record.
    func testAVersion1RecordThatStatesItsStatusAndHoldsNoProcessIDShowsNoRow() async throws {
        let model = try await loadedModel(try recordBytes("fastq-trim-cancelled") { $0["schemaVersion"] = 1 })

        XCTAssertEqual(model.resolvedEnvelope?.schemaVersion, 1)
        XCTAssertEqual(model.summary.runStatus, .stated(.cancelled))
        XCTAssertNil(processID(of: model), "\(model.runtimeRows)")
        XCTAssertFalse(model.copyableText.contains("Process ID"), model.copyableText)
    }

    /// A version 1 envelope that states no status was written before Phase 2.7, when the writers recorded the
    /// process, so a process ID it lacks is a gap and still reads Not recorded.
    func testAVersion1RecordThatStatesNoStatusKeepsTheRowAsNotRecorded() async throws {
        let model = try await loadedModel(try recordBytes("fastq-trim-cancelled") { object in
            object["schemaVersion"] = 1
            object.removeValue(forKey: "status")
        })

        XCTAssertEqual(model.summary.runStatus, .notRecorded)
        XCTAssertEqual(processID(of: model), "Not recorded")
    }

    /// A record shows every fact it holds, so a version 1 record that names a process shows it, whether or not it
    /// states a status.
    func testAVersion1RecordThatHoldsAProcessIDKeepsTheRow() async throws {
        for statesItsStatus in [true, false] {
            let model = try await loadedModel(try recordBytes("fastq-trim-cancelled") { object in
                var runtime = object["runtimeIdentity"] as? [String: Any] ?? [:]
                runtime["processIdentifier"] = 4242
                object["runtimeIdentity"] = runtime
                object["schemaVersion"] = 1
                if !statesItsStatus { object.removeValue(forKey: "status") }
            })

            XCTAssertEqual(processID(of: model), "4242", "status stated: \(statesItsStatus)")
        }
    }

    /// The rule decides by the record's format, not by a version the reader may have filled in. It keeps a
    /// process ID a record holds. It keeps the row of a bare run, whose envelope the reader builds at the
    /// current version although the bytes state none, and the row of a primitive record, whatever version its
    /// own JSON states. A version 1 envelope loses the row only when it states its own status, as the 2.7 native
    /// writers do, and an envelope that embeds a legacy run keeps it. The `typed-mapping-schema3` expected file
    /// pins the typed record, which loses the row.
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
        let version1WithItsStatus = try recordBytes("fastq-trim-cancelled") { $0["schemaVersion"] = 1 }
        XCTAssertEqual(
            try remaining(version1WithItsStatus), ["Executable"],
            "A version 1 envelope that states its status and holds no process ID has no row to show."
        )
        XCTAssertEqual(
            try remaining(version1WithItsStatus, passingTheReading: false), kept,
            "A record a loader verified has no reading, so its version decides alone."
        )
        XCTAssertEqual(try remaining(try recordBytes("fastq-trim-cancelled") { object in
            object["schemaVersion"] = 1
            object.removeValue(forKey: "status")
        }), kept, "A version 1 envelope that states no status was written when the writers recorded the process.")
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

        // A released envelope that embeds a legacy run states its status through the run, and its writers
        // recorded the process. This copy of the MHC record lost its process ID, which is a gap, so it keeps
        // its row although it is a version 1 envelope that states a status.
        let embeddedRun = try edited(try Data(contentsOf: ProvenanceDisplayFixtures.directory.appendingPathComponent(
            "Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref/.lungfish-provenance.json"
        ))) { object in
            var runtime = object["runtimeIdentity"] as? [String: Any] ?? [:]
            runtime.removeValue(forKey: "processIdentifier")
            object["runtimeIdentity"] = runtime
        }
        let embeddedReading = try ProvenanceEnvelopeReader.read(embeddedRun)
        XCTAssertEqual(embeddedReading.shape, .envelope)
        XCTAssertEqual(embeddedReading.envelope.schemaVersion, 1)
        XCTAssertTrue(embeddedReading.statusWasRecorded)
        XCTAssertNotNil(embeddedReading.envelope.legacyRun)
        XCTAssertNil(embeddedReading.envelope.runtimeIdentity.processIdentifier)
        XCTAssertEqual(try remaining(embeddedRun), kept, "An envelope that embeds a legacy run keeps its row.")

        // The primitive adapter reads the version from the record's own JSON, so a primitive record can state
        // 2. Its format is the Older record format, which shows every fact it lacks as Not recorded. The MSA
        // record holds process ID 42 and would keep its row anyway, so this copy holds none.
        let primitiveAtVersion2 = try edited(ProvenanceLegacyRecords.msa) { object in
            object["schemaVersion"] = 2
            var runtime = object["runtimeIdentity"] as? [String: Any] ?? [:]
            runtime.removeValue(forKey: "processIdentifier")
            object["runtimeIdentity"] = runtime
        }
        let primitiveReading = try ProvenanceEnvelopeReader.read(primitiveAtVersion2)
        XCTAssertEqual(primitiveReading.shape, .primitive)
        XCTAssertEqual(primitiveReading.envelope.schemaVersion, 2, "The adapter reads the version the record states.")
        XCTAssertNil(primitiveReading.envelope.runtimeIdentity.processIdentifier)
        XCTAssertEqual(
            try remaining(primitiveAtVersion2), kept,
            "A primitive record keeps its row whatever version its own JSON states."
        )
    }

    // MARK: - A record a native loader verified

    /// A native bundle loader (primer orders and analyses) hands the Inspector a record it has already verified,
    /// so no lookup ran and the record has no reading. The row counts it as stating its status, because a
    /// canonical envelope does, and the Process ID rule reads its version. This pins both through the real
    /// `configureVerifiedSources` path, where the one other render test is skipped.
    func testAVerifiedRecordReadsItsStatedStatusAndShowsNoProcessIDRow() throws {
        let (_, sidecar) = try makeProject(recordBytes("fastq-trim-cancelled"))
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: sidecar), sidecarURL: sidecar)
        let model = ProvenanceInspectorViewModel()

        model.configureVerifiedSources([
            ProvenanceSource(
                id: sidecar.path,
                name: "Analysis",
                item: ProvenanceInspectableItem(
                    url: sidecar.deletingLastPathComponent(),
                    sidebarType: .primerAnalysisBundle,
                    contentMode: .genomics,
                    displayName: "Analysis"
                ),
                verifiedRecord: VerifiedProvenanceRecord(envelope: envelope, sidecarURL: sidecar)
            ),
        ])

        XCTAssertEqual(envelope.status, .cancelled, "The fixture record states that the run was cancelled.")
        XCTAssertEqual(model.summary.runStatus, .stated(.cancelled))
        XCTAssertTrue(model.copyableText.contains("Run Status: Cancelled"), model.copyableText)
        XCTAssertFalse(model.runtimeRows.contains { $0.label == "Process ID" }, "\(model.runtimeRows)")
        XCTAssertFalse(model.copyableText.contains("Process ID"), model.copyableText)
    }

    /// Lane U3, finding P4 of Phase 2.8. `VerifiedProvenanceRecord` once held no flag for a stated status, so a
    /// verified record whose bytes hold no `status` showed the word the decoder derived from the exit status as
    /// if the record had stated it. The same bytes found by a lookup read Not recorded, and now so do these.
    func testAVerifiedRecordThatStatesNoStatusReadsNotRecorded() throws {
        let bytes = try recordBytes("fastq-trim-cancelled") { $0.removeValue(forKey: "status") }
        let (project, sidecar) = try makeProject(bytes)
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: sidecar), sidecarURL: sidecar)
        let model = ProvenanceInspectorViewModel()
        let before = try projectSnapshot(project)
        // The loader decodes the bytes off the main actor and says whether the record stated its status.
        var source = verifiedSource(envelope, sidecar: sidecar)
        source.verifiedRecord?.statusWasRecorded = try ProvenanceEnvelopeReader.read(bytes).statusWasRecorded

        model.configureVerifiedSources([source])

        XCTAssertEqual(try projectSnapshot(project), before, "Reading a verified record never writes into the project.")
        XCTAssertEqual(envelope.status, .completed, "The decoder derives completed from the exit status 0.")
        XCTAssertEqual(model.summary.runStatus, .notRecorded)
        XCTAssertTrue(model.copyableText.contains("Run Status: Not recorded"), model.copyableText)
        XCTAssertFalse(model.copyableText.contains("Run Status: Completed"), model.copyableText)
    }

    /// Lane U35, M2 item 2. The view model reads nothing from the sidecar of a verified record. It once read the
    /// sidecar on the main actor for each presentation, and a sidecar whose text held no `status` answered Not
    /// recorded here. A record whose loader said nothing now counts as stating its status, as a canonical envelope
    /// does, whatever its sidecar holds.
    func testAVerifiedRecordWhoseLoaderSaidNothingReadsNothingFromItsSidecar() throws {
        let bytes = try recordBytes("fastq-trim-cancelled") { $0.removeValue(forKey: "status") }
        let (_, sidecar) = try makeProject(bytes)
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: sidecar), sidecarURL: sidecar)
        let source = verifiedSource(envelope, sidecar: sidecar)
        XCTAssertNil(source.verifiedRecord?.statusWasRecorded, "this loader said nothing")
        let model = ProvenanceInspectorViewModel()

        model.configureVerifiedSources([source])

        XCTAssertEqual(model.summary.runStatus, .stated(.completed), "the sidecar's missing status changed nothing")
    }

    /// A loader that decoded the record's bytes says whether the record stated its status, and its answer is the
    /// only one, in both directions.
    func testALoadersAnswerOnWhetherTheRecordStatedItsStatusWinsOverTheSidecar() throws {
        let stated = try makeProject(recordBytes("fastq-trim-cancelled")).sidecar
        let derived = try makeProject(recordBytes("fastq-trim-cancelled") { $0.removeValue(forKey: "status") }).sidecar
        func runStatus(of sidecar: URL, loaderSays: Bool) throws -> ProvenanceRunStatusDisplay? {
            let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: sidecar), sidecarURL: sidecar)
            var source = verifiedSource(envelope, sidecar: sidecar)
            source.verifiedRecord?.statusWasRecorded = loaderSays
            let model = ProvenanceInspectorViewModel()
            model.configureVerifiedSources([source])
            return model.summary.runStatus
        }

        XCTAssertEqual(try runStatus(of: stated, loaderSays: false), .notRecorded)
        XCTAssertEqual(try runStatus(of: derived, loaderSays: true), .stated(.completed))
    }

    /// A sidecar that cannot be read leaves the old rule in place. A canonical envelope states its status.
    func testAVerifiedRecordWhoseSidecarCannotBeReadCountsAsStatingItsStatus() throws {
        let (_, sidecar) = try makeProject(recordBytes("fastq-trim-cancelled"))
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: sidecar), sidecarURL: sidecar)
        let missing = sidecar.deletingLastPathComponent().appendingPathComponent("no-such-record.json")
        let model = ProvenanceInspectorViewModel()

        model.configureVerifiedSources([verifiedSource(envelope, sidecar: missing)])

        XCTAssertEqual(model.summary.runStatus, .stated(.cancelled))
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

    /// The status line under the section title judges the record, and Run Status says how the run ended, so a
    /// failed run can have a complete record. The audit labels that stood alone name their subject, and
    /// "Complete record" beside "Failed" no longer reads as a contradiction (plan decision P14). Invalid and Stale
    /// were the last two that did not, and they read Invalid record and Stale record (Phase 2.8 lane U3, P1).
    func testTheAuditLabelsNameTheRecordTheyJudge() {
        let words = [
            ProvenanceAuditStatus.present, .incomplete, .legacy, .missing, .notRequired, .invalid, .stale,
        ].map(\.displayName)

        XCTAssertEqual(
            words,
            [
                "Complete record", "Incomplete record", "Older record format", "Missing provenance",
                "No provenance required", "Invalid record", "Stale record",
            ]
        )
    }

    /// A verified record that cannot be read is the one producer of Invalid. Its status line and its Warnings
    /// title read the same words, so the Warnings block never names the problem differently from the line above it.
    func testAnUnreadableVerifiedRecordReadsInvalidRecordInTheStatusLineAndTheWarning() {
        let model = ProvenanceInspectorViewModel()

        model.presentUnavailableVerifiedRecord(
            item: ProvenanceInspectableItem(
                url: URL(fileURLWithPath: "/tmp/analysis.lungfishprimers"),
                sidebarType: .primerAnalysisBundle,
                contentMode: .genomics,
                displayName: "Analysis"
            ),
            message: "The analysis record could not be read."
        )

        XCTAssertEqual(model.summary.statusLabel, "Invalid record")
        XCTAssertEqual(model.warnings.map(\.title), ["Invalid record"])
        XCTAssertEqual(model.copyableText, "Invalid record\nThe analysis record could not be read.")
    }

    /// The status line has a tooltip, which SwiftUI also gives to VoiceOver as its help (Phase 2.8 lane U3, P3).
    func testTheStatusLineHelpSaysWhatItJudgesAndWhatRunStatusSays() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.summary.statusLabel = "Complete record"
        viewModel.summary.runStatus = .stated(.completed)

        let inspected = try ProvenanceSection(viewModel: viewModel).inspect()
        let status = try inspected.find(ViewType.Label.self, where: {
            (try? $0.find(text: "Complete record")) != nil
        })

        XCTAssertEqual(
            try status.help().string(),
            "The status line says whether the record holds every fact LGE expects. Run Status says how the run ended."
        )
    }

    /// Lane U35, M2 item 2 (row 273 of Phase 2.8). The help tells the status line from the Run Status row, so it shows
    /// while that row sits below the line and not where the line names no record. No provenance required, Missing
    /// provenance and Invalid record (an unreadable verified record) show no Run Status row, and their words need no help.
    func testTheStatusLineHasNoHelpWhereNoRunStatusRowSitsBelowIt() throws {
        for (label, runStatus) in [
            ("No provenance required", nil), ("Missing provenance", nil), ("Invalid record", nil),
            ("Complete record", ProvenanceRunStatusDisplay.stated(.failed)),
            ("Incomplete record", .notRecorded), ("Older record format", .stated(.completed)),
        ] as [(String, ProvenanceRunStatusDisplay?)] {
            let viewModel = ProvenanceInspectorViewModel()
            viewModel.summary.statusLabel = label
            viewModel.summary.runStatus = runStatus

            let status = try ProvenanceSection(viewModel: viewModel).inspect().find(ViewType.Label.self, where: {
                (try? $0.find(text: label)) != nil
            })

            if runStatus == nil {
                XCTAssertThrowsError(try status.help(), "\(label) shows no Run Status row, so it needs no help")
            } else {
                XCTAssertNoThrow(try status.help(), "\(label) sits above a Run Status row")
            }
        }
    }

    /// The same rule reaches VoiceOver, which reads the tooltip as the line's help. A line with no help reads none.
    func testTheStatusLineReadsNoHelpToVoiceOverWhereNoRunStatusRowSitsBelowIt() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.summary.statusLabel = "Missing provenance"
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: viewModel))
        defer { window.orderOut(nil) }
        func statusLine() -> NSObject? {
            AccessibilityTreeProbe.all(in: window).first {
                [AccessibilityTreeProbe.label($0), AccessibilityTreeProbe.value($0)].contains("Missing provenance")
            }
        }

        AccessibilityTreeProbe.waitUntil { statusLine() != nil }

        let line = try XCTUnwrap(statusLine(), AccessibilityTreeProbe.dump(window))
        let help: String? = (line as AnyObject).accessibilityHelp?() ?? nil
        XCTAssertTrue((help ?? "").isEmpty, "the line reads no help, it read \(help ?? "nil")")
    }

    /// VoiceOver reads the same sentence as the status line's help, after the line's words.
    func testTheStatusLineHelpReachesVoiceOver() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.summary.statusLabel = "Complete record"
        viewModel.summary.runStatus = .stated(.completed)
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: viewModel))
        defer { window.orderOut(nil) }
        func statusLine() -> NSObject? {
            AccessibilityTreeProbe.all(in: window).first {
                [AccessibilityTreeProbe.label($0), AccessibilityTreeProbe.value($0)].contains("Complete record")
            }
        }
        func helpOfStatusLine() -> String? {
            statusLine().flatMap { ($0 as AnyObject).accessibilityHelp?() ?? nil }
        }

        AccessibilityTreeProbe.waitUntil { helpOfStatusLine() != nil }

        XCTAssertNotNil(statusLine(), AccessibilityTreeProbe.dump(window))
        XCTAssertEqual(
            helpOfStatusLine(),
            "The status line says whether the record holds every fact LGE expects. Run Status says how the run ended."
        )
    }

    // MARK: - VoiceOver

    /// VoiceOver reads the section's accessibility tree in the order the view lists its rows. The Run Status
    /// row and its value come between Created and Exit Status, as they do in the Copy text.
    func testVoiceOverReadsTheRowBetweenCreatedAndExitStatus() throws {
        let viewModel = ProvenanceInspectorViewModel()
        viewModel.summary = ProvenanceRunSummary(
            workflowName: "lungfish fastq trim",
            createdAt: Date(timeIntervalSince1970: 1_791_609_019),
            statusLabel: "Complete record",
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
        return try edited(try Data(contentsOf: url), edit)
    }

    /// `original` after `edit` changed its decoded JSON.
    private func edited(_ original: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The source a native bundle loader hands the Inspector for a record it has already verified.
    private func verifiedSource(_ envelope: ProvenanceEnvelope, sidecar: URL) -> ProvenanceSource {
        ProvenanceSource(
            id: sidecar.path,
            name: "Analysis",
            item: ProvenanceInspectableItem(
                url: sidecar.deletingLastPathComponent(),
                sidebarType: .primerAnalysisBundle,
                contentMode: .genomics,
                displayName: "Analysis"
            ),
            verifiedRecord: VerifiedProvenanceRecord(envelope: envelope, sidecarURL: sidecar)
        )
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
        let finished = await waitUntil(budget: .lookup) { !model.isLoading }
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
