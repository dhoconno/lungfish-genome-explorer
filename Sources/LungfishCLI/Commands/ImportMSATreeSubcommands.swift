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

            do {
                try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

                let resolvedFormat: MultipleSequenceAlignmentBundle.SourceFormat?
                if let sourceFormat {
                    guard let parsed = MultipleSequenceAlignmentBundle.SourceFormat(rawValue: sourceFormat) else {
                        emitter.emitFailed("Unsupported source format '\(sourceFormat)'")
                        throw CLIExitCode.inputError.exitCode
                    }
                    resolvedFormat = parsed
                } else {
                    resolvedFormat = nil
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
                let argv = canonicalArgv(
                    command: "msa",
                    sourceURL: sourceURL,
                    projectURL: projectURL,
                    outputURL: bundleURL,
                    name: name,
                    sourceFormat: sourceFormat
                )

                emitter.emitProgress(0.35, message: "Parsing and indexing \(sourceURL.lastPathComponent)...")
                let bundle = try MultipleSequenceAlignmentBundle.importAlignment(
                    from: sourceURL,
                    to: bundleURL,
                    options: .init(
                        name: displayName,
                        sourceFormat: resolvedFormat,
                        argv: argv,
                        reproducibleCommand: shellCommand(argv)
                    )
                )

                for warning in bundle.manifest.warnings {
                    emitter.emitWarning(warning)
                }
                emitter.emitProgress(0.92, message: "Writing MSA provenance...")
                emitter.emitComplete(bundle: bundleURL, kind: .multipleSequenceAlignment)

                if !globalOptions.quiet {
                    printHumanLine("Imported \(bundleURL.path)", eventsOn: eventsOn)
                    printHumanLine("Rows: \(bundle.manifest.rowCount)", eventsOn: eventsOn)
                    printHumanLine("Columns: \(bundle.manifest.alignedLength)", eventsOn: eventsOn)
                }
            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                emitter.emitFailed(error.localizedDescription)
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

            do {
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
                let argv = canonicalArgv(
                    command: "tree",
                    sourceURL: sourceURL,
                    projectURL: projectURL,
                    outputURL: bundleURL,
                    name: name,
                    sourceFormat: sourceFormat
                )

                emitter.emitProgress(0.35, message: "Parsing and indexing \(sourceURL.lastPathComponent)...")
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

                for warning in bundle.manifest.warnings {
                    emitter.emitWarning(warning)
                }
                emitter.emitProgress(0.92, message: "Writing tree provenance...")
                emitter.emitComplete(bundle: bundleURL, kind: .phylogeneticTree)

                if !globalOptions.quiet {
                    printHumanLine("Imported \(bundleURL.path)", eventsOn: eventsOn)
                    printHumanLine("Tips: \(bundle.manifest.tipCount)", eventsOn: eventsOn)
                    printHumanLine("Internal nodes: \(bundle.manifest.internalNodeCount)", eventsOn: eventsOn)
                }
            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                emitter.emitFailed(error.localizedDescription)
                throw CLIExitCode.formatError.exitCode
            }
        }
    }
}

/// The version 2 events of the four import commands, `import msa`, `import tree`, `import geneious`
/// and `import application-export`, written through the shared `CLIEventEmitter` and `printEventLine`.
///
/// Before version 2 each pair of commands had a private emitter and event names of its own, which
/// `CLIEventLegacyNames` still reads for an older CLI (decision V13). A warning is a `log` event at
/// level `warning`, so a reader counts them from the events. The completion names the bundle or
/// collection in `outputs`, the one list an app imports from, and holds one typed artifact that
/// describes it. A command with `--format json` prints its summary through `printHumanLine`, which
/// puts the text on standard error while events are on.
///
/// With events off nothing is written as an event, so a person would learn of neither a warning nor a
/// failure. The emitter then writes each warning as a `Warning: <message>` line and the failure as an
/// `Error: <message>` line on standard error, through `printStatusLine`. `--quiet` drops the warnings
/// and keeps the failure.
struct ImportCLIEventEmitter: Sendable {
    private let events: CLIEventEmitter
    private let eventsOn: Bool
    private let quiet: Bool

    init(enabled: Bool, quiet: Bool = false) {
        events = CLIEventEmitter(enabled: enabled) { printEventLine($0) }
        eventsOn = enabled
        self.quiet = quiet
    }

    /// The start line names the kind of what the command imports, such as `phylogenetic-tree`.
    func emitStart(kind: String) {
        events.emitStart("Started \(kind) import via lungfish-cli")
    }

    func emitProgress(_ fraction: Double, message: String) {
        events.emitProgress(fraction, message: message)
    }

    func emitWarning(_ message: String) {
        events.emitLog(.warning, message)
        if !eventsOn, !quiet {
            printStatusLine("Warning: \(message)")
        }
    }

    /// The completion of an import that made a bundle. The artifact is typed by the bundle kind and
    /// names the bundle's own provenance record when the importer wrote one.
    func emitComplete(bundle bundleURL: URL, kind: BundleKindID) {
        let record = bundleURL.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        events.emitComplete(
            outputs: [bundleURL.path],
            artifacts: [CLIEventArtifact(
                kind: kind.rawValue,
                path: bundleURL.path,
                role: "bundle",
                provenancePath: FileManager.default.fileExists(atPath: record.path) ? record.path : nil
            )]
        )
    }

    /// The completion of an import that made a collection folder, with the record it wrote.
    func emitComplete(collection collectionURL: URL, provenanceURL: URL) {
        events.emitComplete(
            outputs: [collectionURL.path],
            artifacts: [CLIEventArtifact(
                kind: "import-collection",
                path: collectionURL.path,
                role: "collection",
                provenancePath: provenanceURL.path
            )]
        )
    }

    func emitFailed(_ message: String) {
        events.emitFailed(message)
        if !eventsOn {
            printStatusLine("Error: \(message)")
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
