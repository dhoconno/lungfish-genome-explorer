// ProvenanceExportPinGatePresenterTests.swift - The sheet a script export shows before its save panel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P5b, plan decisions S7 and V6. The screen may be locked when
// this runs, so the tests drive the presenter's decision and its view model and
// write through the same call both GUI paths make after the save panel.

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class ProvenanceExportPinGatePresenterTests: XCTestCase {
    private var directory: URL!
    private let exporter = ProvenanceExporter(signingProvider: nil)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-gate-presenter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// A record whose first step ran minimap2 with no recorded version and whose second step ran
    /// samtools at the lock's version, written as its own sidecar.
    private func request(
        _ format: ProvenanceExportFormat = .shell,
        shape: ProvenanceEnvelopeReader.RecordShape = .envelope,
        minimap2Version: String = "unknown"
    ) throws -> ProvenanceExportRequest {
        let sidecar = directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = ProvenanceEnvelope(
            workflowName: "map",
            toolName: "minimap2",
            steps: [
                ProvenanceStep(
                    toolName: "minimap2",
                    toolVersion: "\(minimap2Version) (managed conda environment minimap2; executable minimap2)",
                    argv: ["minimap2", "-a", "ref.fa", "reads.fq"],
                    exitStatus: 0
                ),
                ProvenanceStep(
                    toolName: "samtools",
                    toolVersion: "1.24 (managed conda environment samtools; executable samtools)",
                    argv: ["samtools", "sort", "aln.sam"],
                    exitStatus: 0
                ),
            ],
            exitStatus: 0
        )
        try ProvenanceJSON.encoder.encode(envelope).write(to: sidecar, options: .atomic)
        return ProvenanceExportRequest(
            envelope: envelope, sourceSidecarURL: sidecar, selectedURL: sidecar, shape: shape, format: format
        )
    }

    /// What `decide` did: whether it showed a sheet, and what it handed the save panel.
    private func decide(
        _ request: ProvenanceExportRequest,
        answer response: ProvenanceExportPinSheetResponse
    ) -> (shown: [ProvenanceExportPinSheetModel], proceeded: [Bool]) {
        var shown: [ProvenanceExportPinSheetModel] = []
        var proceeded: [Bool] = []
        ProvenanceExportPinGatePresenter.decide(
            gate: request.pinGate(exporter: exporter),
            show: { model, answer in
                shown.append(model)
                answer(response)
            },
            proceed: { proceeded.append($0) }
        )
        return (shown, proceeded)
    }

    /// Counts the clicks of each alert button by replacing its action, so a key's answer shows without a sheet up.
    @MainActor
    private final class ClickCounter: NSObject {
        private(set) var counts: [Int]

        init(buttons: [NSButton]) {
            counts = Array(repeating: 0, count: buttons.count)
            super.init()
            for (index, button) in buttons.enumerated() {
                button.tag = index
                button.target = self
                button.action = #selector(clicked(_:))
            }
        }

        @objc private func clicked(_ sender: NSButton) {
            counts[sender.tag] += 1
        }
    }

    private func keyDown(
        _ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode
        ))
    }

    // MARK: - The sheet

    func testTheSheetNamesEachUnpinnedToolAndItsReasonWithCancelAsTheDefault() throws {
        let model = try XCTUnwrap(ProvenanceExportPinSheetModel(gate: try request().pinGate(exporter: exporter)))
        XCTAssertEqual(model.kind, .confirmUnpinned)
        // Cancel comes first, and testReturnAnswersCancelAndNoKeyExportsAnyway checks that Return answers it,
        // as the CLI refuses without the flag.
        XCTAssertEqual(model.buttonTitles, [ProvenanceExportPinSheetModel.cancelTitle, ProvenanceExportPinSheetModel.exportAnywayTitle])
        XCTAssertEqual(model.buttonTitles, ["Cancel", "Export Anyway…"])
        XCTAssertEqual(model.rows, [
            ProvenanceExportPinSheetModel.Row(
                tool: "minimap2", step: "Step 1", reason: "Its version was not recorded."
            ),
        ])
        XCTAssertEqual(model.messageText, "Export a shell script with unpinned tools?")
        XCTAssertEqual(
            model.informativeText,
            "LGE cannot promise that the shell script installs the tool versions that ran, so its results may differ.\n\n"
                + "• minimap2, step 1. Its version was not recorded.\n\n"
                + "Export Anyway… names each of these tools in the shell script and in its export record."
        )
    }

    func testReturnAnswersCancelAndNoKeyExportsAnyway() throws {
        // UX review fix 1. AppKit gives a button titled Cancel the Escape key even when it comes first, which
        // leaves the sheet with no default button, so the alert sets the keys itself.
        let model = try XCTUnwrap(ProvenanceExportPinSheetModel(gate: try request().pinGate(exporter: exporter)))
        let alert = ProvenanceExportPinGatePresenter.makeAlert(model)
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Export Anyway…"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[0].accessibilityIdentifier(), ProvenanceExportPinSheetModel.cancelIdentifier)
        XCTAssertEqual(alert.buttons[1].accessibilityIdentifier(), ProvenanceExportPinSheetModel.exportAnywayIdentifier)
    }

    func testEscapeAnswersCancelAsReturnDoesAndNoKeyExportsAnyway() throws {
        // Walk WO-6. Cancel holds Return, so no button held Escape and the sheet stayed up when a person pressed it.
        // The keys go through the alert's window, as the application sends them to a sheet.
        let model = try XCTUnwrap(ProvenanceExportPinSheetModel(gate: try request().pinGate(exporter: exporter)))
        let alert = ProvenanceExportPinGatePresenter.makeAlert(model)
        let clicks = ClickCounter(buttons: alert.buttons)

        XCTAssertTrue(alert.window.performKeyEquivalent(with: try keyDown("\r", keyCode: 36, in: alert.window)), "Return is handled")
        XCTAssertEqual(clicks.counts, [1, 0], "Return clicks Cancel")
        XCTAssertTrue(alert.window.performKeyEquivalent(with: try keyDown("\u{1b}", keyCode: 53, in: alert.window)), "Escape is handled")
        XCTAssertEqual(clicks.counts, [2, 0], "Escape clicks Cancel too")
        let commandPeriod = try keyDown(".", keyCode: 47, modifiers: .command, in: alert.window)
        XCTAssertTrue(alert.window.performKeyEquivalent(with: commandPeriod), "Command-period, which AppKit pairs with Escape, is handled")
        XCTAssertEqual(clicks.counts, [3, 0], "Command-period clicks Cancel too, and no key clicked Export Anyway…")
    }

    func testConfirmHandsTheOverrideToTheLeafAndCancelLeavesTheFolderUnchanged() throws {
        let request = try request()

        // The folder already holds an earlier export, whose script Cancel must leave byte for byte.
        let cancelled = directory.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelled, withIntermediateDirectories: true)
        let earlierScript = cancelled.appendingPathComponent("run.sh")
        let earlierBytes = Data("#!/usr/bin/env bash\necho \"an earlier export\"\n".utf8)
        try earlierBytes.write(to: earlierScript)
        let afterCancel = decide(request, answer: .cancel)
        XCTAssertEqual(afterCancel.shown.count, 1)
        XCTAssertEqual(afterCancel.proceeded, [], "Cancel never reaches the save panel, so no row begins")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cancelled.path), ["run.sh"])
        XCTAssertEqual(try Data(contentsOf: earlierScript), earlierBytes)

        let confirmed = directory.appendingPathComponent("confirmed", isDirectory: true)
        let afterConfirm = decide(request, answer: .exportAnyway)
        XCTAssertEqual(afterConfirm.proceeded, [true])
        // The leaf writes the export and its record, and ProvenanceExportCLIGUIParityReplayTests runs it. The
        // override reaches it as the command's flag (plan decision S7).
        let invocations = afterConfirm.proceeded.map { allowUnpinned in
            ProvenanceReportExport.invocation(
                inputURL: request.selectedURL, format: request.format, outputDirectory: confirmed, allowUnpinned: allowUnpinned
            )
        }
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertTrue(invocation.arguments().contains(ProvenanceExporter.allowUnpinnedFlag))
        XCTAssertFalse(FileManager.default.fileExists(atPath: confirmed.path), "the app itself writes no byte")
    }

    func testAnExportWithNothingUnpinnedGoesStraightToTheSavePanel() throws {
        let pinned = try request(minimap2Version: "2.31")
        XCTAssertNil(ProvenanceExportPinSheetModel(gate: pinned.pinGate(exporter: exporter)))
        let outcome = decide(pinned, answer: .cancel)
        XCTAssertEqual(outcome.shown, [])
        XCTAssertEqual(outcome.proceeded, [false])
    }

    func testMethodsAndJSONNeverShowTheSheet() throws {
        for format in [ProvenanceExportFormat.methods, .json] {
            for shape in ProvenanceEnvelopeReader.RecordShape.allCases {
                let outcome = decide(try request(format, shape: shape), answer: .cancel)
                XCTAssertEqual(outcome.shown, [], "\(format.cliToken) \(shape.rawValue)")
                XCTAssertEqual(outcome.proceeded, [false], "\(format.cliToken) \(shape.rawValue)")
            }
        }
    }

    func testTheOlderRecordFormatOffersOnlyOKAndNeverReachesTheSavePanel() throws {
        for shape in [ProvenanceEnvelopeReader.RecordShape.workflowRun, .primitive] {
            for answer in [ProvenanceExportPinSheetResponse.exportAnyway, .cancel] {
                let outcome = decide(try request(.nextflow, shape: shape, minimap2Version: "2.31"), answer: answer)
                XCTAssertEqual(outcome.shown.map(\.kind), [.refuseOlderRecordFormat], shape.rawValue)
                XCTAssertEqual(outcome.shown.first?.buttonTitles, ["OK"], shape.rawValue)
                XCTAssertEqual(outcome.proceeded, [], shape.rawValue)
            }
        }
        let model = try XCTUnwrap(ProvenanceExportPinSheetModel(gate: try request(.shell, shape: .primitive).pinGate(exporter: exporter)))
        XCTAssertEqual(model.messageText, "This record cannot be exported as a shell script.")
        XCTAssertEqual(
            model.informativeText,
            "It is in the Older record format. LGE fills in facts such records leave out, so a script made from one "
                + "might not match what ran. Export it as a Methods Section or as Full Provenance (JSON) instead."
        )
    }

    func testTheRecordedCommandCarriesTheFlagOnlyAfterExportAnyway() throws {
        let request = try request()
        let output = URL(fileURLWithPath: "/tmp/project/reads-provenance-shell")
        let base = [
            CLICommandIdentity.executableName, "provenance", "export", request.selectedURL.standardizedFileURL.path,
            "--export-format", "shell", "--output", output.path,
        ]
        let plain = ProvenanceReportExport.invocation(
            inputURL: request.selectedURL, format: .shell, outputDirectory: output, allowUnpinned: false
        )
        XCTAssertEqual(plain.canonicalArgv(), base)
        let override = ProvenanceReportExport.invocation(
            inputURL: request.selectedURL, format: .shell, outputDirectory: output, allowUnpinned: true
        )
        XCTAssertEqual(
            override.canonicalArgv(),
            Array(base.prefix(6)) + [ProvenanceExporter.allowUnpinnedFlag, "--output", output.path]
        )
    }

    // MARK: - The shape

    func testTheShapeComesFromTheFinderSoATypedMappingRecordIsNotTheOlderRecordFormat() throws {
        let envelopeRequest = try request()
        XCTAssertEqual(
            ProvenanceExportRequest.recordShape(selectedURL: directory, sidecarURL: envelopeRequest.sourceSidecarURL),
            .envelope
        )

        let legacy = WorkflowRun(
            name: "legacy", startTime: Date(timeIntervalSince1970: 100), endTime: Date(timeIntervalSince1970: 108),
            status: .completed, steps: []
        )
        let bare = directory.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let bareSidecar = bare.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try ProvenanceJSON.encoder.encode(legacy).write(to: bareSidecar, options: .atomic)
        XCTAssertEqual(ProvenanceExportRequest.recordShape(selectedURL: bare, sidecarURL: bareSidecar), .workflowRun)

        let restored = directory.appendingPathComponent("golden", isDirectory: true)
        let mapping = try XCTUnwrap(Self.restoredGoldenRecords(in: restored)["mapping/mapping-provenance.json"])
        let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceReading(for: mapping))
        XCTAssertEqual(found.reading.shape, .typedRecord)
        XCTAssertEqual(ProvenanceExportRequest.recordShape(selectedURL: mapping, sidecarURL: found.sidecarURL), .typedRecord)
    }

    // MARK: - Golden records

    /// The restored golden records the gate refuses for a shell export, as
    /// `ProvenanceExportPinGateTests.goldenRefusals` and the CLI's test list them.
    static let goldenRefusals: [String] = [
        "genotype/bundle/SIMULATED-MHC-haplotypes.retained_demux_provenance.json | olderRecordFormat",
        "genotype/bundle/SIMULATED-MHC-haplotypes.xlsx.export/request.json | olderRecordFormat",
        "genotype/bundle/retained-demux-genotyping-provenance.json | olderRecordFormat | Step 1 minimap2 | Step 2 samtools sort | Step 3 minimap2 | Step 4 samtools sort | Step 5 samtools merge | Step 6 samtools index | Step 7 pysam retained-read demux filter | Step 10 openpyxl ONT genotype workbook report",
        "genotype/exports/pivot.xlsx.export/request.json | olderRecordFormat",
        "genotype/exports/workbook.xlsx.export/request.json | olderRecordFormat",
    ]

    func testTheAppAsksAboutTheSameRestoredGoldenRecordsTheCLIRefuses() throws {
        let restored = try Self.restoredGoldenRecords(in: directory.appendingPathComponent("golden", isDirectory: true))
        XCTAssertEqual(restored.count, 44)
        var refused: [String] = []
        for (path, url) in restored.sorted(by: { $0.key < $1.key }) {
            let reading = try XCTUnwrap(Self.reading(of: url), path)
            let request = ProvenanceExportRequest(
                envelope: reading.reading.envelope,
                sourceSidecarURL: reading.sidecarURL,
                selectedURL: url,
                shape: ProvenanceExportRequest.recordShape(selectedURL: url, sidecarURL: reading.sidecarURL),
                format: .shell
            )
            let gate = request.pinGate(exporter: exporter)
            guard let model = ProvenanceExportPinSheetModel(gate: gate) else { continue }
            let verdict = model.kind == .refuseOlderRecordFormat ? "olderRecordFormat" : "needsOverride"
            refused.append(([path, verdict] + gate.unpinnedSteps.map { "\($0.stepLabel) \($0.toolName)" }).joined(separator: " | "))
        }
        XCTAssertEqual(refused, Self.goldenRefusals)
    }

    /// The record the app reads for a sidecar the Inspector resolved: the file itself, except a typed
    /// mapping record, which only the finder converts.
    private static func reading(of url: URL) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
        if url.lastPathComponent == MappingProvenance.filename, let found = ProvenanceRecorder.findProvenanceReading(for: url) {
            return found
        }
        return ((try? ProvenanceEnvelopeReader.read(fromSidecar: url)) ?? nil).map { (url, $0) }
    }

    /// The golden records with steps, copied under `directory` with the normalizer's placeholders
    /// restored, so each reads in the shape it was written in. The same restoration as
    /// `GoldenProvenanceRecords.restoredCopies(in:)` in the Workflow tests.
    static func restoredGoldenRecords(in directory: URL) throws -> [String: URL] {
        let root = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/golden", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let restorations = [
            (#""<(TIMESTAMP|GENERATED_AT)>""#, #""2026-10-10T12:00:00Z""#),
            (#""<(DURATION|PID|EPOCH)>""#, "1"),
            (#""<SIZE-[A-Z0-9]+>""#, "1"),
            (#""<UUID-([0-9])>""#, #""00000000-0000-0000-0000-00000000000$1""#),
            (#""<UUID-([0-9]{2})>""#, #""00000000-0000-0000-0000-0000000000$1""#),
        ]
        var result: [String: URL] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard !relative.hasPrefix("cli-help/"), !relative.hasPrefix("tools/"),
                  let envelope = try? ProvenanceEnvelopeReader.decode(Data(contentsOf: url)),
                  !envelope.steps.isEmpty else { continue }
            var text = try String(contentsOf: url, encoding: .utf8)
            for (pattern, template) in restorations {
                text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            let copy = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: copy)
            result[relative] = copy
        }
        return result
    }
}
