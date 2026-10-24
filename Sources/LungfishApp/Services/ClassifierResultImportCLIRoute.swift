// ClassifierResultImportCLIRoute.swift - The Import Center's classifier result imports on lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The Import Center's Kraken2, EsViritu, TaxTriage, NAO-MGS and NVD result imports run `lungfish-cli import <kind>` on
/// `CLIBundleBuildRunner` (Phase 2.12 lanes 12.04 and 12.05, A63-M2), which replaced the app's in-process import
/// helper for every kind. The helper no longer exists. `ProvenanceExportPlan.retiredHelperFlags` is the one place
/// that still names its flag, so that old records stay readable.
///
/// The command writes the result folder and its record, and the app writes nothing after it exits.
/// `OperationCenterCLIBridge` shows the command's progress on the row, and the row completes with the
/// command's `complete` words, the words the helper printed. A cancel reaches the command as SIGTERM with
/// `operationGrace` before SIGKILL. The command removes the folder it began, records the run as cancelled and
/// exits 125, and the runner acknowledges the cancel on the row, which shows no alert.
///
/// ``arguments(kind:inputURL:outputDirectory:preferredName:fetchReferences:)`` is the one builder of the argv. The
/// runner runs it and ``rowCommand(kind:inputURL:outputDirectory:preferredName:fetchReferences:)`` shows it whole.
enum ClassifierResultImportCLIRoute {
    /// The NAO-MGS options the Import Center passes to the command. `fetchReferences` reaches the leaf as
    /// `--no-fetch-references` when it is false, since the leaf's option is a flag that defaults to fetching.
    struct NaoMgsOptions: Sendable {
        let fetchReferences: Bool

        init(fetchReferences: Bool = true) {
            self.fetchReferences = fetchReferences
        }
    }

    /// How a run ended. A failure shows its alert when `alert` is set, the row having failed by it.
    enum Outcome: Equatable {
        case completed(URL, detail: String)
        case cancelled
        case failed(String, alert: Bool)
    }

    /// The argv after `lungfish-cli`. The row shows this argv whole. The leaf records it without `--format json`, as
    /// `import bam` does. The preferred name reaches NAO-MGS as `--sample-name` and every other kind as `--name`.
    static func arguments(
        kind: MetagenomicsImportKind,
        inputURL: URL,
        outputDirectory: URL,
        preferredName: String?,
        fetchReferences: Bool = true
    ) -> [String] {
        let trimmed = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed?.isEmpty == true ? nil : trimmed
        var argv = ["import", kind.importCommandToken, inputURL.path, "--output-dir", outputDirectory.path]
        if kind == .naomgs {
            argv += name.map { ["--sample-name", $0] } ?? []
            if !fetchReferences { argv.append("--no-fetch-references") }
        } else {
            argv += name.map { ["--name", $0] } ?? []
        }
        return argv + ["--format", "json"]
    }

    /// The row's command, the text Copy CLI Command gives. It is `arguments` whole, `--format json` included.
    static func rowCommand(
        kind: MetagenomicsImportKind,
        inputURL: URL,
        outputDirectory: URL,
        preferredName: String?,
        fetchReferences: Bool = true
    ) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "import \(kind.importCommandToken)",
            args: Array(arguments(
                kind: kind, inputURL: inputURL, outputDirectory: outputDirectory,
                preferredName: preferredName, fetchReferences: fetchReferences
            ).dropFirst(2))
        )
    }

    /// The folder a classifier import is told to write its result folder into (`--output-dir`) for `kind`, in the
    /// project `projectURL`. The Import Center and the Tools menu both ask here, so the two menus cannot disagree.
    /// A NAO-MGS result goes to Analyses and every other kind to Imports.
    static func destination(for kind: MetagenomicsImportKind, projectURL: URL) throws -> URL {
        if kind == .naomgs { return try AnalysesFolder.url(for: projectURL) }
        let imports = projectURL.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        return imports
    }

    /// Runs `arguments` for the row `operationID` and ends the row as the helper route did.
    @MainActor
    static func run(
        _ runner: CLIBundleBuildRunner,
        arguments: [String],
        operationID: UUID,
        operationTitle: String
    ) async -> Outcome {
        do {
            let result = try await runner.run(arguments: arguments, operationID: operationID)
            guard let path = result.outputs.first, !path.isEmpty else {
                let detail = "lungfish-cli finished without reporting an imported result."
                return .failed(detail, alert: OperationCenter.shared.fail(id: operationID, detail: detail))
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let detail = result.message ?? "Import complete"
            if OperationCenter.shared.complete(id: operationID, detail: detail, bundleURLs: [folder]) {
                OperationCenter.shared.log(id: operationID, level: .info, message: "Imported result at \(folder.lastPathComponent)")
            }
            return .completed(folder, detail: detail)
        } catch is CancellationError {
            OperationCenter.shared.log(id: operationID, level: .info, message: "\(operationTitle) cancelled")
            return .cancelled
        } catch {
            let detail = error.localizedDescription
            return .failed(detail, alert: OperationCenter.shared.fail(id: operationID, detail: detail))
        }
    }
}
