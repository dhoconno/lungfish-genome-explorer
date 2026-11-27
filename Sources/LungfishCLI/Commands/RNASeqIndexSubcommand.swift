// RNASeqIndexSubcommand.swift - `lungfish-cli rnaseq index` (Phase 5.1 lane RS-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension RNASeqCommand {
    /// Builds the salmon index of a reference set under the storage root, or reuses the published index of the same key.
    struct IndexSubcommand: AsyncParsableCommand {
        /// The Linux route every refusal of a build ends on (ADJ-SPIKE-ARCH item 7).
        static let linuxRoute = "LGE does not build this index on Linux yet: run salmon there, or nf-core/rnaseq, and bring "
            + "its salmon folders into a project with lungfish-cli import rnaseq"

        static let configuration = CommandConfiguration(
            commandName: "index",
            abstract: "Build or reuse the salmon index of a reference set",
            discussion: """
                Lungfish writes the set's transcripts and then its genome as decoys into one file, runs salmon index with the same options every time, and keeps the index under the storage root by set, salmon version, k and decoys. A second request of the same index reuses it and starts no salmon. Every build runs salmon with 8 threads, so --threads does not apply.

                A build needs about 16.6 GB of memory and 64 GB of free disk. On a Mac with less, Lungfish refuses before it starts and says how to build the index on Linux.
                """
        )

        @Option(name: .customLong("set"), help: "The id of a reference set under the storage root")
        var setID: String

        @Option(name: .customLong("k"), help: "k-mer length, an odd number up to 31")
        var k: Int = 31

        @Option(name: .customLong("decoys"), help: "genome (the default) to add the genome as decoys, or none")
        var decoys: String = "genome"

        @Option(name: .customLong("storage-root"), help: "Managed storage root (default: the configured location)")
        var storageRoot: String?

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            guard decoys == "genome" || decoys == "none" else { throw ValidationError("--decoys is genome or none, not \(decoys).") }
            // `-p 8` is fixed (ADJ-SPIKE-BIO item 10), so a thread count is refused in words rather than dropped.
            guard globalOptions.threads == nil else {
                throw ValidationError("rnaseq index always runs salmon with 8 threads, so --threads does not apply. Leave it out.")
            }
        }

        func run() async throws {
            let root: URL
            do {
                root = try resolvedStorageRoot()
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
            let cache = SalmonIndexCache(
                storageRoot: root, host: RunFitHostFacts(physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)))
            let request = SalmonIndexRequest(setID: setID, k: k, decoys: decoys == "none" ? .none : .genome)
            do {
                let outcome = try await cache.ensure(request, linuxRoute: Self.linuxRoute, argv: CommandLine.arguments)
                if globalOptions.outputFormat == .json {
                    var summary: [String: Any] = [
                        "setID": setID, "key": outcome.key.folderName, "path": outcome.indexURL.path, "reused": outcome.reused,
                        "index_seq_hash": outcome.hashes.seqHash, "index_name_hash": outcome.hashes.nameHash,
                    ]
                    if let hash = outcome.hashes.decoySeqHash { summary["index_decoy_seq_hash"] = hash }
                    if let hash = outcome.hashes.decoyNameHash { summary["index_decoy_name_hash"] = hash }
                    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
                    print(String(decoding: data, as: UTF8.self))
                } else if !globalOptions.quiet {
                    print("\(outcome.reused ? "Reused" : "Built") salmon index \(outcome.key.folderName) of set \(setID)")
                    print(outcome.indexURL.path)
                }
            } catch let error as SalmonIndexError {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            } catch let error as RunFitError {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
        }

        /// `--storage-root`, else the configured location, set in this process before anything reads it, as
        /// `rnaseq reference-set` does, so salmon comes from the root the index is written under.
        func resolvedStorageRoot() throws -> URL {
            try Self.resolveStorageRoot(storageRoot)
        }

        /// `--storage-root` as `rnaseq index` and `rnaseq install-reference` read it.
        static func resolveStorageRoot(_ storageRoot: String?) throws -> URL {
            guard let storageRoot, !storageRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ManagedStorageConfigStore().currentLocation().rootURL
            }
            let requested = URL(fileURLWithPath: storageRoot, isDirectory: true).standardizedFileURL
            setenv("LUNGFISH_STORAGE_ROOT", requested.path, 1)
            let resolved = ManagedStorageConfigStore().currentLocation().rootURL
            guard resolved == requested else {
                throw SalmonIndexError.invalidRequest(
                    "The storage root \(requested.path) is unavailable. It must be a folder you can write to.")
            }
            return resolved
        }
    }
}
