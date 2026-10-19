import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct TreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Infer and transform phylogenetic tree bundles",
        subcommands: [
            InferSubcommand.self,
            ExportSubcommand.self,
            RerootSubcommand.self,
            ExtractSubtreeSubcommand.self,
            RelabelSubcommand.self,
        ]
    )

    struct InferSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "infer",
            abstract: "Infer phylogenetic trees from native alignment bundles",
            subcommands: [
                InferIQTreeSubcommand.self,
            ],
            defaultSubcommand: InferIQTreeSubcommand.self
        )
    }

    struct ExportSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export tree bundle payloads with provenance",
            subcommands: [
                SubtreeSubcommand.self,
            ]
        )

        /// Writes a selected subtree as Newick with its record beside it. The tree viewer's Export Subtree runs this
        /// leaf behind its Operations row (Phase 2.12 lane 12.35, ARCH ruling 1.1 row A15).
        ///
        /// The payload and the record go in one `writeAtomically` transaction with the CLI identity
        /// (`ARCH-export-shape.md:211`), so a failure or a cancel leaves neither. The record names the two bundle files
        /// the load reads, each with its digest (BIO-12.31-G3), and the options side A records. A SIGTERM exits 125.
        struct SubtreeSubcommand: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "subtree",
                abstract: "Export a selected .lungfishtree subtree as Newick with provenance"
            )

            @Argument(help: "Input .lungfishtree bundle")
            var bundlePath: String

            @Option(name: .customLong("node"), help: "Normalized tree node ID to export")
            var nodeID: String?

            @Option(name: .customLong("label"), help: "Unique node display label or raw label to export")
            var label: String?

            @Option(name: .customLong("output-format"), help: "Output format. Currently only newick is supported")
            var outputFormat: String = "newick"

            @Option(name: .customLong("output"), help: "Output Newick file path")
            var outputPath: String

            @Flag(name: .customLong("force"), help: "Overwrite an existing output file")
            var force: Bool = false

            @OptionGroup var globalOptions: GlobalOptions

            /// The invocation this parse stands for, which the record's argv comes from (ARCH 2).
            func invocation() -> ViewerExportInvocation {
                TreeSubtreeExport.invocation(
                    bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
                    nodeID: nodeID,
                    label: label,
                    outputFormat: outputFormat.lowercased(),
                    outputURL: URL(fileURLWithPath: outputPath),
                    force: force,
                    emitsEvents: globalOptions.outputFormat == .json
                )
            }

            func run() async throws {
                let command = self
                let outcome = await runCancellingOnSIGTERM {
                    try command.execute(emit: { printEventLine($0) })
                }
                switch outcome {
                case .success:
                    return
                case .failure(let error) where error is CancellationError:
                    throw CLIExitCode.cancelled.exitCode
                case .failure(let error):
                    throw error
                }
            }

            func executeForTesting(emit: @escaping (String) -> Void) throws {
                try execute(emit: emit)
            }

            private func execute(emit: @escaping (String) -> Void) throws {
                let runClock = ProvenanceRunClock()
                let emitter = CLIEventEmitter(
                    enabled: globalOptions.outputFormat == .json,
                    emit: emit
                )
                let invocation = invocation()
                let bundleURL = URL(fileURLWithPath: invocation.input, isDirectory: true)
                let outputURL = URL(fileURLWithPath: invocation.output)
                let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
                emitter.emitStart(message: "Starting tree subtree export.")

                do {
                    guard outputFormat.lowercased() == "newick" else {
                        throw ValidationError("Unsupported tree subtree export format '\(outputFormat)'. Supported formats: newick.")
                    }
                    guard (nodeID == nil) != (label == nil) else {
                        throw ValidationError("Pass exactly one of --node or --label for subtree export.")
                    }
                    try validateOutputNameLength(outputURL)
                    try validateOutputNameLength(provenanceURL)
                    guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                        throw ValidationError("Input tree bundle not found: \(bundleURL.path)")
                    }
                    if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                        throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
                    }

                    emitter.emitProgress(0.18, message: "Loading tree bundle.")
                    let bundle = try PhylogeneticTreeBundle.load(from: bundleURL)
                    let subtree: PhylogeneticTreeSubtreeExport
                    if let nodeID {
                        subtree = try bundle.subtreeExport(nodeID: nodeID)
                    } else if let label {
                        subtree = try bundle.subtreeExport(label: label)
                    } else {
                        throw ValidationError("Pass exactly one of --node or --label for subtree export.")
                    }

                    emitter.emitProgress(0.58, message: "Writing Newick subtree.")
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let payload = Data((subtree.newick + "\n").utf8)
                    try Task.checkCancellation()
                    try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
                        workflowName: TreeSubtreeExport.workflowName,
                        sourceURLs: TreeSubtreeExport.inputURLs(bundleURL: bundleURL),
                        outputURL: outputURL,
                        outputFormat: .text,
                        argv: invocation.canonicalArgv(),
                        explicitOptions: explicitOptions(bundleURL: bundleURL, outputURL: outputURL, subtree: subtree),
                        defaults: ["outputFormat": .string(outputFormat.lowercased())],
                        resolved: [
                            "descendantTipCount": .integer(subtree.descendantTipCount),
                            "outputByteCount": .integer(payload.count),
                        ],
                        runClock: runClock
                    )) { stagedURL in
                        try payload.write(to: stagedURL, options: .atomic)
                        emitter.emitProgress(0.82, message: "Writing subtree export provenance.")
                        try ViewerExportLeaf.checkpointAfterStaging()
                    }

                    emitter.emitComplete(output: outputURL.path)
                    if globalOptions.outputFormat != .json && !globalOptions.quiet {
                        emit("Exported subtree: \(outputURL.path)")
                        emit("Provenance: \(provenanceURL.path)")
                    }
                } catch is CancellationError {
                    emitter.emitFailed(ViewerExportLeaf.cancelledMessage)
                    throw CancellationError()
                } catch {
                    emitter.emitFailed(treeCommandErrorDescription(error))
                    throw error
                }
            }

            /// The options the record holds, the keys the tree viewer's export recorded (A against C, ARCH 1.7). The
            /// selected node's ID and label stand as the user's choice, as they did in the view.
            private func explicitOptions(
                bundleURL: URL,
                outputURL: URL,
                subtree: PhylogeneticTreeSubtreeExport
            ) -> [String: ParameterValue] {
                var options: [String: ParameterValue] = [
                    "sourceBundlePath": .file(bundleURL),
                    "outputPath": .file(outputURL),
                    "selectedNodeID": .string(subtree.selectedNodeID),
                    "selectedLabel": .string(subtree.selectedLabel),
                ]
                if let label {
                    options["label"] = .string(label)
                }
                if force {
                    options["force"] = .boolean(true)
                }
                return options
            }
        }
    }

    struct RerootSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "reroot",
            abstract: "Root a .lungfishtree bundle on the branch above a node (outgroup rooting) and write a new bundle with provenance"
        )

        @Option(name: .customLong("bundle"), help: "Input .lungfishtree bundle")
        var bundlePath: String

        @Option(name: .customLong("on"), help: "Tip label, internal node label, or normalized node ID of the outgroup; the new root splits the branch above it at its midpoint")
        var selector: String

        @Option(name: .customLong("output"), help: "Output .lungfishtree bundle path")
        var outputPath: String

        @OptionGroup var globalOptions: GlobalOptions

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try executeTreeTransform(
                bundlePath: bundlePath,
                outputPath: outputPath,
                toolName: "lungfish tree reroot",
                argv: canonicalArgv(),
                globalOptions: globalOptions,
                emit: emit
            ) { bundle, outputURL, provenance in
                try bundle.rerootedBundle(on: selector, to: outputURL, provenance: provenance)
            }
        }

        private func canonicalArgv() -> [String] {
            var argv = [CLICommandIdentity.executableName, "tree", "reroot", "--bundle", URL(fileURLWithPath: bundlePath).standardizedFileURL.path, "--on", selector, "--output", URL(fileURLWithPath: outputPath).standardizedFileURL.path]
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct ExtractSubtreeSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "extract-subtree",
            abstract: "Extract a selected clade as a new .lungfishtree bundle with provenance"
        )

        @Option(name: .customLong("bundle"), help: "Input .lungfishtree bundle")
        var bundlePath: String

        @Option(name: .customLong("node"), help: "Normalized node ID or unique node label to extract")
        var node: String

        @Option(name: .customLong("output"), help: "Output .lungfishtree bundle path")
        var outputPath: String

        @OptionGroup var globalOptions: GlobalOptions

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try executeTreeTransform(
                bundlePath: bundlePath,
                outputPath: outputPath,
                toolName: "lungfish tree extract-subtree",
                argv: canonicalArgv(),
                globalOptions: globalOptions,
                emit: emit
            ) { bundle, outputURL, provenance in
                try bundle.extractSubtreeBundle(nodeID: node, to: outputURL, provenance: provenance)
            }
        }

        private func canonicalArgv() -> [String] {
            var argv = [CLICommandIdentity.executableName, "tree", "extract-subtree", "--bundle", URL(fileURLWithPath: bundlePath).standardizedFileURL.path, "--node", node, "--output", URL(fileURLWithPath: outputPath).standardizedFileURL.path]
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct RelabelSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "relabel",
            abstract: "Relabel tree tips from bundle metadata.tsv and write a new bundle with provenance"
        )

        @Option(name: .customLong("bundle"), help: "Input .lungfishtree bundle")
        var bundlePath: String

        @Option(name: .customLong("column"), help: "metadata.tsv column to use for tip labels")
        var column: String

        @Option(name: .customLong("output"), help: "Output .lungfishtree bundle path")
        var outputPath: String

        @OptionGroup var globalOptions: GlobalOptions

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try executeTreeTransform(
                bundlePath: bundlePath,
                outputPath: outputPath,
                toolName: "lungfish tree relabel",
                argv: canonicalArgv(),
                globalOptions: globalOptions,
                emit: emit
            ) { bundle, outputURL, provenance in
                try bundle.relabeledBundle(column: column, to: outputURL, provenance: provenance)
            }
        }

        private func canonicalArgv() -> [String] {
            var argv = [CLICommandIdentity.executableName, "tree", "relabel", "--bundle", URL(fileURLWithPath: bundlePath).standardizedFileURL.path, "--column", column, "--output", URL(fileURLWithPath: outputPath).standardizedFileURL.path]
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }
}

// The conformances sit beside the structs, since `TreeTransformCommand` carries `Sendable` and a type
// declares that conformance in its own file.
extension TreeCommand.RerootSubcommand: TreeTransformCommand {}
extension TreeCommand.ExtractSubtreeSubcommand: TreeTransformCommand {}
extension TreeCommand.RelabelSubcommand: TreeTransformCommand {}

struct TreeProcessResult {
    let exitStatus: Int32
    let stdout: String
    let stderr: String
    let wallTimeSeconds: TimeInterval
}

struct TreeAlignedFASTARecord {
    let name: String
    let sequence: String
}

/// Runs one IQ-TREE process through `ToolProcess` and returns its status and output. ToolProcess reads
/// both pipes from launch, so a tool that writes more than the pipe buffer never blocks. Cancelling the
/// calling task stops the process tree with SIGTERM, and with SIGKILL after three seconds, so a cancelled
/// `tree infer iqtree` leaves no IQ-TREE behind (Phase 2.11 lane S61). The three seconds sit inside the
/// six the app gives the command to record its cancelled run.
func runProcess(
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL?
) async throws -> TreeProcessResult {
    let processClock = ProvenanceRunClock()
    let spec = ToolProcessSpec(
        executableURL: executableURL,
        arguments: arguments,
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: workingDirectory,
        terminationGracePeriod: .seconds(3),
        label: executableURL.lastPathComponent
    )
    do throws(ToolProcessError) {
        let result = try await ToolProcess.run(spec)
        return TreeProcessResult(
            exitStatus: result.status,
            stdout: result.stdoutText,
            stderr: result.stderrText,
            wallTimeSeconds: processClock.elapsed
        )
    } catch {
        if case .cancelled = error { throw CancellationError() }
        throw error
    }
}

func parseTreeAlignedFASTA(at url: URL) throws -> [TreeAlignedFASTARecord] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var records: [TreeAlignedFASTARecord] = []
    var currentName: String?
    var currentSequence = ""

    func flush() {
        guard let currentName else { return }
        records.append(TreeAlignedFASTARecord(name: currentName, sequence: currentSequence))
    }

    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false else { continue }
        if line.hasPrefix(">") {
            flush()
            currentName = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            currentSequence = ""
        } else {
            currentSequence += line
        }
    }
    flush()

    guard records.isEmpty == false else {
        throw ValidationError("MSA bundle does not contain aligned FASTA records.")
    }
    return records
}

func validateTreeAlignedRecords(_ records: [TreeAlignedFASTARecord]) throws {
    guard let length = records.first?.sequence.count, length > 0 else {
        throw ValidationError("Tree inference input alignment is empty.")
    }
    let mismatch = records.first { $0.sequence.count != length }
    if let mismatch {
        throw ValidationError("Selected MSA rows are not rectangular; row \(mismatch.name) differs in aligned length.")
    }
}

func writeTreeAlignedFASTA(records: [TreeAlignedFASTARecord], to url: URL) throws {
    let text = records
        .map { ">\($0.name)\n\($0.sequence)" }
        .joined(separator: "\n") + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func parseTreeColumnRanges(_ value: String?, alignedLength: Int) throws -> [ClosedRange<Int>] {
    guard let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        return []
    }
    return try value.split(separator: ",").map { token in
        let trimmed = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
        let startText = parts.first ?? ""
        guard let oneBasedStart = Int(startText), oneBasedStart >= 1 else {
            throw ValidationError("Invalid aligned column range '\(trimmed)'.")
        }
        let oneBasedEnd: Int
        if parts.count == 2 {
            guard let parsedEnd = Int(parts[1]), parsedEnd >= oneBasedStart else {
                throw ValidationError("Invalid aligned column range '\(trimmed)'.")
            }
            oneBasedEnd = parsedEnd
        } else {
            oneBasedEnd = oneBasedStart
        }
        guard oneBasedEnd <= alignedLength else {
            throw ValidationError("Aligned column range '\(trimmed)' exceeds alignment length \(alignedLength).")
        }
        return (oneBasedStart - 1)...(oneBasedEnd - 1)
    }
}

func parseIQTreeVersion(stdout: String, stderr: String) -> String {
    let text = "\(stdout)\n\(stderr)"
    if let range = text.range(of: #"version\s+([0-9][A-Za-z0-9._+-]*)"#, options: [.regularExpression, .caseInsensitive]) {
        let match = String(text[range])
        return match.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "unknown"
    }
    return "unknown"
}

func copyIQTreeArtifacts(from stagingURL: URL, to bundleURL: URL) throws -> [String] {
    let artifactDir = bundleURL.appendingPathComponent("artifacts/iqtree", isDirectory: true)
    try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
    var relativePaths: [String] = []
    for fileName in ["input.aligned.fasta", "run.treefile", "run.iqtree", "run.log", "tip-map.tsv"] {
        let sourceURL = stagingURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
        let relativePath = "artifacts/iqtree/\(fileName)"
        let destinationURL = bundleURL.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        relativePaths.append(relativePath)
    }
    return relativePaths
}

func rewriteManifestAndProvenance(
    bundleURL: URL,
    msaBundleURL: URL,
    artifactPaths: [String],
    workflowName: String,
    wrapperToolName: String,
    wrapperToolVersion: String,
    externalToolName: String,
    externalToolVersion: String,
    argv: [String],
    executableURL: URL,
    externalArguments: [String],
    externalArgumentPathRewrites: [String: String],
    model: String,
    sequenceType: String,
    bootstrap: Int?,
    alrt: Int?,
    seed: Int?,
    threads: String,
    safeMode: Bool,
    keepIdenticalSequences: Bool,
    advancedArguments: [String],
    rowCount: Int,
    alignedLength: Int,
    selectedRowCount: Int,
    selectedAlignedLength: Int,
    rows: String?,
    columns: String?,
    runOptions: [String: String],
    warnings: [String],
    exitStatus: Int32,
    stdout: String,
    stderr: String,
    externalWallTimeSeconds: TimeInterval,
    wallTimeSeconds: TimeInterval
) throws {
    let manifestURL = bundleURL.appendingPathComponent("manifest.json")
    let allPayloadPaths = try regularFileRelativePaths(in: bundleURL)
        .filter { $0 != ".lungfish-provenance.json" }
        .sorted()
    let checksums = try checksumMap(paths: allPayloadPaths, bundleURL: bundleURL)
    let fileSizes = try fileSizeMap(paths: allPayloadPaths, bundleURL: bundleURL)

    var manifest = try jsonObject(at: manifestURL)
    var capabilities = manifest["capabilities"] as? [String] ?? []
    capabilities.append(contentsOf: ["iqtree-inference", "external-tool-artifacts"])
    manifest["capabilities"] = Array(Set(capabilities)).sorted()
    manifest["checksums"] = checksums
    manifest["fileSizes"] = fileSizes
    if warnings.isEmpty == false {
        manifest["warnings"] = (manifest["warnings"] as? [String] ?? []) + warnings
    }
    try writeJSONObject(manifest, to: manifestURL)

    let updatedPayloadPaths = try regularFileRelativePaths(in: bundleURL)
        .filter { $0 != ".lungfish-provenance.json" }
        .sorted()
    let updatedChecksums = try checksumMap(paths: updatedPayloadPaths, bundleURL: bundleURL)
    let updatedFileSizes = try fileSizeMap(paths: updatedPayloadPaths, bundleURL: bundleURL)
    var options: [String: String] = [
        "model": model,
        "sequenceType": sequenceType,
        "threads": threads,
        "safeMode": String(safeMode),
        "keepIdenticalSequences": String(keepIdenticalSequences),
        "rowCount": String(rowCount),
        "alignedLength": String(alignedLength),
        "selectedRowCount": String(selectedRowCount),
        "selectedAlignedLength": String(selectedAlignedLength),
        "sourceFormat": "aligned-fasta",
        "artifactPaths": artifactPaths.joined(separator: ","),
    ]
    if let bootstrap {
        options["bootstrap"] = String(bootstrap)
    }
    if let alrt {
        options["alrt"] = String(alrt)
    }
    if let seed {
        options["seed"] = String(seed)
    }
    if advancedArguments.isEmpty == false {
        let joined = AdvancedCommandLineOptions.join(advancedArguments)
        options["advancedArguments"] = joined
        options["extraArgs"] = joined
    }
    if let rows {
        options["rows"] = rows
    }
    if let columns {
        options["columns"] = columns
    }
    options.merge(runOptions) { _, new in new }

    let runtime = runtimeIdentityDictionary()

    let storedAlignmentURL = bundleURL.appendingPathComponent("artifacts/iqtree/input.aligned.fasta")
    let storedAlignmentInputs: [[String: Any]]
    if FileManager.default.fileExists(atPath: storedAlignmentURL.path) {
        storedAlignmentInputs = [try fileRecord(path: storedAlignmentURL.path, url: storedAlignmentURL)]
    } else {
        storedAlignmentInputs = []
    }
    let rehydratedExternalArguments = externalArguments.map { argument in
        externalArgumentPathRewrites[argument] ?? argument
    }
    let rehydratedExternalArgv = [executableURL.path] + rehydratedExternalArguments

    let provenance: [String: Any] = [
        "schemaVersion": 1,
        "workflowName": workflowName,
        "toolName": wrapperToolName,
        "toolVersion": wrapperToolVersion,
        "argv": argv,
        "command": shellCommand(argv),
        "reproducibleCommand": shellCommand(argv),
        "externalTool": [
            "toolName": externalToolName,
            "toolVersion": externalToolVersion,
            "executablePath": executableURL.path,
            "executable": executableURL.path,
            "argv": rehydratedExternalArgv,
            "arguments": rehydratedExternalArguments,
            "command": shellCommand(rehydratedExternalArgv),
            "reproducibleCommand": shellCommand(rehydratedExternalArgv),
            "exitStatus": Int(exitStatus),
            "wallTimeSeconds": externalWallTimeSeconds,
            "stdout": stdout,
            "stderr": stderr,
            "runtime": runtime,
        ],
        "options": options,
        "runtime": runtime,
        "runtimeIdentity": runtime,
        "input": try fileRecord(path: msaBundleURL.path, url: msaBundleURL),
        "inputs": [try fileRecord(path: msaBundleURL.path, url: msaBundleURL)] + storedAlignmentInputs,
        "output": [
            "path": bundleURL.path,
            "sha256": bundleDigest(checksums: updatedChecksums),
            "fileSizeBytes": try directorySize(at: bundleURL),
        ],
        "checksums": updatedChecksums,
        "fileSizes": updatedFileSizes,
        "exitStatus": Int(exitStatus),
        "status": NativeProvenanceRecordFacts.completedStatus,
        "wallTimeSeconds": wallTimeSeconds,
        "warnings": warnings,
        "stderr": stderr,
    ]
    try writeJSONObject(provenance, to: bundleURL.appendingPathComponent(".lungfish-provenance.json"))
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

struct TreeCommandRuntimeError: Error, LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
    var description: String { message }
}

func treeCommandErrorDescription(_ error: Error) -> String {
    if let localizedError = error as? LocalizedError,
       let errorDescription = localizedError.errorDescription,
       errorDescription.isEmpty == false {
        return errorDescription
    }
    let description = String(describing: error)
    return description.isEmpty ? error.localizedDescription : description
}

private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

/// No process ID, and null for the conda and container values the shell that started LGE set (2.7 B6).
private func runtimeIdentityDictionary() -> [String: Any] {
    [
        "executablePath": NativeProvenanceRecordFacts.executablePath, "swiftRuntime": "swift",
        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        "condaEnvironment": NSNull(), "containerImage": NSNull(),
    ]
}

private func regularFileRelativePaths(in bundleURL: URL) throws -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: bundleURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else {
        return []
    }
    var paths: [String] = []
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        // Physical paths: under /tmp the enumerator yields /private/tmp URLs.
        guard let relative = CanonicalFilePath.relativePath(of: fileURL, within: bundleURL) else { continue }
        paths.append(relative)
    }
    return paths
}

private func checksumMap(paths: [String], bundleURL: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for path in paths {
        result[path] = try sha256(at: bundleURL.appendingPathComponent(path))
    }
    return result
}

private func fileSizeMap(paths: [String], bundleURL: URL) throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    for path in paths {
        result[path] = try fileSize(at: bundleURL.appendingPathComponent(path))
    }
    return result
}

private func fileRecord(path: String, url: URL) throws -> [String: Any] {
    let size = isDirectory(url) ? try directorySize(at: url) : try fileSize(at: url)
    return [
        "path": path,
        "sha256": try sha256(at: url),
        "fileSizeBytes": size,
    ]
}

private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
}

private func sha256(at url: URL) throws -> String {
    if isDirectory(url) {
        let paths = try regularFileRelativePaths(in: url).sorted()
        let checksums = try checksumMap(paths: paths, bundleURL: url)
        return bundleDigest(checksums: checksums)
    }
    return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

private func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
}

private func directorySize(at url: URL) throws -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: []
    ) else {
        return 0
    }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            total += Int64(values.fileSize ?? 0)
        }
    }
    return total
}

private func bundleDigest(checksums: [String: String]) -> String {
    let joined = checksums.keys.sorted().map { "\($0)=\(checksums[$0] ?? "")" }.joined(separator: "\n")
    return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
}

// Module-visible name for the IQ-TREE subcommand kept in its own file. The short name stays
// private because MSACommand.swift and ImportMSATreeSubcommands.swift declare their own.
func treeCLIShellCommand(_ argv: [String]) -> String { shellCommand(argv) }

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
