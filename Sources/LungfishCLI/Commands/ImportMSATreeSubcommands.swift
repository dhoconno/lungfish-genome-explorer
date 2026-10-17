import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os
import Synchronization

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

/// What a bundle import tells the rest of its command once the importer returned, in values that cross
/// a task boundary.
struct ImportedBundleSummary: Sendable {
    let warnings: [String]
    /// The lines the command prints after `Imported <path>`, such as `Rows: 12`.
    let summaryLines: [String]
}

/// The bundle a bundle import made and what the importer reported.
struct ImportedBundle: Sendable {
    let bundleURL: URL
    let summary: ImportedBundleSummary
}

/// What a collection import tells the rest of its command once the service returned.
struct ImportedCollectionSummary: Sendable {
    let collectionURL: URL
    let provenanceURL: URL
    let warnings: [String]
}

/// The bundle a run would publish, which the run sets once it has chosen the path, so a cancel can remove
/// what the run made. A path that existed before the importer ran is never removed.
final class ImportDestination: Sendable {
    private let state = OSAllocatedUnfairLock<(url: URL, existedBefore: Bool)?>(initialState: nil)

    func set(_ url: URL) {
        let existedBefore = FileManager.default.fileExists(atPath: url.path)
        state.withLock { $0 = (url, existedBefore) }
    }

    func removeIfCreatedByThisRun() {
        guard let chosen = state.withLock({ $0 }), !chosen.existedBefore else { return }
        try? FileManager.default.removeItem(at: chosen.url)
    }
}

/// The cancel that the four import commands share (Phase 2.11 lane A63, decision S7).
///
/// The app's Cancel sends the command SIGTERM and gives it `operationGrace` before SIGKILL. A command
/// that scopes ``run(_:)`` around its import turns the signal into a cancel of that import, records the
/// run as cancelled in the project, tells the row with a `failed` event that carries ``message`` and
/// exits 125 through ``finish(emitter:command:parameters:recordDirectory:startedAt:)``. A second SIGTERM
/// ends the process at once.
enum ImportCancellation {
    /// What the command's `failed` event and its record say once the import was cancelled.
    static let message = "Import cancelled. Nothing was published."

    /// Runs `work` as a task that SIGTERM cancels, and returns how it ended. A failure after the signal
    /// was caught is the cancel, whatever error it carries, since a tool that got the same signal can end
    /// first.
    static func run<Success: Sendable>(
        _ work: @escaping @Sendable () async throws -> Success
    ) async -> Result<Success, any Error> {
        let pendingCancel = PendingTaskCancel<Result<Success, any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let task = Task { () -> Result<Success, any Error> in
            do {
                return .success(try await work())
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || SIGTERMCancellation.signalCaught
                return .failure(cancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        return outcome
    }

    /// Runs the blocking `work` on a thread of its own and returns its result, or throws
    /// `CancellationError` as soon as the calling task is cancelled, whichever comes first. A cancel does
    /// not stop `work`, which may sit in a read that cannot be interrupted. The command exits right after
    /// the cancel, which ends the thread.
    static func blocking<Success: Sendable>(
        _ work: @escaping @Sendable () throws -> Success
    ) async throws -> Success {
        let handoff = BlockingHandoff<Success>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handoff.start(continuation)
                Thread.detachNewThread {
                    handoff.finish(Result { try work() })
                }
            }
        } onCancel: {
            handoff.cancel()
        }
    }

    /// The end of a cancelled import, which every command shares. It records the run as cancelled in
    /// `recordDirectory`, tells the row with the `failed` event and returns the exit code the command
    /// throws, 125. A record that cannot be written does not hide the cancel.
    static func finish(
        emitter: ImportCLIEventEmitter,
        command: String,
        parameters: [String: ParameterValue],
        recordDirectory: URL,
        startedAt: Date
    ) async -> ExitCode {
        _ = try? await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish \(command)",
            parameters: parameters,
            toolName: "lungfish \(command)",
            toolVersion: LungfishCLI.configuration.version,
            command: [CLICommandIdentity.executableName] + Array(CommandLine.arguments.dropFirst()),
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.exitCode.rawValue,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: message,
            status: .cancelled,
            outputDirectory: recordDirectory,
            writeFileSidecars: false
        )
        emitter.emitFailed(message)
        return CLIExitCode.cancelled.exitCode
    }
}

/// Hands the outcome of a blocking call to the task that awaits it, or the cancel of that task,
/// whichever comes first. The continuation resumes once.
private final class BlockingHandoff<Success: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Success, any Error>?
        var cancelRequested = false
        var resumed = false
    }

    private let state = Mutex(State())

    /// Stores the continuation, or resumes it at once when the cancel came first.
    func start(_ continuation: CheckedContinuation<Success, any Error>) {
        let cancelled = state.withLock { state -> Bool in
            if state.cancelRequested {
                state.resumed = true
                return true
            }
            state.continuation = continuation
            return false
        }
        if cancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Resumes the task with the result of the call, unless the cancel resumed it first.
    func finish(_ result: Result<Success, any Error>) {
        let continuation = takeContinuation(requestingCancel: false)
        continuation?.resume(with: result)
    }

    /// Resumes the task with a cancel, unless the call finished first.
    func cancel() {
        let continuation = takeContinuation(requestingCancel: true)
        continuation?.resume(throwing: CancellationError())
    }

    private func takeContinuation(requestingCancel: Bool) -> CheckedContinuation<Success, any Error>? {
        state.withLock { state in
            if requestingCancel {
                state.cancelRequested = true
            }
            guard !state.resumed, let continuation = state.continuation else { return nil }
            state.resumed = true
            state.continuation = nil
            return continuation
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
