// ImportCommand+FASTA.swift - The import fasta leaf, moved out of ImportCommand.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - FASTA Import

extension ImportCommand {

    /// Import a standalone reference sequence file into a Lungfish project.
    ///
    /// Accepts FASTA/GenBank/EMBL (plain or compressed), then builds a canonical
    /// `.lungfishref` bundle in the project's "Reference Sequences" folder.
    struct FASTASubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "fasta",
            abstract: "Import a standalone reference sequence file as a .lungfishref bundle"
        )

        @Argument(help: "Path to the input reference (.fa/.fasta/.gb/.embl, optionally .gz/.bgz/.bz2/.xz/.zst)")
        var inputFile: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Display name for the reference (default: filename)"
        )
        var name: String?

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        private static let compressionExtensions: Set<String> = ["gz", "gzip", "bgz", "bz2", "xz", "zst", "zstd"]
        private static let fastaExtensions: Set<String> = ["fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn"]
        private static let genbankExtensions: Set<String> = ["gb", "gbk", "genbank", "gbff", "embl"]

        private struct BuildInputs {
            let fastaURL: URL
            let annotationInputs: [AnnotationInput]
            let recordStoreURL: URL?
            let warnings: [ReferenceImportWarning]
            let organism: String
            let sequenceNames: [String]
            let sequenceCount: Int
            let totalLength: Int64
        }

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input file not found: \(inputFile)"))
                throw CLIExitCode.inputError.exitCode
            }

            let ext = normalizedExtension(for: inputURL)
            guard Self.fastaExtensions.contains(ext) || Self.genbankExtensions.contains(ext) else {
                print(formatter.error("Unsupported reference format: .\(ext)"))
                throw CLIExitCode.formatError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)
            let refsDirectory = try ReferenceSequenceFolder.ensureFolder(in: outputDirectory)
            try FileManager.default.createDirectory(at: refsDirectory, withIntermediateDirectories: true)

            print(formatter.header("Reference Import"))
            print("")

            if !globalOptions.quiet {
                print(formatter.info("Preparing reference input..."))
            }

            let tempDirectory = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-cli-ref-import-",
                contextURL: outputDirectory
            )
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let displayName = resolvedBundleName(explicitName: name, sourceURL: inputURL)
            let buildInputs = try await prepareBuildInputs(
                sourceURL: inputURL,
                bundleName: displayName,
                tempDirectory: tempDirectory
            )

            let bundleName = makeUniqueBundleName(base: displayName, in: refsDirectory)
            for warning in buildInputs.warnings {
                print(formatter.warning(warning.message))
            }

            if !globalOptions.quiet {
                print(formatter.info("Building .lungfishref bundle..."))
            }

            let sourceInfo = SourceInfo(
                organism: buildInputs.organism.isEmpty ? bundleName : buildInputs.organism,
                assembly: bundleName,
                database: "Imported File",
                sourceURL: inputURL,
                downloadDate: Date(),
                notes: "Imported from \(inputURL.lastPathComponent)"
            )

            let configuration = BuildConfiguration(
                name: bundleName,
                identifier: "org.lungfish.cli.import.\(UUID().uuidString.lowercased())",
                fastaURL: buildInputs.fastaURL,
                annotationFiles: buildInputs.annotationInputs,
                outputDirectory: refsDirectory,
                source: sourceInfo,
                compressFASTA: true,
                provenanceWorkflowName: "lungfish import fasta",
                provenanceCommand: provenanceCommand(
                    sourceURL: inputURL,
                    outputDirectory: outputDirectory,
                    bundleName: bundleName
                ),
                provenanceInputFiles: [inputURL],
                warnings: buildInputs.warnings.map(\.bundleWarning),
                referenceRecordStoreURL: buildInputs.recordStoreURL
            )

            let bundleURL = try await NativeBundleBuilder().build(configuration: configuration)

            print("")
            print(formatter.header("Summary"))
            print("")
            print(formatter.keyValueTable([
                ("Name", bundleName),
                ("Sequences", String(buildInputs.sequenceCount)),
                ("Total length", formatBases(buildInputs.totalLength)),
                ("Bundle", bundleURL.lastPathComponent),
            ]))

            if !buildInputs.sequenceNames.isEmpty {
                let displayNames = buildInputs.sequenceNames.prefix(10)
                    .joined(separator: ", ")
                let suffix = buildInputs.sequenceNames.count > 10
                    ? " (+\(buildInputs.sequenceNames.count - 10) more)" : ""
                print("")
                print("  Sequences: \(displayNames)\(suffix)")
            }

            print("")
            print(formatter.success(
                "Reference import complete: \(bundleName) (\(buildInputs.sequenceCount) sequences, \(formatBases(buildInputs.totalLength)))"
            ))
        }

        private func normalizedExtension(for url: URL) -> String {
            var ext = url.pathExtension.lowercased()
            if Self.compressionExtensions.contains(ext) {
                ext = url.deletingPathExtension().pathExtension.lowercased()
            }
            return ext
        }

        private func resolvedBundleName(explicitName: String?, sourceURL: URL) -> String {
            let rawName: String
            if let explicitName {
                rawName = explicitName
            } else {
                rawName = ReferenceBundleImportService.defaultBundleName(for: sourceURL)
            }

            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = trimmed.isEmpty ? "Imported Reference" : trimmed
            return fallback
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
        }

        private func makeUniqueBundleName(base: String, in directory: URL) -> String {
            let fm = FileManager.default
            var candidate = base
            var counter = 2

            while fm.fileExists(atPath: bundleURL(for: candidate, in: directory).path) {
                candidate = "\(base) \(counter)"
                counter += 1
            }

            return candidate
        }

        private func bundleURL(for bundleName: String, in directory: URL) -> URL {
            let safe = bundleName
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
            return directory.appendingPathComponent("\(safe).lungfishref", isDirectory: true)
        }

        private func provenanceCommand(
            sourceURL: URL,
            outputDirectory: URL,
            bundleName: String
        ) -> [String] {
            var command = [
                CLICommandIdentity.executableName,
                "import",
                "fasta",
                sourceURL.path,
                "--output-dir",
                outputDirectory.path,
                "--name",
                bundleName,
            ]
            if globalOptions.quiet {
                command.append("--quiet")
            }
            return command
        }

        private func prepareBuildInputs(
            sourceURL: URL,
            bundleName: String,
            tempDirectory: URL
        ) async throws -> BuildInputs {
            let prepared = try await ReferenceSourcePreparer().prepare(
                sourceURL: sourceURL,
                bundleName: bundleName,
                tempDirectory: tempDirectory
            )
            let sequences = try await FASTAReader(url: prepared.fastaURL).readAll()
            guard !sequences.isEmpty else {
                throw CLIError.validationFailed(errors: ["No sequences found in \(sourceURL.lastPathComponent)"])
            }

            let sequenceNames = sequences.map(\.name)
            let totalLength = sequences.reduce(Int64(0)) { partial, sequence in
                partial + Int64(sequence.length)
            }

            return BuildInputs(
                fastaURL: prepared.fastaURL,
                annotationInputs: prepared.annotationInputs,
                recordStoreURL: prepared.recordStoreURL,
                warnings: prepared.warnings,
                organism: prepared.sourceInfo.organism,
                sequenceNames: sequenceNames,
                sequenceCount: sequences.count,
                totalLength: totalLength
            )
        }
    }
}
