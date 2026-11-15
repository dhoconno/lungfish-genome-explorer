// RNASeqQuantSubcommand.swift - `lungfish-cli rnaseq quant` (Phase 5.1 lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension RNASeqCommand {
    /// Counts a project's bulk reads with salmon on the published index of a reference set, one FASTQ bundle a sample, and
    /// writes one result in the project's `Analyses/`.
    struct QuantSubcommand: AsyncParsableCommand {
        /// The Linux route every refusal of a quant that cannot fit ends on (ADJ-SPIKE-ARCH item 7).
        static let linuxRoute = "LGE does not count these reads on Linux yet: run salmon there, or nf-core/rnaseq, and bring "
            + "its salmon folders into a project with lungfish-cli import rnaseq"

        static let configuration = CommandConfiguration(
            commandName: "quant",
            abstract: "Count bulk RNA-seq reads in a project with salmon",
            discussion: """
                Each FASTQ bundle is one sample. Lungfish runs salmon quant with selective alignment and library type A on the set's own index, which lungfish-cli rnaseq index builds, and never builds one itself. Reads are not trimmed unless you pass --trim, which runs Trim Galore with poly-G trimming off unless you pass --poly-g-trimming on. Duplicates are kept.

                The result holds transcript counts and gene sums through the set's transcript table, in unit estimated, and its record names the set, the index's hashes, salmon's version and every setting that changes counts. --threads is recorded and changes no count.
                """
        )

        @Argument(help: "FASTQ bundles, one sample each")
        var bundles: [String]

        @Option(name: .customLong("project"), help: "The project the result is written in")
        var project: String

        @Option(name: .customLong("name"), help: "The result's name")
        var name: String = "RNA-seq counts"

        @Option(name: .customLong("set"), help: "The id of a reference set under the storage root")
        var setID: String

        @Option(name: .customLong("k"), help: "k-mer length of the index, an odd number up to 31")
        var k: Int = 31

        @Option(name: .customLong("decoys"), help: "genome (the default) for the index with the genome as decoys, or none")
        var decoys: String = "genome"

        @Flag(name: .customLong("trim"), help: "Trim the reads with Trim Galore before salmon (default: not trimmed)")
        var trim: Bool = false

        @Option(name: .customLong("poly-g-trimming"), help: "With --trim: on passes --poly_g to Trim Galore, off (the default) --no_poly_g")
        var polyGTrimming: String?

        @Option(name: .customLong("storage-root"), help: "Managed storage root (default: the configured location)")
        var storageRoot: String?

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            guard decoys == "genome" || decoys == "none" else { throw ValidationError("--decoys is genome or none, not \(decoys).") }
            if let polyGTrimming {
                guard polyGTrimming == "on" || polyGTrimming == "off" else {
                    throw ValidationError("--poly-g-trimming is on or off, not \(polyGTrimming).")
                }
                guard trim else { throw ValidationError("--poly-g-trimming needs --trim, since reads are not trimmed without it.") }
            }
            if let threads = globalOptions.threads, threads < 1 { throw ValidationError("--threads is a number from 1 up.") }
        }

        /// The route's request. `--threads` defaults to the 6 of the scripts that GS and GC ran.
        func makeRequest(argv: [String]) -> SalmonQuantRequest {
            SalmonQuantRequest(
                bundles: bundles.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL },
                projectURL: URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL, name: name, setID: setID,
                k: k, decoys: decoys == "none" ? .none : .genome, threads: globalOptions.threads ?? 6,
                trim: trim ? .trimGalore(polyG: polyGTrimming == "on") : .none, argv: argv)
        }

        func run() async throws {
            try await execute(argv: CommandLine.arguments)
        }

        /// Runs the quant with `argv` as the command recorded. One SIGTERM cancels it: salmon ends, the working folder goes,
        /// nothing is published and the command exits 125.
        func execute(argv: [String]) async throws {
            let root: URL
            do {
                root = try resolvedStorageRoot()
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
            let request = makeRequest(argv: argv)
            let route = SalmonQuantRoute(
                storageRoot: root, host: RunFitHostFacts(physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)))
            let ran = await runCancellingOnSIGTERM { try await route.run(request, linuxRoute: Self.linuxRoute) }
            switch ran {
            case .success(let outcome):
                if globalOptions.outputFormat == .json {
                    let summary: [String: Any] = [
                        "setID": setID, "result": outcome.resultURL.path, "samples": outcome.samples,
                        "index": outcome.index.key.folderName, "index_seq_hash": outcome.index.hashes.seqHash,
                    ]
                    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
                    print(String(decoding: data, as: UTF8.self))
                } else if !globalOptions.quiet {
                    print("Counted \(outcome.samples.count) sample\(outcome.samples.count == 1 ? "" : "s") against set \(setID)")
                    print(outcome.resultURL.path)
                }
            case .failure(let error) where error is CancellationError:
                FileHandle.standardError.write(Data("The quant was cancelled. No result was written.\n".utf8))
                throw CLIExitCode.cancelled.exitCode
            case .failure(let error):
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                switch error {
                case is SalmonQuantError, is SalmonIndexError, is RunFitError: throw CLIExitCode.inputError.exitCode
                default: throw CLIExitCode.failure.exitCode
                }
            }
        }

        /// `--storage-root`, else the configured location, set in this process before anything reads it, as
        /// `rnaseq index` does, so salmon comes from the root the index is under.
        func resolvedStorageRoot() throws -> URL {
            guard let storageRoot, !storageRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ManagedStorageConfigStore().currentLocation().rootURL
            }
            let requested = URL(fileURLWithPath: storageRoot, isDirectory: true).standardizedFileURL
            setenv("LUNGFISH_STORAGE_ROOT", requested.path, 1)
            let resolved = ManagedStorageConfigStore().currentLocation().rootURL
            guard resolved == requested else {
                throw SalmonQuantError.invalidRequest(
                    "The storage root \(requested.path) is unavailable. It must be a folder you can write to.")
            }
            return resolved
        }
    }
}
