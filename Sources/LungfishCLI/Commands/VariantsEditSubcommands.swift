// VariantsEditSubcommands.swift - Delete variants from, or import sample metadata into, a reference bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The stored edits of the variant table that had no command (2.10 A43, plan decision C3). Each
/// leaf calls the Workflow function the variant table calls, so the bundle and its records equal
/// what the table writes, and each record names the command that reproduces the edit. With
/// `--format json` a leaf writes only `CLIEvent` lines on standard output, and its start and
/// complete messages are the words the table's row shows.
extension VariantsCommand {
    /// Deletes the selected variants, or every variant, through `VariantDeletionMutationService`,
    /// the function the table's Delete and Delete All menu items call.
    struct DeleteSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete variants from the variant databases of a reference bundle."
        )

        @Argument(help: "Reference bundle to edit")
        var bundle: String

        @Flag(name: .customLong("all"), help: "Delete every variant of every variant track.")
        var all = false

        @Option(
            name: .customLong("variant-id"),
            help: "Delete one variant, named <track-id>:<row-id>. Repeat for more variants."
        )
        var variantIDs: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            if all && !variantIDs.isEmpty {
                throw ValidationError("Pass --all or --variant-id, not both.")
            }
            if !all && variantIDs.isEmpty {
                throw ValidationError("Pass --all to delete every variant, or --variant-id <track-id>:<row-id> for each variant to delete.")
            }
            do {
                _ = try VariantDeletionMutationService.selection(fromVariantIDs: variantIDs)
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }

        func run() async throws {
            try await execute(emit: { printEventLine($0) })
        }

        /// The run, with each event line handed to `emit`.
        func execute(emit: @escaping (String) -> Void) async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
            events.emitStart(VariantsEditWords.start)
            do {
                let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
                try VariantsEditWords.checkBundle(bundleURL)
                let tracks = try VariantEditTargets.tracks(inBundleAt: bundleURL)
                let selection = try VariantDeletionMutationService.selection(fromVariantIDs: variantIDs)
                for trackID in selection.keys.sorted() where !tracks.contains(where: { $0.id == trackID }) {
                    throw ValidationError(
                        "The bundle holds no variant track '\(trackID)' with a database. Its tracks are "
                            + (tracks.isEmpty ? "none." : tracks.map(\.id).joined(separator: ", ") + ".")
                    )
                }
                let targets = tracks.map {
                    VariantDeletionMutationTarget(trackId: $0.id, databaseURL: $0.databaseURL, trackName: $0.name)
                }
                let argv = recordedArguments(bundleURL: bundleURL, selection: selection)
                let service = VariantDeletionMutationService(toolName: CLICommandIdentity.executableName, toolKind: CLICommandIdentity.recordedToolKind)
                let result = try all
                    ? service.deleteAllVariants(bundleURL: bundleURL, targets: targets, invocationArgv: argv)
                    : service.deleteVariants(idsByTrack: selection, bundleURL: bundleURL, targets: targets, invocationArgv: argv)
                let changed = result.totalDeleted > 0
                events.emitComplete(
                    output: bundleURL.path,
                    message: changed ? VariantsEditWords.complete : "No matching variants. The bundle is unchanged."
                )
                if !globalOptions.quiet {
                    let count = result.totalDeleted
                    printHumanLine("Deleted \(count) variant\(count == 1 ? "" : "s").", eventsOn: eventsOn)
                }
            } catch {
                events.emitFailed(CLIFailureWords.describe(error))
                throw error
            }
        }

        /// The argv the record names, the words the process was started with, or, for a run inside
        /// another process, the command the table's row records for the same deletion.
        func recordedArguments(bundleURL: URL, selection: [String: [Int64]]) -> [String] {
            observedProcessVariantsCommandArguments(subcommand: "delete")
                ?? [CLICommandIdentity.executableName] + (all
                    ? VariantDeletionMutationService.deleteAllArguments(bundleURL: bundleURL)
                    : VariantDeletionMutationService.deleteSelectedArguments(bundleURL: bundleURL, idsByTrack: selection))
        }
    }

    /// Imports a CSV or TSV file of sample metadata through `VariantSampleMetadataImportService`,
    /// the function the table's Import Metadata button calls.
    struct ImportSampleMetadataSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import-sample-metadata",
            abstract: "Import a CSV or TSV file of sample metadata into the variant databases of a reference bundle."
        )

        @Argument(help: "Reference bundle to edit")
        var bundle: String

        @Argument(help: "CSV or TSV file of sample metadata. Its first column names the sample.")
        var metadataFile: String

        @Option(
            name: .customLong("metadata-format"),
            help: "File format, csv or tsv. Taken from the file extension when omitted (csv, else tsv)."
        )
        var metadataFormat: String?

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            if let metadataFormat, !["csv", "tsv"].contains(metadataFormat.lowercased()) {
                throw ValidationError("--metadata-format must be csv or tsv.")
            }
        }

        /// Runs the import so that SIGTERM cancels it instead of ending the command, as the app's
        /// Cancel does (plan decision C5). The import then leaves the bundle as it was, and the
        /// command exits 125. The command listens before the task starts, so an early SIGTERM
        /// cancels the task once it exists, and a second SIGTERM ends the command at once.
        func run() async throws {
            let pendingCancel = PendingTaskCancel<(any Error)?>()
            // The task's cancel is read by the import at its next ask, before it writes the record.
            let termination = SIGTERMCancellation(secondSignalEndsProcess: true) {
                pendingCancel.cancel()
                FileHandle.standardError.write(Data("Cancelling the import.\n".utf8))
            }
            defer { termination.end() }
            let task = Task { () -> (any Error)? in
                do {
                    try await self.execute(emit: { printEventLine($0) })
                    return nil
                } catch {
                    return error
                }
            }
            pendingCancel.attach(task)
            guard let error = await task.value else { return }
            if error is CancellationError {
                FileHandle.standardError.write(Data("Import cancelled. The bundle is as it was.\n".utf8))
                throw CLIExitCode.cancelled.exitCode
            }
            throw error
        }

        /// The run, with each event line handed to `emit`.
        func execute(emit: @escaping (String) -> Void) async throws {
            let eventsOn = globalOptions.outputFormat == .json
            let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
            events.emitStart(VariantsEditWords.start)
            do {
                let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
                let fileURL = URL(fileURLWithPath: metadataFile).standardizedFileURL
                try VariantsEditWords.checkBundle(bundleURL)
                try Self.checkFile(fileURL)
                let tracks = try VariantEditTargets.tracks(inBundleAt: bundleURL)
                guard !tracks.isEmpty else {
                    throw ValidationError("The bundle holds no variant database to import sample metadata into.")
                }
                let format = resolvedFormat(for: fileURL)
                // The table names each target by its track ID.
                let targets = tracks.map { VariantSampleMetadataImportTarget(databaseURL: $0.databaseURL, trackName: $0.id) }
                let result = try VariantSampleMetadataImportService(toolName: CLICommandIdentity.executableName, toolKind: CLICommandIdentity.recordedToolKind).importMetadata(
                    from: fileURL,
                    format: format,
                    bundleURL: bundleURL,
                    targets: targets,
                    invocationArgv: recordedArguments(fileURL: fileURL, format: format, bundleURL: bundleURL),
                    shouldCancel: { Task.isCancelled }
                )
                events.emitComplete(output: bundleURL.path, message: VariantsEditWords.complete)
                if !globalOptions.quiet {
                    let count = result.totalUpdated
                    printHumanLine(
                        "Updated \(count) sample row\(count == 1 ? "" : "s") in \(result.updatedDatabaseCount) database\(result.updatedDatabaseCount == 1 ? "" : "s").",
                        eventsOn: eventsOn
                    )
                }
            } catch is CancellationError {
                // A cancel is not a failure. The app's transport reports it from the exit.
                throw CancellationError()
            } catch {
                events.emitFailed(CLIFailureWords.describe(error))
                throw error
            }
        }

        /// The format the table reads the file as, the option when given, else `csv` for a `.csv`
        /// file and `tsv` for any other.
        func resolvedFormat(for fileURL: URL) -> MetadataFormat {
            switch metadataFormat?.lowercased() {
            case "csv": return .csv
            case "tsv": return .tsv
            default: return fileURL.pathExtension.lowercased() == "csv" ? .csv : .tsv
            }
        }

        /// The import reads `file` and writes inside the bundle, so the file is checked before the
        /// service writes anything. A link to a file counts as a file.
        static func checkFile(_ file: URL) throws {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ValidationError("No sample metadata file at \(file.path). Pass a CSV or TSV file.")
            }
        }

        /// The argv the record names, the words the process was started with, or, for a run inside
        /// another process, the command the table's row records for the same import.
        func recordedArguments(fileURL: URL, format: MetadataFormat, bundleURL: URL) -> [String] {
            observedProcessVariantsCommandArguments(subcommand: "import-sample-metadata")
                ?? [CLICommandIdentity.executableName] + VariantSampleMetadataImportService.importMetadataArguments(
                    metadataURL: fileURL, format: format, bundleURL: bundleURL
                )
        }
    }
}

/// What the two leaves share.
enum VariantsEditWords {
    /// The words of the table's row, "Updating stored data and provenance" while it runs and
    /// "Data and provenance updated" once it is done (`beginVariantStorageMutationOperation`).
    static let start = "Updating stored data and provenance"
    static let complete = "Data and provenance updated"

    /// The edits write inside `bundle`, so it is checked before the service writes anything.
    static func checkBundle(_ bundle: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundle.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ValidationError("No reference bundle at \(bundle.path). Pass a .lungfishref folder.")
        }
    }
}

/// The argv the process was started with when it runs `variants <subcommand>`, else nil. The
/// `sequence` leaves read theirs the same way (`observedProcessSequenceCommandArguments`).
func observedProcessVariantsCommandArguments(subcommand: String) -> [String]? {
    let rawArguments = CommandLine.arguments
    guard let executable = rawArguments.first else { return nil }
    let processArguments = Array(rawArguments.dropFirst())
    let normalizedArguments = LungfishCLI.normalizedArgumentsForParsing(processArguments)
    guard let groupIndex = normalizedArguments.firstIndex(of: "variants"),
          normalizedArguments.indices.contains(normalizedArguments.index(after: groupIndex)),
          normalizedArguments[normalizedArguments.index(after: groupIndex)] == subcommand else {
        return nil
    }
    return [executable] + processArguments
}
