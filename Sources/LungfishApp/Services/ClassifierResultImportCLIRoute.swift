// ClassifierResultImportCLIRoute.swift - The Import Center's Kraken2, EsViritu and TaxTriage result imports on lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The Import Center's Kraken2, EsViritu and TaxTriage result imports run `lungfish-cli import <kind>` on
/// `CLIBundleBuildRunner` (Phase 2.12 lane 12.04, A63-M2a), which replaced the app's
/// `--metagenomics-import-helper` mode for these kinds. NAO-MGS and NVD still run in the helper.
///
/// The command writes the result folder and its record, and the app writes nothing after it exits.
/// `OperationCenterCLIBridge` shows the command's progress on the row, and the row completes with the
/// command's `complete` words, the words the helper printed. A cancel reaches the command as SIGTERM with
/// `operationGrace` before SIGKILL. The command removes the folder it began, records the run as cancelled and
/// exits 125, and the runner acknowledges the cancel on the row, which shows no alert.
enum ClassifierResultImportCLIRoute {
    /// How a run ended. A failure shows its alert when `alert` is set, the row having failed by it.
    enum Outcome: Equatable {
        case completed(URL, detail: String)
        case cancelled
        case failed(String, alert: Bool)
    }

    /// Whether the Import Center runs `kind` on `lungfish-cli`.
    static func runs(_ kind: MetagenomicsImportKind) -> Bool {
        kind == .kraken2 || kind == .esviritu || kind == .taxtriage
    }

    /// The argv after `lungfish-cli`. Before `--format json` it is the command the leaf records and the row shows.
    static func arguments(kind: MetagenomicsImportKind, inputURL: URL, outputDirectory: URL, preferredName: String?) -> [String] {
        let trimmed = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed?.isEmpty == true ? nil : trimmed
        return ["import", kind.importCommandToken, inputURL.path, "--output-dir", outputDirectory.path]
            + (name.map { ["--name", $0] } ?? [])
            + ["--format", "json"]
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
