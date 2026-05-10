// ImportCzIdSubcommand.swift - First-class CZ-ID project import command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishApp
import LungfishWorkflow

extension ImportCommand {
    /// Import a hosted CZ-ID taxon report into a project classification bundle.
    struct CzIdSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cz-id",
            abstract: "Import hosted CZ-ID classification results into a project"
        )

        @Argument(help: "Path to a CZ-ID taxon report TSV, ZIP archive, or extracted export folder")
        var inputPath: String

        @Option(name: .customLong("project"), help: "Lungfish project directory to import into")
        var projectPath: String

        @Option(name: .customLong("sample-name"), help: "Sample name for the imported .lungfishtax bundle")
        var sampleName: String

        @Option(name: .customLong("metadata"), help: "Optional CZ-ID metadata sidecar path to record in provenance")
        var metadataPath: String?

        @Option(name: .customLong("non-host-fastq"), help: "Optional non-host FASTQ path to record in provenance")
        var nonHostFastqPath: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let fileManager = FileManager.default
            let inputURL = URL(fileURLWithPath: inputPath)
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL

            guard fileManager.fileExists(atPath: inputURL.path) else {
                print(formatter.error("CZ-ID input not found: \(inputPath)"))
                throw ExitCode.failure
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                print(formatter.error("Project directory not found: \(projectURL.path)"))
                throw ExitCode.failure
            }

            let trimmedSampleName = sampleName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSampleName.isEmpty else {
                print(formatter.error("--sample-name cannot be empty"))
                throw ExitCode.failure
            }

            let metadataURL = metadataPath.map(URL.init(fileURLWithPath:))
            if let metadataURL, !fileManager.fileExists(atPath: metadataURL.path) {
                print(formatter.error("Metadata sidecar not found: \(metadataURL.path)"))
                throw ExitCode.failure
            }

            let nonHostFastqURL = nonHostFastqPath.map(URL.init(fileURLWithPath:))
            if let nonHostFastqURL, !fileManager.fileExists(atPath: nonHostFastqURL.path) {
                print(formatter.error("Non-host FASTQ not found: \(nonHostFastqURL.path)"))
                throw ExitCode.failure
            }

            let classificationsURL = projectURL.appendingPathComponent("Classifications", isDirectory: true)
            let bundleURL = classificationsURL.appendingPathComponent(
                "\(Self.bundleFileName(for: trimmedSampleName)).lungfishtax",
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: bundleURL.path) else {
                print(formatter.error("Classification bundle already exists: \(bundleURL.path)"))
                throw ExitCode.failure
            }

            try fileManager.createDirectory(at: classificationsURL, withIntermediateDirectories: true)

            var command = [
                "lungfish",
                "import",
                "cz-id",
                inputURL.path,
                "--project",
                projectURL.path,
                "--sample-name",
                trimmedSampleName,
            ]
            if let metadataPath {
                command.append(contentsOf: ["--metadata", metadataPath])
            }
            if let nonHostFastqPath {
                command.append(contentsOf: ["--non-host-fastq", nonHostFastqPath])
            }

            let conversion = try await CzIdImportPreview.withResolvedReport(from: inputURL) { resolved in
                let sourceInput = resolved.selectedSourceURL.standardizedFileURL == resolved.reportURL.standardizedFileURL
                    ? nil
                    : resolved.selectedSourceURL
                return try CzIdDataConverter.convertTaxonReport(
                    at: resolved.reportURL,
                    outputDirectory: bundleURL,
                    command: command,
                    sourceInputURL: sourceInput,
                    sampleNameOverride: trimmedSampleName,
                    additionalInputURLs: [metadataURL, nonHostFastqURL].compactMap { $0 },
                    provenanceToolName: "lungfish import cz-id",
                    provenanceParameters: [
                        "project": .file(projectURL),
                        "sampleName": .string(trimmedSampleName),
                        "czIdSchemaVersion": .string(CzIdDataConverter.schemaVersion),
                        "sourcePath": .file(inputURL),
                        "outputBundle": .file(bundleURL),
                        "metadataPath": metadataURL.map(ParameterValue.file) ?? .null,
                        "nonHostFastqPath": nonHostFastqURL.map(ParameterValue.file) ?? .null,
                    ]
                )
            }

            if !globalOptions.quiet {
                print(formatter.header("CZ-ID Import"))
                print("")
                print(formatter.keyValueTable([
                    ("Sample", conversion.manifest?.sampleName ?? trimmedSampleName),
                    ("Rows", String(conversion.parsed.rows.count)),
                    ("Pipeline", conversion.parsed.metadata.pipelineVersion ?? "unknown"),
                    ("NT database", conversion.parsed.metadata.ntDatabaseVersion ?? "unknown"),
                    ("NR database", conversion.parsed.metadata.nrDatabaseVersion ?? "unknown"),
                    ("Output", bundleURL.path),
                ]))
                print("")
                print(formatter.success("Imported CZ-ID result into \(bundleURL.path)"))
            }
        }

        private static func bundleFileName(for sampleName: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            let scalars = sampleName.unicodeScalars.map { scalar -> Character in
                allowed.contains(scalar) ? Character(scalar) : "-"
            }
            let name = String(scalars)
                .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            return name.isEmpty ? "cz-id-sample" : name
        }
    }
}
