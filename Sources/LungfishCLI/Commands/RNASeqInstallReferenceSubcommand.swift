// RNASeqInstallReferenceSubcommand.swift - `lungfish-cli rnaseq install-reference` (2026-11-26 novice path)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow
import Synchronization

extension RNASeqCommand {
    /// Downloads a catalog reference set, builds it and builds its salmon index, which Plugin Manager > Databases runs.
    struct InstallReferenceSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install-reference",
            abstract: "Download a reference set, build it and build its salmon index",
            discussion: """
                Lungfish checks that this Mac has the memory and free disk the salmon index needs, downloads the set's genome and GTF into the storage folder, checks each file's sha256 against the named set, builds the set as rnaseq reference-set --default does and builds its index at k 31 with the genome as decoys, as rnaseq index does. The downloads are kept, and a second run downloads and builds nothing. The sets are human/gencode-50, mouse/gencode-M39, rhesus/ensembl-116 and cynomolgus/refseq-GCF_037993035.2.
                """
        )

        @Option(name: .customLong("default"), help: "The named set to install: human/gencode-50, mouse/gencode-M39, rhesus/ensembl-116 or cynomolgus/refseq-GCF_037993035.2")
        var defaultID: String

        @Option(name: .customLong("storage-root"), help: "Managed storage root (default: the configured location)")
        var storageRoot: String?

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            guard globalOptions.threads == nil else {
                throw ValidationError("rnaseq install-reference always builds the index with 8 threads, so --threads does not apply. Leave it out.")
            }
        }

        func run() async throws {
            let eventsOn = globalOptions.outputFormat == .json
            try await execute(eventsOn: eventsOn, quiet: globalOptions.quiet, emit: printEventLine)
        }

        /// The run, with each event line handed to `emit`, so a test can keep them.
        func execute(
            eventsOn: Bool, quiet: Bool, emit: @escaping (String) -> Void, install: ReferenceSetInstall? = nil
        ) async throws {
            let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
            let say: @Sendable (String) -> Void = { text in if !quiet || eventsOn { printHumanLine(text, eventsOn: eventsOn) } }
            let root: URL
            do {
                root = try IndexSubcommand.resolveStorageRoot(storageRoot)
            } catch {
                events.emitFailed(error.localizedDescription)
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
            guard ReferenceSetCatalog.entry(defaultID) != nil else {
                let words = ReferenceSetInstallError.notInCatalog(defaultID, offered: ReferenceSetCatalog.entries.map(\.id))
                    .localizedDescription
                events.emitFailed(words)
                FileHandle.standardError.write(Data("Error: \(words)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
            let installer = install ?? ReferenceSetInstall(storageRoot: root)
            let id = defaultID
            events.emitStart("Installing the reference set \(id)")
            let argv = CommandLine.arguments
            let percent = PercentGate()
            let ended = await ManagedToolLeaf.cancellingOnSIGTERM { () async throws -> ReferenceSetInstallOutcome in
                try await installer.install(id, argv: argv) { step in
                    switch step {
                    case .downloading(let fraction, let message):
                        // One event a whole percent, since the loader reports every network chunk.
                        if percent.advance(to: Int(fraction * 100)) { events.emitProgress(fraction, message: message) }
                    case .stage(let message):
                        events.emitLog(.info, message)
                        if !eventsOn { say(message) }
                    }
                }
            }
            switch ended {
            case .success(let outcome):
                say("Installed reference set \(outcome.setID)")
                say(outcome.setURL.path)
                say(outcome.indexURL.path)
                events.emitComplete(
                    outputs: [outcome.setURL.path, outcome.indexURL.path],
                    message: "Ready to count with the reference set \(outcome.setID)")
            case .failure(let error):
                if ManagedToolLeaf.endedOnCancel(error) {
                    let words = "Install cancelled. The downloads that finished are kept and the next Download uses them."
                    events.emitFailed(words)
                    FileHandle.standardError.write(Data("\(words)\n".utf8))
                    throw CLIExitCode.cancelled.exitCode
                }
                events.emitFailed(error.localizedDescription)
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.failure.exitCode
            }
        }
    }
}

/// Passes each whole percent once.
private final class PercentGate: Sendable {
    private let last = Mutex(-1)

    func advance(to value: Int) -> Bool {
        last.withLock { last in
            guard value > last else { return false }
            last = value
            return true
        }
    }
}
