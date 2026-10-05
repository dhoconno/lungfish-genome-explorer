import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension TreeCommand {
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

        @Option(name: .customLong("seed"), help: "Random seed (default: IQ-TREE chooses a time-based random seed when omitted)")
        var seed: Int?

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

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional IQ-TREE arguments passed verbatim"
        )
        var extraArgs: String = ""

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
            let emitter = CLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let workflowName = "phylogenetic-tree-infer-iqtree"
            let wrapperToolName = "lungfish tree infer iqtree"
            let wrapperToolVersion = PhylogeneticTreeBundleImporter.toolVersion
            let externalToolName = "iqtree3"
            let msaBundleURL = URL(fileURLWithPath: msaBundlePath).standardizedFileURL
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(message: "Starting IQ-TREE inference.")

            // `.tmp` is the shared project-wide scratch root (ProjectTempDirectory,
            // SRA downloads, classification/MAFFT materialization). Only this
            // invocation's own staging subdirectory may ever be removed —
            // deleting `.tmp` itself can destroy an unrelated operation's
            // in-flight working files.
            let tempRoot = projectURL.appendingPathComponent(".tmp", isDirectory: true)
            let stagingURL = tempRoot.appendingPathComponent("lungfish-tree-iqtree-\(UUID().uuidString)", isDirectory: true)
            // Refuse-without-force must delete nothing. With --force,
            // the new bundle is built at a fresh sibling path and only
            // atomically swapped into place once IQ-TREE succeeds — the
            // existing output must never be deleted before work starts, so a
            // failed --force run leaves the previous tree untouched.
            var createdOutputInThisRun = false
            do {
                guard FileManager.default.fileExists(atPath: msaBundleURL.path) else {
                    throw ValidationError("Input MSA bundle not found: \(msaBundleURL.path)")
                }
                let outputExisted = FileManager.default.fileExists(atPath: outputURL.path)
                if outputExisted, force == false {
                    throw ValidationError("Output tree bundle already exists: \(outputURL.path). Use --force to overwrite.")
                }
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
                defer {
                    try? FileManager.default.removeItem(at: stagingURL)
                }
                // `importTree` refuses to write into an existing directory,
                // so build at a fresh sibling path first when replacing an
                // existing output, and only swap it into place after the
                // whole pipeline (including IQ-TREE itself) has succeeded.
                let buildTargetURL = outputExisted
                    ? stagingURL.appendingPathComponent("built").appendingPathExtension(outputURL.pathExtension)
                    : outputURL
                if !outputExisted {
                    createdOutputInThisRun = true
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
                if let seed {
                    iqtreeArguments += ["--seed", String(seed)]
                }
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
                    to: buildTargetURL,
                    options: .init(
                        name: name ?? outputURL.deletingPathExtension().lastPathComponent,
                        argv: argv,
                        command: treeCLIShellCommand(argv),
                        sourceFormat: "newick",
                        toolName: wrapperToolName,
                        toolVersion: wrapperToolVersion
                    )
                )

                emitter.emitProgress(0.84, message: "Preserving IQ-TREE artifacts.")
                let artifactPaths = try copyIQTreeArtifacts(from: stagingURL, to: buildTargetURL)
                let externalArgumentPathRewrites = [
                    stagedAlignmentURL.path: outputURL.appendingPathComponent("artifacts/iqtree/input.aligned.fasta").path,
                    prefixURL.path: outputURL.appendingPathComponent("artifacts/iqtree/run").path,
                ]
                try rewriteManifestAndProvenance(
                    bundleURL: buildTargetURL,
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

                if outputExisted {
                    // Atomic swap: move the old bundle aside, move
                    // the new one into place, then discard the old one only
                    // after the replace has succeeded. Restore on failure so
                    // a mid-swap error never leaves the output missing.
                    let displacedURL = stagingURL.appendingPathComponent("displaced")
                        .appendingPathExtension(outputURL.pathExtension)
                    try FileManager.default.moveItem(at: outputURL, to: displacedURL)
                    do {
                        try FileManager.default.moveItem(at: buildTargetURL, to: outputURL)
                    } catch {
                        try? FileManager.default.moveItem(at: displacedURL, to: outputURL)
                        throw error
                    }
                    try? FileManager.default.removeItem(at: displacedURL)
                }

                emitter.emitComplete(output: outputURL.path)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    print("Inferred tree: \(outputURL.path)")
                }
            } catch {
                emitter.emitFailed(treeCommandErrorDescription(error))
                // Only remove the output if THIS invocation created it fresh
                // (no pre-existing bundle). A plain refusal (exists, no
                // --force) or a failed --force run must leave the existing
                // output untouched: the --force build target
                // lives under `stagingURL` and is discarded with it below,
                // never touching `outputURL` unless the atomic swap above
                // already completed. Never remove the shared `.tmp` root —
                // only this run's own staging dir.
                if createdOutputInThisRun {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                try? FileManager.default.removeItem(at: stagingURL)
                throw error
            }
        }

        private func canonicalArgv(msaBundleURL: URL, projectURL: URL, outputURL: URL) -> [String] {
            var argv = [
                CLICommandIdentity.executableName,
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
            if let seed {
                argv += ["--seed", String(seed)]
            }
            if safeMode {
                argv.append("--safe")
            }
            if keepIdenticalSequences {
                argv.append("--keep-identical")
            }
            if extraArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                argv += ["--extra-args", extraArgs]
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
            managedHomeDirectory: URL,
            appIdentity: LungfishAppIdentity = .current
        ) throws -> URL {
            try resolveIQTreeExecutable(
                iqtreePath: iqtreePath,
                environment: environment,
                managedHomeDirectory: managedHomeDirectory,
                appIdentity: appIdentity
            )
        }

        private static func resolveIQTreeExecutable(
            iqtreePath: String?,
            environment: [String: String],
            managedHomeDirectory: URL,
            appIdentity: LungfishAppIdentity = .current
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
                    homeDirectory: managedHomeDirectory,
                    appIdentity: appIdentity
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
            let text = [extraIQTreeOptions, extraArgs]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return try AdvancedCommandLineOptions.parse(text)
        }
    }
}
