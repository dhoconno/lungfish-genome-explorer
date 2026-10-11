// CLIEventLegacyNames.swift — The dated table that reads the private event names of older lungfish-cli builds as version 2 events.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let legacyNamesLogger = Logger(subsystem: LogSubsystem.workflow, category: "CLIEventLegacyNames")

/// Reads the private event names that `lungfish-cli` builds older than the version 2
/// envelope print, as the version 2 events a current build prints for the same run.
///
/// Dated 2026-10-11, decision V13 of Phase 2.6. Until then `import msa`, `import tree`,
/// `import geneious` and `import application-export` wrote events under names of their
/// own, the shapes S2 and S3 of the Phase 2.6 inventory, and each app runner parsed them
/// by hand. Both runners now read their stream through `CLISubprocessTransport`, so an
/// older CLI, found through `LUNGFISH_CLI_PATH`, a stale build folder or `PATH`, would
/// end in a missing completion if nothing read those names. This table does.
///
/// `CLIEventLine` consults it only when a line has no `schemaVersion` and its event name
/// is not one of the names it knows. A line whose name is not in the table stays an
/// ignored line and never throws. A field that is missing or has the wrong type takes
/// the default that the app's own parsers used, so an older CLI gives the same operation
/// log, the same label and the same imported bundle as it did before.
///
/// What each old name becomes.
///
///   Start      a `start` whose message names the kind, `Started <kind> import via lungfish-cli`
///   Progress   a `progress` with the same fraction and message
///   Warning    a `log` at level `warning`
///   Complete   a `complete` that names the bundle or collection in `outputs` and holds
///              one typed artifact for it. The `warningCount` key is not carried, because
///              the old CLI wrote one warning line for each warning it counted and the
///              runner counts those lines.
///   Failed     a `failed` with the error as its message
///
/// S8 and S9, the progress lines of `fastq ont-fluidigm-samples` and
/// `fastq ont-pacbio-barcode-demux`, need no row. They print `progress` with an extra
/// `operation` key, which is a name version 1 already had and a key the decoder ignores.
/// `CLIEventLegacyNamesTests` pins that.
///
/// Delete this file as a unit when the `.legacy` rows expire, together with
/// `CLIEventLegacyNamesTests`, `Tests/Fixtures/cli-events/legacy` and the one call in
/// `CLIEventLine.init(from:)`.
enum CLIEventLegacyNames {
    /// The day this table was written. A build that prints a name from it is older than this day.
    static let dated = "2026-10-11"

    /// An old line read as a version 2 event.
    struct Translation: Equatable {
        let event: CLIEvent
        /// The typed artifacts of a `complete` line. Empty for every other event.
        let artifacts: [CLIEventArtifact]
    }

    /// The old names this table reads, sorted.
    static var names: [String] { rows.keys.sorted() }

    /// Reads the line that `decoder` holds under the old event `name`. Returns nil when the
    /// table does not know the name, and the caller then ignores the line. Never throws.
    static func translate(name: String, from decoder: Decoder) -> Translation? {
        guard let row = rows[name], let fields = try? decoder.container(keyedBy: Field.self) else {
            return nil
        }
        legacyNamesLogger.debug("Read a line of an older CLI. Event name \(name, privacy: .public).")

        func text(_ key: Field) -> String? {
            try? fields.decodeIfPresent(String.self, forKey: key)
        }

        switch row.becomes {
        case .start:
            let kind = text(.kind) ?? ""
            return Translation(event: .start(message: "Started \(kind) import via lungfish-cli"), artifacts: [])
        case .progress:
            let fraction = (try? fields.decodeIfPresent(Double.self, forKey: .progress)) ?? 0
            return Translation(
                event: .progress(
                    fraction: max(0, min(1, fraction)),
                    message: text(.message) ?? row.shape.progressMessage
                ),
                artifacts: []
            )
        case .warning:
            return Translation(event: .log(level: .warning, message: text(.message) ?? "Import warning"), artifacts: [])
        case .complete:
            let path = text(row.shape.outputKey) ?? ""
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // A completion that names nothing, which the transport fails as a missing completion.
                return Translation(event: .complete(outputs: [], message: nil), artifacts: [])
            }
            return Translation(
                event: .complete(outputs: [path], message: nil),
                artifacts: [row.shape.artifact(path: path)]
            )
        case .failed:
            return Translation(event: .failed(message: text(.error) ?? row.shape.failureMessage, detail: nil), artifacts: [])
        }
    }

    // MARK: The table

    /// The keys the old encoders wrote besides `event`.
    private enum Field: String, CodingKey {
        case kind
        case source
        case progress
        case message
        case bundle
        case collection
        case error
    }

    private enum Shape {
        /// S2, written by `import msa` and `import tree`.
        case nativeBundleImport
        /// S3, written by `import geneious` and `import application-export`.
        case applicationExportImport

        /// What a progress line without a message showed.
        var progressMessage: String {
            switch self {
            case .nativeBundleImport: return "Importing bundle..."
            case .applicationExportImport: return "Importing application export..."
            }
        }

        /// What a failed line without an error showed.
        var failureMessage: String {
            switch self {
            case .nativeBundleImport: return "Native bundle import failed"
            case .applicationExportImport: return "Application export import failed"
            }
        }

        /// The key of the `complete` line that names what the import made.
        var outputKey: Field {
            switch self {
            case .nativeBundleImport: return .bundle
            case .applicationExportImport: return .collection
            }
        }

        /// The typed artifact of what the import made. A current `lungfish-cli` writes the same
        /// kind and role, apart from the provenance path, which a line of an old CLI does not name.
        func artifact(path: String) -> CLIEventArtifact {
            switch self {
            case .nativeBundleImport:
                let kind = BundleKindRegistry.descriptor(forLowercasedExtensionOf: URL(fileURLWithPath: path))?.id.rawValue
                return CLIEventArtifact(kind: kind ?? "", path: path, role: "bundle")
            case .applicationExportImport:
                return CLIEventArtifact(kind: "import-collection", path: path, role: "collection")
            }
        }
    }

    private enum Becomes {
        case start
        case progress
        case warning
        case complete
        case failed
    }

    private struct Row {
        let shape: Shape
        let becomes: Becomes
    }

    private static let rows: [String: Row] = [
        "nativeBundleImportStart": Row(shape: .nativeBundleImport, becomes: .start),
        "nativeBundleImportProgress": Row(shape: .nativeBundleImport, becomes: .progress),
        "nativeBundleImportWarning": Row(shape: .nativeBundleImport, becomes: .warning),
        "nativeBundleImportComplete": Row(shape: .nativeBundleImport, becomes: .complete),
        "nativeBundleImportFailed": Row(shape: .nativeBundleImport, becomes: .failed),
        "applicationExportImportStart": Row(shape: .applicationExportImport, becomes: .start),
        "applicationExportProgress": Row(shape: .applicationExportImport, becomes: .progress),
        "applicationExportWarning": Row(shape: .applicationExportImport, becomes: .warning),
        "applicationExportImportComplete": Row(shape: .applicationExportImport, becomes: .complete),
        "applicationExportImportFailed": Row(shape: .applicationExportImport, becomes: .failed),
    ]
}
