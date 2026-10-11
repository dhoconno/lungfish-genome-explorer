// ProvenanceExportPinGatePresenter.swift - The sheet a script export shows before its save panel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Plan decisions S7 and V6. File > Export > Provenance and the Inspector's export
// menu both ask `ProvenanceExporter.pinGate` before they open the save panel. A
// record in the Older record format is never written as a script. A script with
// steps whose tool versions LGE cannot pin shows one sheet that names each tool
// and its reason, with Cancel as the default to match the CLI's refusal, and
// Export Anyway… goes on to the save panel. Other formats never see the sheet.

import AppKit
import LungfishCore
import LungfishWorkflow

/// One provenance export the app is about to write, as both GUI paths describe it.
struct ProvenanceExportRequest {
    let envelope: ProvenanceEnvelope
    let sourceSidecarURL: URL?
    /// The file or bundle the export describes, which the recorded command names.
    let selectedURL: URL
    /// The shape the reader decoded the record in.
    let shape: ProvenanceEnvelopeReader.RecordShape
    let format: ProvenanceExportFormat

    /// What the export must check before the save panel opens.
    func pinGate(exporter: ProvenanceExporter) -> ProvenanceExportPinGate {
        exporter.pinGate(
            for: envelope, shape: shape, format: format, sourceSidecarURL: sourceSidecarURL, sourceRootURL: selectedURL
        )
    }

    /// The command the export record keeps, in the CLI's own spelling, with `--allow-unpinned` after Export Anyway….
    func exportArgv(outputDirectory: URL, allowUnpinned: Bool) -> [String] {
        AppProvenanceExportCommandBuilder.argv(format: format, sourceURL: selectedURL, outputDirectory: outputDirectory)
            + (allowUnpinned ? [ProvenanceExporter.allowUnpinnedFlag] : [])
    }

    /// Writes the export into the folder the save panel chose, as both GUI paths do.
    func write(to outputDirectory: URL, allowUnpinned: Bool, exporter: ProvenanceExporter) throws -> ProvenanceExportBundle {
        try exporter.exportBundle(
            envelope,
            format: format,
            to: outputDirectory,
            sourceSidecarURL: sourceSidecarURL,
            sourceRootURL: selectedURL,
            exportArgv: exportArgv(outputDirectory: outputDirectory, allowUnpinned: allowUnpinned),
            allowUnpinned: allowUnpinned
        )
    }

    /// The shape of the record the export reads, from the finder's walk for `selectedURL` when it
    /// finds that record, and otherwise from the sidecar read alone.
    ///
    /// The finder reads a typed record such as `mapping-provenance.json` as `.typedRecord`, which is
    /// never the Older record format, so it is asked first.
    static func recordShape(selectedURL: URL, sidecarURL: URL?) -> ProvenanceEnvelopeReader.RecordShape {
        if let found = ProvenanceRecorder.findProvenanceReading(for: selectedURL),
           sidecarURL.map({ $0.standardizedFileURL == found.sidecarURL.standardizedFileURL }) ?? true {
            return found.reading.shape
        }
        if let sidecarURL, let reading = (try? ProvenanceEnvelopeReader.read(fromSidecar: sidecarURL)) ?? nil {
            return reading.shape
        }
        return .envelope
    }
}

/// What the app shows before the save panel when the pin gate refuses a script export.
struct ProvenanceExportPinSheetModel: Equatable {
    enum Kind: Equatable {
        /// Steps whose tool versions LGE cannot pin. Cancel is the default, and Export Anyway… goes on.
        case confirmUnpinned
        /// A record in the Older record format, which is never written as a script. OK is the only button.
        case refuseOlderRecordFormat
    }

    /// One unpinned tool as the sheet lists it.
    struct Row: Equatable {
        let tool: String
        /// `Step 3`, as the script numbers it.
        let step: String
        let reason: String
    }

    static let cancelTitle = "Cancel"
    static let exportAnywayTitle = "Export Anyway…"
    static let okTitle = "OK"
    static let cancelIdentifier = "provenance-export-pin-cancel"
    static let exportAnywayIdentifier = "provenance-export-pin-export-anyway"

    let kind: Kind
    let messageText: String
    let informativeText: String
    let rows: [Row]
    /// The button titles in the order the alert adds them. The first is the default.
    let buttonTitles: [String]

    /// The sheet the gate calls for, or nil when the export goes straight to the save panel.
    init?(gate: ProvenanceExportPinGate) {
        let name = gate.format.sentenceName
        if gate.refusesOlderRecordFormat {
            kind = .refuseOlderRecordFormat
            messageText = "This record cannot be exported as a \(name)"
            let subject = gate.olderRecordFormatUpstream.map { "It builds on \($0.lastPathComponent), which is" } ?? "It is"
            informativeText = "\(subject) in the Older record format, which LGE never exports as a script. "
                + "Export it as a Methods Section or as Full Provenance (JSON) instead."
            rows = []
            buttonTitles = [Self.okTitle]
            return
        }
        guard gate.requiresOverride else { return nil }
        kind = .confirmUnpinned
        rows = gate.unpinnedSteps.map { Row(tool: $0.toolName, step: $0.stepLabel, reason: $0.reason.sentence) }
        messageText = "Export a \(name) with unpinned tools?"
        informativeText = "LGE cannot pin the version of these tools, so the \(name) may not recreate the environments that ran.\n\n"
            + rows.map { "• \($0.tool), \($0.step.lowercased()). \($0.reason)" }.joined(separator: "\n")
            + "\n\nExport Anyway… names each of these tools in the \(name) and in its export record."
        buttonTitles = [Self.cancelTitle, Self.exportAnywayTitle]
    }
}

/// The answer the sheet gave.
enum ProvenanceExportPinSheetResponse: Equatable {
    case exportAnyway
    case cancel
}

/// The one presenter both GUI paths call before their save panel (plan decision S7).
@MainActor
enum ProvenanceExportPinGatePresenter {
    /// Asks the gate and shows its sheet when it calls for one. `proceed` runs with whether the
    /// person chose Export Anyway…, and never runs after Cancel or the Older record format refusal.
    static func present(
        _ request: ProvenanceExportRequest,
        window: NSWindow,
        exporter: ProvenanceExporter = ProvenanceExporter(),
        proceed: @escaping (_ allowUnpinned: Bool) -> Void
    ) {
        decide(gate: request.pinGate(exporter: exporter), show: { model, answer in
            showSheet(model, window: window, answer: answer)
        }, proceed: proceed)
    }

    /// The decision both paths share, with the sheet passed in so a test answers it.
    static func decide(
        gate: ProvenanceExportPinGate,
        show: (ProvenanceExportPinSheetModel, @escaping (ProvenanceExportPinSheetResponse) -> Void) -> Void,
        proceed: @escaping (_ allowUnpinned: Bool) -> Void
    ) {
        guard let model = ProvenanceExportPinSheetModel(gate: gate) else {
            proceed(false)
            return
        }
        show(model) { response in
            guard model.kind == .confirmUnpinned, response == .exportAnyway else { return }
            proceed(true)
        }
    }

    private static func showSheet(
        _ model: ProvenanceExportPinSheetModel,
        window: NSWindow,
        answer: @escaping (ProvenanceExportPinSheetResponse) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = model.messageText
        alert.informativeText = model.informativeText
        alert.alertStyle = model.kind == .confirmUnpinned ? .warning : .informational
        for title in model.buttonTitles {
            alert.addButton(withTitle: title)
        }
        if model.kind == .confirmUnpinned, alert.buttons.count == 2 {
            alert.buttons[0].setAccessibilityIdentifier(ProvenanceExportPinSheetModel.cancelIdentifier)
            alert.buttons[1].setAccessibilityIdentifier(ProvenanceExportPinSheetModel.exportAnywayIdentifier)
        }
        alert.beginSheetModal(for: window) { response in
            answer(model.kind == .confirmUnpinned && response == .alertSecondButtonReturn ? .exportAnyway : .cancel)
        }
    }
}
