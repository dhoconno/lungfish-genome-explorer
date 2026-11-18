// RNASeqAdoptSheet.swift - The adopt card for the RNA-seq counts a Linux run returned (Phase 5.4 lane EX-APP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The card asks for the returned plan folder, or the batch folder, in an open panel and then opens this sheet for the name,
// the storage root and the check. The sheet runs `lungfish-cli import rnaseq <folder> --adopt` through the runner every
// import uses. Its Check button adds `--dry-run`, which runs every check and reads and writes nothing. A refused adopt
// writes nothing, and its words reach the Operations row and this sheet as the command wrote them.

import AppKit
import Foundation
import Observation
import SwiftUI

/// What the adopt sheet hands its launcher. `arguments` is the argv after `lungfish-cli` that runs.
struct RNASeqAdoptRequest: Sendable, Equatable {
    let arguments: [String]
    let name: String
    let folder: URL
    let projectURL: URL
    let dryRun: Bool
}

/// How an adopt ended, in the words the sheet shows.
enum RNASeqAdoptOutcome: Sendable, Equatable {
    /// The command made this `.lungfishrnaseq` folder.
    case adopted(URL)
    /// A `--dry-run` passed every check and wrote nothing.
    case checked
    /// The command refused or failed, in its own words.
    case refused(String)
    /// The run was cancelled, and the command removed its stage.
    case cancelled
}

@MainActor
@Observable
final class RNASeqAdoptSheetModel {
    enum Phase: Equatable {
        case editing
        case running
    }

    let folder: URL
    let projectURL: URL
    var name: String
    var storageRoot: URL?

    private(set) var phase: Phase = .editing
    /// The command's words after a refusal.
    private(set) var failure: String?
    /// A line that is not a refusal: a passed check or a cancel.
    private(set) var note: String?
    private(set) var operationID: UUID?

    @ObservationIgnored
    var start: (@MainActor (RNASeqAdoptRequest, @escaping @MainActor (RNASeqAdoptOutcome) -> Void) -> UUID?)?
    @ObservationIgnored
    var cancelRun: (@MainActor (UUID) -> Void)?
    @ObservationIgnored
    var onAdopted: (@MainActor (URL) -> Void)?
    @ObservationIgnored
    var onDismiss: (@MainActor () -> Void)?

    init(folder: URL, projectURL: URL) {
        self.folder = folder
        self.projectURL = projectURL
        self.name = folder.lastPathComponent
    }

    /// The argv after `lungfish-cli` of the adopt, `import rnaseq <folder> --adopt`, ending in `--format json`. `dryRun`
    /// adds `--dry-run` and `storageRoot` adds `--storage-root`, the two options the adopt takes.
    nonisolated static func arguments(folder: URL, projectURL: URL, name: String, storageRoot: URL?, dryRun: Bool) -> [String] {
        var arguments = [
            "import", "rnaseq", folder.standardizedFileURL.path, "--adopt",
            "--project", projectURL.standardizedFileURL.path, "--name", name,
        ]
        if let storageRoot { arguments += ["--storage-root", storageRoot.standardizedFileURL.path] }
        if dryRun { arguments.append("--dry-run") }
        return arguments + ["--format", "json"]
    }

    /// Why Check and Adopt are not available yet, in words, or nil when the sheet's values make a command.
    var missingChoice: String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give the result a name." : nil
    }

    var canRun: Bool { phase == .editing && missingChoice == nil }

    func request(dryRun: Bool) -> RNASeqAdoptRequest? {
        guard missingChoice == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return RNASeqAdoptRequest(
            arguments: Self.arguments(folder: folder, projectURL: projectURL, name: trimmed, storageRoot: storageRoot, dryRun: dryRun),
            name: trimmed, folder: folder, projectURL: projectURL, dryRun: dryRun
        )
    }

    func checkClicked() { run(dryRun: true) }

    func adoptClicked() { run(dryRun: false) }

    private func run(dryRun: Bool) {
        guard canRun, let request = request(dryRun: dryRun), let start else { return }
        failure = nil
        note = nil
        phase = .running
        operationID = start(request) { [weak self] outcome in self?.finish(outcome) }
        if operationID == nil {
            phase = .editing
            failure = "The Operations panel shows why the adopt could not start."
        }
    }

    func cancelClicked() {
        if phase == .running, let operationID {
            cancelRun?(operationID)
        } else {
            onDismiss?()
        }
    }

    func finish(_ outcome: RNASeqAdoptOutcome) {
        operationID = nil
        phase = .editing
        switch outcome {
        case .adopted(let url):
            failure = nil
            note = nil
            onAdopted?(url)
            onDismiss?()
        case .checked:
            failure = nil
            note = "Checked. \(folder.lastPathComponent) passed every check, and nothing was imported."
        case .refused(let words):
            failure = words
            note = nil
        case .cancelled:
            failure = nil
            note = "The adopt was cancelled. Nothing was imported."
        }
    }
}

struct RNASeqAdoptSheet: View {
    @Bindable var model: RNASeqAdoptSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adopt a Linux Run of RNA-seq Counts").font(.headline)
            Text("Folder: \(model.folder.lastPathComponent)")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("rnaseq-adopt-folder")
            Text(RNASeqPlanWords.adoptIntro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Name:").frame(width: RNASeqImportLayout.labelWidth, alignment: .trailing)
                    TextField(RNASeqPlanWords.adoptNameHelp, text: $model.name).accessibilityIdentifier("rnaseq-adopt-name")
                }
                RNASeqImportChooserRow(
                    title: "Storage root:", help: RNASeqPlanWords.adoptStorageRootHelp, value: model.storageRoot,
                    identifier: "rnaseq-adopt-storage-root",
                    choose: { RNASeqImportPanels.choose(message: "Choose the storage root", directories: true) { if let url = $0 { model.storageRoot = url } } },
                    clear: { model.storageRoot = nil }
                )
            }
            .disabled(model.phase == .running)
            footer
        }
        .padding(20)
        .frame(width: 580)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.failure {
                Text(failure)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("rnaseq-adopt-failure")
                Text("Nothing was written. Change what the message names, then choose Check or Adopt again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = model.note {
                Text(note).foregroundStyle(.secondary).accessibilityIdentifier("rnaseq-adopt-note")
            }
            if model.phase == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working. The Operations panel shows each step.").foregroundStyle(.secondary)
                }
            } else if let missing = model.missingChoice {
                Text(missing).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(model.phase == .running ? "Cancel Adopt" : "Cancel") { model.cancelClicked() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("rnaseq-adopt-cancel")
                Button("Check") { model.checkClicked() }
                    .disabled(!model.canRun)
                    .accessibilityIdentifier("rnaseq-adopt-check")
                Button("Adopt") { model.adoptClicked() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
                    .accessibilityIdentifier("rnaseq-adopt-run")
            }
        }
    }
}
