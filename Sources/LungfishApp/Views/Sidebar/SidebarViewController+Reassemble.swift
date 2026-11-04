// SidebarViewController+Reassemble.swift - Reassemble on an assembly bundle in the sidebar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os.log
import LungfishKit

extension SidebarViewController {

    /// What Reassemble opens the assembly wizard with, or why it refuses (R3).
    enum ReassemblePlan: Equatable {
        /// `inputFiles` are the inputs the user chose for the original run, and nothing else.
        case open(inputFiles: [URL], outputDirectory: URL, initialTool: AssemblyTool)
        case refuse(reason: String)
    }

    @objc func reassembleSelectedSidebarBundle(_ sender: Any?) {
        Task { @MainActor [self] in
            await reassembleSelectedSidebarBundle(presentWizard: { window, inputFiles, outputDirectory, initialTool in
                AssemblySheetPresenter.present(
                    from: window,
                    inputFiles: inputFiles,
                    outputDirectory: outputDirectory,
                    initialTool: initialTool,
                    routeContext: OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope),
                    onCancel: nil
                )
            })
        }
    }

    /// Reassemble on the selected assembly bundle, with `presentWizard`
    /// opening the assembly wizard (a test passes a recorder). The plan checks
    /// the bytes of the reads off the main actor, so this returns once the
    /// wizard is shown or the refusal is on screen.
    func reassembleSelectedSidebarBundle(presentWizard: (NSWindow, [URL], URL, AssemblyTool) -> Void) async {
        guard let item = selectedItems().first, item.type == .referenceBundle, let bundleURL = item.url else { return }
        switch await reassemblePlan(forBundleAt: bundleURL, title: item.title) {
        case .open(let inputFiles, let outputDirectory, let initialTool):
            guard let window = view.window else { return }
            presentWizard(window, inputFiles, outputDirectory, initialTool)
        case .refuse(let reason):
            sidebarLogger.error("contextMenuReassemble: Cannot reassemble \(bundleURL.lastPathComponent): \(reason)")
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "Cannot Reassemble"
            alert.informativeText = reason
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) }
        }
    }

    /// Reassemble opens the wizard on the inputs the user chose for the
    /// original run (`AssemblyProvenance.reassemblyInputPaths`), never on the
    /// lineage the record also keeps. It refuses when the record cannot be
    /// read, or when an input is gone, since assembling the rest would not
    /// reassemble the original reads.
    func reassemblePlan(forBundleAt bundleURL: URL, title: String) async -> ReassemblePlan {
        guard let provenance = try? AssemblyProvenance.load(from: bundleURL.appendingPathComponent("assembly")) else {
            return .refuse(reason: "\(title)'s assembly provenance file is missing or corrupted, so the original assembly inputs and tool settings could not be recovered.")
        }
        let inputs = await provenance.reassemblyInputFiles(projectURL: projectURL)
        guard inputs.missing.isEmpty else {
            let names = inputs.missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            return .refuse(reason: "\(title) was assembled from inputs that can no longer be found (\(names)). Reassemble uses exactly the reads of the original assembly, so restore them or start a new assembly.")
        }
        let tool = AssemblyTool(rawValue: provenance.assembler.lowercased().replacingOccurrences(of: " ", with: ""))
        return .open(inputFiles: inputs.found, outputDirectory: bundleURL.deletingLastPathComponent(), initialTool: tool ?? .spades)
    }
}
