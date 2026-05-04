import ArgumentParser
import Foundation
import LungfishIO

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
            let emitter = NativeBundleImportCLIEventEmitter(enabled: globalOptions.outputFormat == .json)
            emitter.emitStart(kind: "multiple-sequence-alignment", source: sourceURL.path)

            do {
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw ValidationError("Input file not found: \(sourceURL.path)")
                }
                try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

                let resolvedFormat: MultipleSequenceAlignmentBundle.SourceFormat?
                if let sourceFormat {
                    guard let parsed = MultipleSequenceAlignmentBundle.SourceFormat(rawValue: sourceFormat) else {
                        throw ValidationError("Unsupported source format '\(sourceFormat)'")
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
                emitter.emitComplete(bundle: bundleURL.path, warningCount: bundle.manifest.warnings.count)

                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    print("Imported \(bundleURL.path)")
                    print("Rows: \(bundle.manifest.rowCount)")
                    print("Columns: \(bundle.manifest.alignedLength)")
                }
            } catch {
                emitter.emitFailed(error.localizedDescription)
                throw ExitCode.failure
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
            let emitter = NativeBundleImportCLIEventEmitter(enabled: globalOptions.outputFormat == .json)
            emitter.emitStart(kind: "phylogenetic-tree", source: sourceURL.path)

            do {
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw ValidationError("Input file not found: \(sourceURL.path)")
                }
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
                emitter.emitComplete(bundle: bundleURL.path, warningCount: bundle.manifest.warnings.count)

                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    print("Imported \(bundleURL.path)")
                    print("Tips: \(bundle.manifest.tipCount)")
                    print("Internal nodes: \(bundle.manifest.internalNodeCount)")
                }
            } catch {
                emitter.emitFailed(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}

private final class NativeBundleImportCLIEventEmitter: @unchecked Sendable {
    private struct Event: Encodable {
        let event: String
        let kind: String?
        let source: String?
        let progress: Double?
        let message: String?
        let bundle: String?
        let warningCount: Int?
        let error: String?
    }

    private let enabled: Bool
    private let lock = NSLock()

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func emitStart(kind: String, source: String) {
        emit(Event(event: "nativeBundleImportStart", kind: kind, source: source, progress: nil, message: nil, bundle: nil, warningCount: nil, error: nil))
    }

    func emitProgress(_ progress: Double, message: String) {
        emit(Event(event: "nativeBundleImportProgress", kind: nil, source: nil, progress: max(0, min(1, progress)), message: message, bundle: nil, warningCount: nil, error: nil))
    }

    func emitWarning(_ message: String) {
        emit(Event(event: "nativeBundleImportWarning", kind: nil, source: nil, progress: nil, message: message, bundle: nil, warningCount: nil, error: nil))
    }

    func emitComplete(bundle: String, warningCount: Int) {
        emit(Event(event: "nativeBundleImportComplete", kind: nil, source: nil, progress: 1, message: nil, bundle: bundle, warningCount: warningCount, error: nil))
    }

    func emitFailed(_ error: String) {
        emit(Event(event: "nativeBundleImportFailed", kind: nil, source: nil, progress: nil, message: nil, bundle: nil, warningCount: nil, error: error))
    }

    private func emit(_ event: Event) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        print(line)
        fflush(stdout)
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
    var argv = ["lungfish", "import", command, sourceURL.path, "--project", projectURL.path, "--output", outputURL.path]
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
