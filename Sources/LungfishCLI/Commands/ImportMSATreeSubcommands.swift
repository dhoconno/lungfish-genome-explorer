import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ImportCommand {
    struct MSASubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "msa",
            abstract: "Import a multiple sequence alignment as a .lungfishmsa bundle"
        )

        @Argument(help: "Path to the alignment file")
        var inputFile: String

        @Option(name: .customLong("project"), help: "Lungfish project directory to import into")
        var projectPath: String

        @Option(name: .customLong("name"), help: "Display name for the alignment bundle")
        var name: String?

        @Option(name: .customLong("source-format"), help: "Source format: aligned-fasta, clustal, phylip, nexus, stockholm, a2m-a3m")
        var sourceFormat: String?

        @Option(name: .customLong("output"), help: "Explicit output .lungfishmsa bundle path")
        var outputPath: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let sourceURL = URL(fileURLWithPath: inputFile).standardizedFileURL
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
            let eventsOn = globalOptions.outputFormat == .json
            let emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
            emitter.emitStart(kind: BundleKindID.multipleSequenceAlignment.rawValue)

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                emitter.emitFailed("Input file not found: \(sourceURL.path)")
                throw CLIExitCode.inputError.exitCode
            }

            let name = name
            let sourceFormat = sourceFormat
            let outputPath = outputPath
            let startedAt = Date()
            let destination = ImportDestination()
            // SIGTERM, the app's Cancel, cancels the import from here on (decision S7). The importer reads
            // its input before it writes anything, so a cancel there leaves nothing behind.
            let outcome = await ImportCancellation.run { () async throws -> ImportedBundle in
                try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

                if let sourceFormat {
                    guard MultipleSequenceAlignmentBundle.SourceFormat(rawValue: sourceFormat) != nil else {
                        emitter.emitFailed("Unsupported source format '\(sourceFormat)'")
                        throw CLIExitCode.inputError.exitCode
                    }
                }

                emitter.emitProgress(0.12, message: "Preparing MSA bundle destination...")
                let displayName = sanitizedName(name ?? sourceURL.deletingPathExtension().lastPathComponent)
                let bundleURL = try resolvedBundleURL(
                    explicitOutputPath: outputPath,
                    projectURL: projectURL,
                    folderName: "Multiple Sequence Alignments",
                    displayName: displayName,
                    extensionName: MultipleSequenceAlignmentBundle.directoryExtension
                )
                destination.set(bundleURL)
                let argv = canonicalArgv(
                    command: "msa",
                    sourceURL: sourceURL,
                    projectURL: projectURL,
                    outputURL: bundleURL,
                    name: name,
                    sourceFormat: sourceFormat
                )

                emitter.emitProgress(0.35, message: "Parsing and indexing \(sourceURL.lastPathComponent)...")
                let summary = try await ImportCancellation.blocking {
                    let bundle = try MultipleSequenceAlignmentBundle.importAlignment(
                        from: sourceURL,
                        to: bundleURL,
                        options: .init(
                            name: displayName,
                            sourceFormat: sourceFormat.flatMap { MultipleSequenceAlignmentBundle.SourceFormat(rawValue: $0) },
                            argv: argv,
                            reproducibleCommand: shellCommand(argv)
                        )
                    )
                    return ImportedBundleSummary(
                        warnings: bundle.manifest.warnings,
                        summaryLines: ["Rows: \(bundle.manifest.rowCount)", "Columns: \(bundle.manifest.alignedLength)"]
                    )
                }
                return ImportedBundle(bundleURL: bundleURL, summary: summary)
            }

            switch outcome {
            case .success(let imported):
                for warning in imported.summary.warnings {
                    emitter.emitWarning(warning)
                }
                emitter.emitProgress(0.92, message: "Writing MSA provenance...")
                emitter.emitComplete(bundle: imported.bundleURL, kind: .multipleSequenceAlignment)

                if !globalOptions.quiet {
                    printHumanLine("Imported \(imported.bundleURL.path)", eventsOn: eventsOn)
                    for line in imported.summary.summaryLines {
                        printHumanLine(line, eventsOn: eventsOn)
                    }
                }
            case .failure(let error) where error is CancellationError:
                destination.removeIfCreatedByThisRun()
                throw await ImportCancellation.finish(
                    emitter: emitter,
                    command: "import msa",
                    parameters: ["input": .file(sourceURL), "project": .file(projectURL)],
                    recordDirectory: projectURL,
                    startedAt: startedAt
                )
            case .failure(let exitCode as ExitCode):
                throw exitCode
            case .failure(let error):
                emitter.emitFailed(CLIFailureWords.describe(error))
                throw CLIExitCode.formatError.exitCode
            }
        }
    }

    struct TreeSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tree",
            abstract: "Import a phylogenetic tree as a .lungfishtree bundle"
        )

        @Argument(help: "Path to the tree file")
        var inputFile: String

        @Option(name: .customLong("project"), help: "Lungfish project directory to import into")
        var projectPath: String

        @Option(name: .customLong("name"), help: "Display name for the tree bundle")
        var name: String?

        @Option(name: .customLong("source-format"), help: "Source format: newick or nexus")
        var sourceFormat: String?

        @Option(name: .customLong("output"), help: "Explicit output .lungfishtree bundle path")
        var outputPath: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let sourceURL = URL(fileURLWithPath: inputFile).standardizedFileURL
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
            let eventsOn = globalOptions.outputFormat == .json
            let emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
            emitter.emitStart(kind: BundleKindID.phylogeneticTree.rawValue)

            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                emitter.emitFailed("Input file not found: \(sourceURL.path)")
                throw CLIExitCode.inputError.exitCode
            }

            let name = name
            let sourceFormat = sourceFormat
            let outputPath = outputPath
            let startedAt = Date()
            let destination = ImportDestination()
            // SIGTERM, the app's Cancel, cancels the import from here on (decision S7). The importer reads
            // its input before it writes anything, so a cancel there leaves nothing behind.
            let outcome = await ImportCancellation.run { () async throws -> ImportedBundle in
                try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

                emitter.emitProgress(0.12, message: "Preparing tree bundle destination...")
                let displayName = sanitizedName(name ?? sourceURL.deletingPathExtension().lastPathComponent)
                let bundleURL = try resolvedBundleURL(
                    explicitOutputPath: outputPath,
                    projectURL: projectURL,
                    folderName: "Phylogenetic Trees",
                    displayName: displayName,
                    extensionName: "lungfishtree"
                )
                destination.set(bundleURL)
                let argv = canonicalArgv(
                    command: "tree",
                    sourceURL: sourceURL,
                    projectURL: projectURL,
                    outputURL: bundleURL,
                    name: name,
                    sourceFormat: sourceFormat
                )

                emitter.emitProgress(0.35, message: "Parsing and indexing \(sourceURL.lastPathComponent)...")
                let summary = try await ImportCancellation.blocking {
                    let bundle = try PhylogeneticTreeBundleImporter.importTree(
                        from: sourceURL,
                        to: bundleURL,
                        options: .init(
                            name: displayName,
                            argv: argv,
                            command: shellCommand(argv),
                            sourceFormat: sourceFormat
                        )
                    )
                    return ImportedBundleSummary(
                        warnings: bundle.manifest.warnings,
                        summaryLines: [
                            "Tips: \(bundle.manifest.tipCount)",
                            "Internal nodes: \(bundle.manifest.internalNodeCount)",
                        ]
                    )
                }
                return ImportedBundle(bundleURL: bundleURL, summary: summary)
            }

            switch outcome {
            case .success(let imported):
                for warning in imported.summary.warnings {
                    emitter.emitWarning(warning)
                }
                emitter.emitProgress(0.92, message: "Writing tree provenance...")
                emitter.emitComplete(bundle: imported.bundleURL, kind: .phylogeneticTree)

                if !globalOptions.quiet {
                    printHumanLine("Imported \(imported.bundleURL.path)", eventsOn: eventsOn)
                    for line in imported.summary.summaryLines {
                        printHumanLine(line, eventsOn: eventsOn)
                    }
                }
            case .failure(let error) where error is CancellationError:
                destination.removeIfCreatedByThisRun()
                throw await ImportCancellation.finish(
                    emitter: emitter,
                    command: "import tree",
                    parameters: ["input": .file(sourceURL), "project": .file(projectURL)],
                    recordDirectory: projectURL,
                    startedAt: startedAt
                )
            case .failure(let exitCode as ExitCode):
                throw exitCode
            case .failure(let error):
                emitter.emitFailed(CLIFailureWords.describe(error))
                throw CLIExitCode.formatError.exitCode
            }
        }
    }
}

private func resolvedBundleURL(
    explicitOutputPath: String?,
    projectURL: URL,
    folderName: String,
    displayName: String,
    extensionName: String
) throws -> URL {
    if let explicitOutputPath {
        let explicit = URL(fileURLWithPath: explicitOutputPath).standardizedFileURL
        try FileManager.default.createDirectory(at: explicit.deletingLastPathComponent(), withIntermediateDirectories: true)
        return explicit
    }

    let folder = projectURL.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let baseName = sanitizedName(displayName)
    var candidate = folder.appendingPathComponent("\(baseName).\(extensionName)", isDirectory: true)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = folder.appendingPathComponent("\(baseName) \(index).\(extensionName)", isDirectory: true)
        index += 1
    }
    return candidate
}

private func sanitizedName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = trimmed.isEmpty ? "Imported Bundle" : trimmed
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
    let sanitizedScalars = fallback.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    let sanitized = String(sanitizedScalars).trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? "Imported Bundle" : sanitized
}

private func canonicalArgv(
    command: String,
    sourceURL: URL,
    projectURL: URL,
    outputURL: URL,
    name: String?,
    sourceFormat: String?
) -> [String] {
    var argv = [CLICommandIdentity.executableName, "import", command, sourceURL.path, "--project", projectURL.path, "--output", outputURL.path]
    if let name {
        argv += ["--name", name]
    }
    if let sourceFormat {
        argv += ["--source-format", sourceFormat]
    }
    return argv
}

private func shellCommand(_ argv: [String]) -> String {
    argv.map(shellEscaped).joined(separator: " ")
}

private func shellEscaped(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=/:.,")
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
