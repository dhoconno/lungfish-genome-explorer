// RNASeqReferenceSetSubcommand.swift - `lungfish-cli rnaseq reference-set` (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

extension RNASeqCommand {
    /// Builds a reference set under the storage root, or reuses the published set of the same id.
    struct ReferenceSetSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reference-set",
            abstract: "Build a reference set from a genome, an annotation and extra sequences",
            discussion: """
                Lungfish copies each file into the set, checks its sha256, writes the transcript FASTA with gffread and
                the gene and transcript tables, and names the set by its content. A set of the same content is reused.
                An extra is "<kind>,<name>,<fasta>[,<annotation>]", where kind is virus, bacterium or spike-in. The
                annotation of an extra needs --layout deposit.
                """
        )

        @Option(name: .customLong("genome"), help: "Genome FASTA, plain or gzip, or a .lungfishref reference bundle")
        var genomePath: String

        @Option(name: .customLong("annotation"), help: "GTF annotation of the genome, plain or gzip")
        var annotationPath: String

        @Option(name: .customLong("default"), help: "A named default set whose checksums the files must equal, such as rhesus/ensembl-100")
        var defaultID: String?

        @Option(name: .customLong("name"), help: "Display name of the set")
        var name: String?

        @Option(name: .customLong("species"), help: "Species, such as \"Macaca mulatta\"")
        var species: String?

        @Option(name: .customLong("assembly"), help: "Assembly name, such as Mmul_10")
        var assembly: String?

        @Option(name: .customLong("assembly-accession"), help: "Assembly accession")
        var assemblyAccession: String?

        @Option(name: .customLong("annotation-source"), help: "Annotation source, such as Ensembl or RefSeq")
        var annotationSource: String?

        @Option(name: .customLong("annotation-release"), help: "Annotation release, such as 100")
        var annotationRelease: String?

        @Option(name: .customLong("extra"), help: "An extra sequence as <kind>,<name>,<fasta>[,<annotation>], in the order given")
        var extras: [String] = []

        @Option(name: .customLong("extra-mask"), help: "An extra's rRNA mask as <name>,<gtf>, the GTF's gene lines of gene_biotype rRNA")
        var extraMasks: [String] = []

        @Option(name: .customLong("layout"), help: "lge (the default) or deposit")
        var layout: String = "lge"

        @Option(name: .customLong("study"), help: "The study whose deposit the deposit layout reproduces")
        var study: String?

        @Option(name: .customLong("mitochondrial-contig"), help: "A mitochondrial contig, when the files do not name it")
        var mitochondrialContigs: [String] = []

        @Option(name: .customLong("assembly-report"), help: "NCBI assembly report that types the mitochondrion")
        var assemblyReport: String?

        @Option(name: .customLong("storage-root"), help: "Managed storage root (default: the configured location)")
        var storageRoot: String?

        @OptionGroup var globalOptions: GlobalOptions

        func validate() throws {
            guard layout == "lge" || layout == "deposit" else { throw ValidationError("--layout is lge or deposit, not \(layout).") }
            if layout == "deposit", (study ?? "").isEmpty { throw ValidationError("--layout deposit needs --study, the study it reproduces.") }
        }

        func run() async throws {
            let request: ReferenceSetRequest
            let root: URL
            do {
                request = try makeRequest()
                root = try resolvedStorageRoot()
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
            do {
                let outcome = try await ReferenceSetOwner(storageRoot: root).build(request, argv: CommandLine.arguments)
                if globalOptions.outputFormat == .json {
                    let summary: [String: Any] = ["id": outcome.manifest.id, "path": outcome.url.path, "reused": outcome.reused]
                    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
                    print(String(decoding: data, as: UTF8.self))
                } else if !globalOptions.quiet {
                    print("\(outcome.reused ? "Reused" : "Built") reference set \(outcome.manifest.id)")
                    print(outcome.url.path)
                }
                for note in outcome.notes { FileHandle.standardError.write(Data("Note: \(note)\n".utf8)) }
            } catch let error as ReferenceSetError {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
        }

        /// `--storage-root`, else the configured location. As `tools --storage-root` does (`ToolsCommand.swift:189-215`),
        /// the root is set as `LUNGFISH_STORAGE_ROOT` in this process before anything reads it, so gffread and the
        /// version in the set's id come from the root the set is written under, never from the configured one.
        func resolvedStorageRoot() throws -> URL {
            guard let storageRoot, !storageRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ManagedStorageConfigStore().currentLocation().rootURL
            }
            let requested = URL(fileURLWithPath: storageRoot, isDirectory: true).standardizedFileURL
            setenv("LUNGFISH_STORAGE_ROOT", requested.path, 1)
            let resolved = ManagedStorageConfigStore().currentLocation().rootURL
            guard resolved == requested else {
                // `currentLocation` falls back to the configured root when the folder is missing or not writable.
                throw ReferenceSetError.invalidRequest(
                    "The storage root \(requested.path) is unavailable. It must be a folder you can write to.")
            }
            return resolved
        }

        /// The request the options name. A named default fills what the options leave out and carries its checksums.
        func makeRequest() throws -> ReferenceSetRequest {
            let named = try defaultID.map(ReferenceSetDefault.named)
            func value(_ given: String?, _ fallback: String?, _ flag: String) throws -> String {
                guard let text = given ?? fallback, !text.isEmpty else {
                    throw ReferenceSetError.invalidRequest("\(flag) is needed, or --default naming a set.")
                }
                return text
            }
            let species = try value(self.species, named?.species, "--species")
            let assembly = try value(self.assembly, named?.assemblyName, "--assembly")
            let source = try value(annotationSource, named?.annotationSource, "--annotation-source")
            let release = try value(annotationRelease, named?.annotationRelease, "--annotation-release")
            return ReferenceSetRequest(
                name: name ?? "\(species) \(assembly) \(source) \(release)", species: species, assemblyName: assembly,
                assemblyAccession: assemblyAccession ?? named?.assemblyAccession, assemblySourceURL: named?.genomeURL,
                annotationSource: source, annotationRelease: release, genome: URL(fileURLWithPath: genomePath),
                annotation: URL(fileURLWithPath: annotationPath), extras: try Self.masking(extras.map(Self.parseExtra), with: extraMasks),
                layout: layout == "deposit" ? .deposit(study: study ?? "") : .lge, mitochondrialContigs: mitochondrialContigs,
                assemblyReport: assemblyReport.map { URL(fileURLWithPath: $0) }, expected: named)
        }

        static func parseExtra(_ text: String) throws -> ReferenceSetExtraInput {
            let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 || parts.count == 4, let kind = ReferenceSetExtraKind(rawValue: parts[0]), !parts[1].isEmpty else {
                throw ReferenceSetError.invalidRequest(
                    "--extra \(text) is not <kind>,<name>,<fasta>[,<annotation>] with kind virus, bacterium or spike-in.")
            }
            return ReferenceSetExtraInput(
                name: parts[1], kind: kind, fasta: URL(fileURLWithPath: parts[2]),
                annotation: parts.count == 4 ? URL(fileURLWithPath: parts[3]) : nil)
        }

        /// Each `--extra-mask <name>,<gtf>` joins the extra of that name, once an extra.
        static func masking(_ extras: [ReferenceSetExtraInput], with masks: [String]) throws -> [ReferenceSetExtraInput] {
            var extras = extras
            for text in masks {
                guard let comma = text.firstIndex(of: ","), comma != text.startIndex, text.index(after: comma) != text.endIndex else {
                    throw ReferenceSetError.invalidRequest("--extra-mask \(text) is not <name>,<gtf>.")
                }
                let name = String(text[..<comma])
                guard let index = extras.firstIndex(where: { $0.name == name }) else {
                    throw ReferenceSetError.invalidRequest("--extra-mask \(text) names no extra \(name). Give the extra with --extra first.")
                }
                guard extras[index].mask == nil else {
                    throw ReferenceSetError.invalidRequest("The extra \(name) takes one mask, and --extra-mask names it twice.")
                }
                extras[index].mask = URL(fileURLWithPath: String(text[text.index(after: comma)...]))
            }
            return extras
        }
    }
}
