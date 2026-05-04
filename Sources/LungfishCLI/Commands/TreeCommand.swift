import ArgumentParser
import CryptoKit
import Foundation
import LungfishIO
import LungfishWorkflow

struct TreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Infer and transform phylogenetic tree bundles",
        subcommands: [
            InferSubcommand.self,
            ExportSubcommand.self,
        ]
    )

    struct InferSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "infer",
            abstract: "Infer phylogenetic trees from native alignment bundles",
            subcommands: [
                InferIQTreeSubcommand.self,
            ]
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

        struct SubtreeSubcommand: ParsableCommand {
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

            func run() throws {
                try execute(emit: { print($0) })
            }

            func executeForTesting(emit: @escaping (String) -> Void) throws {
                try execute(emit: emit)
            }

            private func execute(emit: @escaping (String) -> Void) throws {
                let startedAt = Date()
                let emitter = TreeExportCLIEventEmitter(
                    enabled: globalOptions.outputFormat == .json,
                    emit: emit
                )
                let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
                let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
                let provenanceURL = outputURL.appendingPathExtension("lungfish-provenance.json")
                var didWriteOutput = false
                emitter.emitStart(message: "Starting tree subtree export.")

                do {
                    guard outputFormat.lowercased() == "newick" else {
                        throw ValidationError("Unsupported tree subtree export format '\(outputFormat)'. Supported formats: newick.")
                    }
                    guard (nodeID == nil) != (label == nil) else {
                        throw ValidationError("Pass exactly one of --node or --label for subtree export.")
                    }
                    guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                        throw ValidationError("Input tree bundle not found: \(bundleURL.path)")
                    }
                    if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                        throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
                    }
                    if FileManager.default.fileExists(atPath: outputURL.path), force {
                        try FileManager.default.removeItem(at: outputURL)
                    }

                    emitter.emitProgress(0.18, message: "Loading tree bundle.")
                    let bundle = try PhylogeneticTreeBundle.load(from: bundleURL)
                    let subtree: PhylogeneticTreeSubtreeExport
                    let selectionMode: String
                    if let nodeID {
                        subtree = try bundle.subtreeExport(nodeID: nodeID)
                        selectionMode = "node"
                    } else if let label {
                        subtree = try bundle.subtreeExport(label: label)
                        selectionMode = "label"
                    } else {
                        throw ValidationError("Pass exactly one of --node or --label for subtree export.")
                    }

                    emitter.emitProgress(0.58, message: "Writing Newick subtree.")
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data((subtree.newick + "\n").utf8).write(to: outputURL, options: .atomic)
                    didWriteOutput = true

                    emitter.emitProgress(0.82, message: "Writing subtree export provenance.")
                    let argv = canonicalArgv(bundleURL: bundleURL, outputURL: outputURL)
                    let provenance = try subtreeExportProvenance(
                        bundleURL: bundleURL,
                        outputURL: outputURL,
                        argv: argv,
                        selectionMode: selectionMode,
                        subtree: subtree,
                        wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
                    )
                    try writeJSONObject(provenance, to: provenanceURL)

                    emitter.emitComplete(output: outputURL.path)
                    if globalOptions.outputFormat != .json && !globalOptions.quiet {
                        emit("Exported subtree: \(outputURL.path)")
                        emit("Provenance: \(provenanceURL.path)")
                    }
                } catch {
                    emitter.emitFailed(treeCommandErrorDescription(error))
                    if didWriteOutput {
                        try? FileManager.default.removeItem(at: outputURL)
                        try? FileManager.default.removeItem(at: provenanceURL)
                    }
                    throw error
                }
            }

            private func canonicalArgv(bundleURL: URL, outputURL: URL) -> [String] {
                var argv = [
                    "lungfish",
                    "tree",
                    "export",
                    "subtree",
                    bundleURL.path,
                    "--output-format",
                    outputFormat.lowercased(),
                    "--output",
                    outputURL.path,
                ]
                if let nodeID {
                    argv += ["--node", nodeID]
                }
                if let label {
                    argv += ["--label", label]
                }
                if force {
                    argv.append("--force")
                }
                if globalOptions.outputFormat == .json {
                    argv += ["--format", "json"]
                }
                return argv
            }

            private func subtreeExportProvenance(
                bundleURL: URL,
                outputURL: URL,
                argv: [String],
                selectionMode: String,
                subtree: PhylogeneticTreeSubtreeExport,
                wallTimeSeconds: TimeInterval
            ) throws -> [String: Any] {
                var options: [String: Any] = [
                    "outputFormat": outputFormat.lowercased(),
                    "selectionMode": selectionMode,
                    "selectedNodeID": subtree.selectedNodeID,
                    "selectedLabel": subtree.selectedLabel,
                    "selectedTipCount": subtree.descendantTipCount,
                    "force": force,
                ]
                if let nodeID {
                    options["node"] = nodeID
                }
                if let label {
                    options["label"] = label
                }

                let primaryTreeURL = bundleURL.appendingPathComponent("tree/primary.nwk")
                return [
                    "schemaVersion": 1,
                    "workflowName": "phylogenetic-tree-subtree-export",
                    "actionID": "tree.export.subtree",
                    "toolName": "lungfish tree export subtree",
                    "toolVersion": PhylogeneticTreeBundleImporter.toolVersion,
                    "argv": argv,
                    "command": shellCommand(argv),
                    "reproducibleCommand": shellCommand(argv),
                    "options": options,
                    "runtime": runtimeIdentityDictionary(),
                    "runtimeIdentity": runtimeIdentityDictionary(),
                    "inputBundle": try fileRecord(path: bundleURL.path, url: bundleURL),
                    "inputTreeFile": try fileRecord(path: primaryTreeURL.path, url: primaryTreeURL),
                    "outputFile": try fileRecord(path: outputURL.path, url: outputURL),
                    "exitStatus": 0,
                    "wallTimeSeconds": wallTimeSeconds,
                    "warnings": [],
                    "stderr": NSNull(),
                    "createdAt": ISO8601DateFormatter().string(from: Date()),
                ]
            }
        }
    }

    struct InferIQTreeSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "iqtree",
            abstract: "Infer a maximum-likelihood tree from a .lungfishmsa bundle using IQ-TREE"
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var msaBundlePath: String

        @Option(name: .customLong("project"), help: "Lungfish project directory for project-local staging")
        var projectPath: String

        @Option(name: .customLong("output"), help: "Output .lungfishtree bundle path")
        var outputPath: String

        @Option(name: .customLong("rows"), help: "Optional comma-separated row IDs or display names")
        var rows: String?

        @Option(name: .customLong("columns"), help: "Optional 1-based aligned column ranges, e.g. 10-40,55")
        var columns: String?

        @Option(name: .customLong("name"), help: "Output tree bundle name")
        var name: String?

        @Option(name: .customLong("model"), help: "IQ-TREE model string")
        var model: String = "MFP"

        @Option(name: .customLong("sequence-type"), help: "IQ-TREE sequence type: auto, DNA, AA, CODON, BIN, MORPH, NT2AA")
        var sequenceType: String = "auto"

        @Option(name: .customLong("bootstrap"), help: "Ultrafast bootstrap replicate count")
        var bootstrap: Int?

        @Option(name: .customLong("alrt"), help: "SH-aLRT replicate count")
        var alrt: Int?

        @Option(name: .customLong("seed"), help: "Random seed")
        var seed: Int = 1

        @Flag(name: .customLong("safe"), help: "Enable IQ-TREE safe numerical mode")
        var safeMode: Bool = false

        @Flag(name: .customLong("keep-identical"), help: "Keep identical sequences in the IQ-TREE analysis")
        var keepIdenticalSequences: Bool = false

        @Option(
            name: .customLong("extra-iqtree-options"),
            parsing: .unconditional,
            help: "Additional IQ-TREE options, written exactly as they should be passed to IQ-TREE"
        )
        var extraIQTreeOptions: String = ""

        @Option(name: .customLong("iqtree-path"), help: "Override path to iqtree3 executable")
        var iqtreePath: String?

        @Flag(name: .customLong("force"), help: "Overwrite an existing output bundle")
        var force: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            try await execute(emit: { print($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            try await execute(emit: emit)
        }

        private func execute(emit: @escaping (String) -> Void) async throws {
            let startedAt = Date()
            let emitter = TreeInferenceCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let workflowName = "phylogenetic-tree-infer-iqtree"
            let wrapperToolName = "lungfish tree infer iqtree"
            let wrapperToolVersion = PhylogeneticTreeBundleImporter.toolVersion
            let externalToolName = "iqtree3"
            let msaBundleURL = URL(fileURLWithPath: msaBundlePath).standardizedFileURL
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(message: "Starting IQ-TREE inference.")

            let tempRoot = projectURL.appendingPathComponent(".tmp", isDirectory: true)
            let stagingURL = tempRoot.appendingPathComponent("lungfish-tree-iqtree-\(UUID().uuidString)", isDirectory: true)
            do {
                guard FileManager.default.fileExists(atPath: msaBundleURL.path) else {
                    throw ValidationError("Input MSA bundle not found: \(msaBundleURL.path)")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output tree bundle already exists: \(outputURL.path). Use --force to overwrite.")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force {
                    try FileManager.default.removeItem(at: outputURL)
                }
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                defer {
                    try? FileManager.default.removeItem(at: stagingURL)
                    try? FileManager.default.removeItem(at: tempRoot)
                }

                emitter.emitProgress(0.12, message: "Preparing aligned FASTA input.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: msaBundleURL)
                let stagedAlignmentURL = stagingURL.appendingPathComponent("input.aligned.fasta")
                let selectedRecords = try selectTreeAlignedRecords(
                    records: parseTreeAlignedFASTA(at: msaBundleURL.appendingPathComponent("alignment/primary.aligned.fasta")),
                    bundle: bundle,
                    rows: rows,
                    columns: columns
                )
                let selectedAlignedLength = selectedRecords.first?.sequence.count ?? 0
                guard selectedAlignedLength > 0 else {
                    throw ValidationError("Tree inference selection produced zero aligned columns.")
                }
                try validateTreeAlignedRecords(selectedRecords)
                try writeTreeAlignedFASTA(records: selectedRecords, to: stagedAlignmentURL)

                emitter.emitProgress(0.20, message: "Resolving IQ-TREE executable.")
                let executableURL = try resolveIQTreeExecutable()
                let versionResult = try runProcess(executableURL: executableURL, arguments: ["--version"], workingDirectory: nil)
                let toolVersion = parseIQTreeVersion(stdout: versionResult.stdout, stderr: versionResult.stderr)
                let iqtreeThreads = globalOptions.threads.map(String.init) ?? "AUTO"

                let prefixURL = stagingURL.appendingPathComponent("run")
                var iqtreeArguments = [
                    "-s", stagedAlignmentURL.path,
                    "-m", model,
                    "--prefix", prefixURL.path,
                    "-nt", iqtreeThreads,
                ]
                let normalizedSequenceType = try parsedSequenceType()
                if let normalizedSequenceType {
                    iqtreeArguments += ["-st", normalizedSequenceType]
                }
                if let bootstrap {
                    guard bootstrap > 0 else {
                        throw ValidationError("--bootstrap must be greater than 0.")
                    }
                    iqtreeArguments += ["-B", String(bootstrap)]
                }
                if let alrt {
                    guard alrt > 0 else {
                        throw ValidationError("--alrt must be greater than 0.")
                    }
                    iqtreeArguments += ["-alrt", String(alrt)]
                }
                iqtreeArguments += ["--seed", String(seed)]
                if safeMode {
                    iqtreeArguments.append("-safe")
                }
                if keepIdenticalSequences {
                    iqtreeArguments.append("-keep-ident")
                }
                let advancedArguments = try parsedAdvancedArguments()
                iqtreeArguments += advancedArguments

                emitter.emitProgress(0.34, message: "Running IQ-TREE.")
                let runResult = try runProcess(
                    executableURL: executableURL,
                    arguments: iqtreeArguments,
                    workingDirectory: stagingURL
                )
                guard runResult.exitStatus == 0 else {
                    let stderr = runResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = stderr.isEmpty ? "" : ": \(stderr)"
                    throw TreeCommandRuntimeError("IQ-TREE failed with exit status \(runResult.exitStatus)\(suffix)")
                }

                let treefileURL = stagingURL.appendingPathComponent("run.treefile")
                guard FileManager.default.fileExists(atPath: treefileURL.path) else {
                    throw ValidationError("IQ-TREE did not produce \(treefileURL.lastPathComponent).")
                }

                let argv = canonicalArgv(msaBundleURL: msaBundleURL, projectURL: projectURL, outputURL: outputURL)
                emitter.emitProgress(0.72, message: "Creating native .lungfishtree bundle.")
                _ = try PhylogeneticTreeBundleImporter.importTree(
                    from: treefileURL,
                    to: outputURL,
                    options: .init(
                        name: name ?? outputURL.deletingPathExtension().lastPathComponent,
                        argv: argv,
                        command: shellCommand(argv),
                        sourceFormat: "newick",
                        toolName: wrapperToolName,
                        toolVersion: wrapperToolVersion
                    )
                )

                emitter.emitProgress(0.84, message: "Preserving IQ-TREE artifacts.")
                let artifactPaths = try copyIQTreeArtifacts(from: stagingURL, to: outputURL)
                let externalArgumentPathRewrites = [
                    stagedAlignmentURL.path: outputURL.appendingPathComponent("artifacts/iqtree/input.aligned.fasta").path,
                    prefixURL.path: outputURL.appendingPathComponent("artifacts/iqtree/run").path,
                ]
                try rewriteManifestAndProvenance(
                    bundleURL: outputURL,
                    msaBundleURL: msaBundleURL,
                    artifactPaths: artifactPaths,
                    workflowName: workflowName,
                    wrapperToolName: wrapperToolName,
                    wrapperToolVersion: wrapperToolVersion,
                    externalToolName: externalToolName,
                    externalToolVersion: toolVersion,
                    argv: argv,
                    executableURL: executableURL,
                    externalArguments: iqtreeArguments,
                    externalArgumentPathRewrites: externalArgumentPathRewrites,
                    model: model,
                    sequenceType: normalizedSequenceType ?? "auto",
                    bootstrap: bootstrap,
                    alrt: alrt,
                    seed: seed,
                    threads: iqtreeThreads,
                    safeMode: safeMode,
                    keepIdenticalSequences: keepIdenticalSequences,
                    advancedArguments: advancedArguments,
                    rowCount: bundle.manifest.rowCount,
                    alignedLength: bundle.manifest.alignedLength,
                    selectedRowCount: selectedRecords.count,
                    selectedAlignedLength: selectedAlignedLength,
                    rows: rows,
                    columns: columns,
                    exitStatus: runResult.exitStatus,
                    stdout: runResult.stdout,
                    stderr: runResult.stderr,
                    externalWallTimeSeconds: runResult.wallTimeSeconds,
                    wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
                )

                emitter.emitComplete(output: outputURL.path)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    print("Inferred tree: \(outputURL.path)")
                }
            } catch {
                emitter.emitFailed(treeCommandErrorDescription(error))
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: stagingURL)
                try? FileManager.default.removeItem(at: tempRoot)
                throw error
            }
        }

        private func canonicalArgv(msaBundleURL: URL, projectURL: URL, outputURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "tree",
                "infer",
                "iqtree",
                msaBundleURL.path,
                "--project", projectURL.path,
                "--output", outputURL.path,
                "--model", model,
            ]
            if sequenceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
               sequenceType.lowercased() != "auto" {
                argv += ["--sequence-type", sequenceType]
            }
            if let rows {
                argv += ["--rows", rows]
            }
            if let columns {
                argv += ["--columns", columns]
            }
            if let threads = globalOptions.threads {
                argv += ["--threads", String(threads)]
            }
            if let name {
                argv += ["--name", name]
            }
            if let bootstrap {
                argv += ["--bootstrap", String(bootstrap)]
            }
            if let alrt {
                argv += ["--alrt", String(alrt)]
            }
            argv += ["--seed", String(seed)]
            if safeMode {
                argv.append("--safe")
            }
            if keepIdenticalSequences {
                argv.append("--keep-identical")
            }
            if extraIQTreeOptions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                argv += ["--extra-iqtree-options", extraIQTreeOptions]
            }
            if let iqtreePath {
                argv += ["--iqtree-path", iqtreePath]
            }
            if force {
                argv.append("--force")
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }

        static func resolveIQTreeExecutableForTesting(
            iqtreePath: String?,
            environment: [String: String],
            managedHomeDirectory: URL
        ) throws -> URL {
            try resolveIQTreeExecutable(
                iqtreePath: iqtreePath,
                environment: environment,
                managedHomeDirectory: managedHomeDirectory
            )
        }

        private static func resolveIQTreeExecutable(
            iqtreePath: String?,
            environment: [String: String],
            managedHomeDirectory: URL
        ) throws -> URL {
            if let iqtreePath {
                let url = URL(fileURLWithPath: iqtreePath).standardizedFileURL
                guard FileManager.default.isExecutableFile(atPath: url.path) else {
                    throw ValidationError("IQ-TREE executable is not executable: \(url.path)")
                }
                return url
            }
            if let envPath = environment["LUNGFISH_IQTREE_PATH"], !envPath.isEmpty {
                let url = URL(fileURLWithPath: envPath).standardizedFileURL
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
            for executable in ["iqtree3", "iqtree"] {
                let managedURL = CoreToolLocator.managedExecutableURL(
                    environment: "iqtree",
                    executableName: executable,
                    homeDirectory: managedHomeDirectory
                )
                if FileManager.default.isExecutableFile(atPath: managedURL.path) {
                    return managedURL.standardizedFileURL
                }
            }
            let pathEntries = (environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
            for executable in ["iqtree3", "iqtree"] {
                for entry in pathEntries {
                    let url = URL(fileURLWithPath: entry, isDirectory: true).appendingPathComponent(executable)
                    if FileManager.default.isExecutableFile(atPath: url.path) {
                        return url
                    }
                }
            }
            throw ValidationError("IQ-TREE executable not found. Install the Phylogenetics plugin pack or pass --iqtree-path.")
        }

        private func resolveIQTreeExecutable() throws -> URL {
            try Self.resolveIQTreeExecutable(
                iqtreePath: iqtreePath,
                environment: ProcessInfo.processInfo.environment,
                managedHomeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        }

        private func parsedSequenceType() throws -> String? {
            let trimmed = sequenceType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed.lowercased() != "auto" else {
                return nil
            }
            let allowed = ["DNA", "AA", "CODON", "BIN", "MORPH", "NT2AA"]
            let uppercased = trimmed.uppercased()
            guard allowed.contains(uppercased) else {
                throw ValidationError("Unsupported IQ-TREE sequence type '\(trimmed)'. Supported values: auto, DNA, AA, CODON, BIN, MORPH, NT2AA.")
            }
            return uppercased
        }

        private func parsedAdvancedArguments() throws -> [String] {
            try AdvancedCommandLineOptions.parse(extraIQTreeOptions)
        }
    }
}

private final class TreeInferenceCLIEventEmitter: @unchecked Sendable {
    private struct Event: Encodable {
        let event: String
        let progress: Double?
        let message: String?
        let output: String?
        let error: String?
    }

    private let enabled: Bool
    private let emitLine: (String) -> Void
    private let lock = NSLock()

    init(enabled: Bool, emit: @escaping (String) -> Void) {
        self.enabled = enabled
        self.emitLine = emit
    }

    func emitStart(message: String) {
        emit(Event(event: "treeInferenceStart", progress: 0, message: message, output: nil, error: nil))
    }

    func emitProgress(_ progress: Double, message: String) {
        emit(Event(event: "treeInferenceProgress", progress: max(0, min(1, progress)), message: message, output: nil, error: nil))
    }

    func emitComplete(output: String) {
        emit(Event(event: "treeInferenceComplete", progress: 1, message: nil, output: output, error: nil))
    }

    func emitFailed(_ message: String) {
        emit(Event(event: "treeInferenceFailed", progress: nil, message: nil, output: nil, error: message))
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
        emitLine(line)
    }
}

private final class TreeExportCLIEventEmitter: @unchecked Sendable {
    private struct Event: Encodable {
        let event: String
        let progress: Double?
        let message: String?
        let output: String?
        let error: String?
    }

    private let enabled: Bool
    private let emitLine: (String) -> Void
    private let lock = NSLock()

    init(enabled: Bool, emit: @escaping (String) -> Void) {
        self.enabled = enabled
        self.emitLine = emit
    }

    func emitStart(message: String) {
        emit(Event(event: "treeExportStart", progress: 0, message: message, output: nil, error: nil))
    }

    func emitProgress(_ progress: Double, message: String) {
        emit(Event(event: "treeExportProgress", progress: max(0, min(1, progress)), message: message, output: nil, error: nil))
    }

    func emitComplete(output: String) {
        emit(Event(event: "treeExportComplete", progress: 1, message: nil, output: output, error: nil))
    }

    func emitFailed(_ message: String) {
        emit(Event(event: "treeExportFailed", progress: nil, message: nil, output: nil, error: message))
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
        emitLine(line)
    }
}

private struct TreeProcessResult {
    let exitStatus: Int32
    let stdout: String
    let stderr: String
    let wallTimeSeconds: TimeInterval
}

private struct TreeAlignedFASTARecord {
    let name: String
    let sequence: String
}

private func runProcess(
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL?
) throws -> TreeProcessResult {
    let startedAt = Date()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return TreeProcessResult(
        exitStatus: process.terminationStatus,
        stdout: stdout,
        stderr: stderr,
        wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
    )
}

private func parseTreeAlignedFASTA(at url: URL) throws -> [TreeAlignedFASTARecord] {
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

private func selectTreeAlignedRecords(
    records: [TreeAlignedFASTARecord],
    bundle: MultipleSequenceAlignmentBundle,
    rows: String?,
    columns: String?
) throws -> [TreeAlignedFASTARecord] {
    let rowNames: Set<String>?
    if let rows, rows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        rowNames = Set(rows.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
    } else {
        rowNames = nil
    }

    var rowIDsByDisplayName: [String: String] = [:]
    var sourceNamesByDisplayName: [String: String] = [:]
    for row in bundle.rows {
        rowIDsByDisplayName[row.displayName] = row.id
        sourceNamesByDisplayName[row.displayName] = row.sourceName
    }

    var selected = records.filter { record in
        guard let rowNames else { return true }
        return rowNames.contains(record.name)
            || rowNames.contains(rowIDsByDisplayName[record.name] ?? "")
            || rowNames.contains(sourceNamesByDisplayName[record.name] ?? "")
    }
    guard selected.isEmpty == false else {
        throw ValidationError("No MSA rows matched --rows selection.")
    }

    let columnRanges = try parseTreeColumnRanges(columns, alignedLength: bundle.manifest.alignedLength)
    if columnRanges.isEmpty == false {
        selected = selected.map { record in
            let characters = Array(record.sequence)
            let subset = columnRanges.flatMap { range in
                range.map { characters[$0] }
            }
            return TreeAlignedFASTARecord(name: record.name, sequence: String(subset))
        }
    }
    return selected
}

private func validateTreeAlignedRecords(_ records: [TreeAlignedFASTARecord]) throws {
    guard let length = records.first?.sequence.count, length > 0 else {
        throw ValidationError("Tree inference input alignment is empty.")
    }
    let mismatch = records.first { $0.sequence.count != length }
    if let mismatch {
        throw ValidationError("Selected MSA rows are not rectangular; row \(mismatch.name) differs in aligned length.")
    }
}

private func writeTreeAlignedFASTA(records: [TreeAlignedFASTARecord], to url: URL) throws {
    let text = records
        .map { ">\($0.name)\n\($0.sequence)" }
        .joined(separator: "\n") + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func parseTreeColumnRanges(_ value: String?, alignedLength: Int) throws -> [ClosedRange<Int>] {
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

private func parseIQTreeVersion(stdout: String, stderr: String) -> String {
    let text = "\(stdout)\n\(stderr)"
    if let range = text.range(of: #"version\s+([0-9][A-Za-z0-9._+-]*)"#, options: [.regularExpression, .caseInsensitive]) {
        let match = String(text[range])
        return match.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "unknown"
    }
    return "unknown"
}

private func copyIQTreeArtifacts(from stagingURL: URL, to bundleURL: URL) throws -> [String] {
    let artifactDir = bundleURL.appendingPathComponent("artifacts/iqtree", isDirectory: true)
    try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
    var relativePaths: [String] = []
    for fileName in ["input.aligned.fasta", "run.treefile", "run.iqtree", "run.log"] {
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

private func rewriteManifestAndProvenance(
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
        options["advancedArguments"] = AdvancedCommandLineOptions.join(advancedArguments)
    }
    if let rows {
        options["rows"] = rows
    }
    if let columns {
        options["columns"] = columns
    }

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
        "wallTimeSeconds": wallTimeSeconds,
        "warnings": [],
        "stderr": stderr,
    ]
    try writeJSONObject(provenance, to: bundleURL.appendingPathComponent(".lungfish-provenance.json"))
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

private struct TreeCommandRuntimeError: Error, LocalizedError, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
    var description: String { message }
}

private func treeCommandErrorDescription(_ error: Error) -> String {
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

private func runtimeIdentityDictionary() -> [String: Any] {
    [
        "executablePath": ProcessInfo.processInfo.arguments.first ?? NSNull(),
        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        "swiftRuntime": "swift",
        "processIdentifier": ProcessInfo.processInfo.processIdentifier,
        "condaEnvironment": ProcessInfo.processInfo.environment["CONDA_DEFAULT_ENV"] ?? NSNull(),
        "containerImage": ProcessInfo.processInfo.environment["LUNGFISH_CONTAINER_IMAGE"] ?? NSNull(),
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
        let relative = String(fileURL.path.dropFirst(bundleURL.path.count + 1))
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
