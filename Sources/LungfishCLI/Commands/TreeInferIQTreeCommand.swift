import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension TreeCommand {
    struct InferIQTreeSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "iqtree",
            abstract: "Infer a maximum-likelihood tree from a .lungfishmsa bundle using IQ-TREE",
            discussion: """
            --threads sets IQ-TREE -T. Without --threads IQ-TREE runs with -T AUTO, which is \
            not reproducible because the same seed can give different branch support. Pass \
            --seed N with a fixed --threads N to reproduce a tree.
            """
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

        @Option(
            name: .customLong("sequence-type"),
            help: "IQ-TREE sequence type: auto, DNA, AA, CODON, CODON1 to CODON25 (IQ-TREE genetic code numbers), BIN, MORPH, NT2AA"
        )
        var sequenceType: String = "auto"

        @Option(name: .customLong("bootstrap"), help: "Ultrafast bootstrap replicate count (1000 or more)")
        var bootstrap: Int?

        @Option(name: .customLong("alrt"), help: "SH-aLRT replicate count (1 or more)")
        var alrt: Int?

        @Option(name: .customLong("seed"), help: "Random seed (default: IQ-TREE draws one, and provenance records it as effectiveSeed)")
        var seed: Int?

        @Option(
            name: .customLong("outgroup"),
            help: "Optional comma-separated outgroup row IDs or display names. The saved tree is rooted on the outgroup. It does not change the inferred relationships."
        )
        var outgroup: String?

        @Flag(name: .customLong("safe"), help: "Enable IQ-TREE safe numerical mode")
        var safeMode: Bool = false

        @Flag(name: .customLong("keep-identical"), help: "Keep identical sequences in the IQ-TREE analysis")
        var keepIdenticalSequences: Bool = false

        @Option(
            name: .customLong("extra-iqtree-options"),
            parsing: .unconditional,
            help: .hidden
        )
        var extraIQTreeOptions: String = ""

        @Option(
            name: .customLong("extra-args"),
            parsing: .unconditional,
            help: "Additional IQ-TREE arguments passed verbatim. Flags that have a curated option (-s, --prefix, -m, -T, -nt, --seed, -B, --alrt, -alrt, -o, -st, --seqtype) are rejected."
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

                // Rulings C5, C6 and C7: every check that can fail runs before anything is staged.
                try validateCuratedOptions()
                let normalizedSequenceType = try Self.normalizedSequenceType(sequenceType)
                let advancedArguments = try parsedAdvancedArguments()
                emitter.emitProgress(0.12, message: "Preparing aligned FASTA input.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: msaBundleURL)
                let stagedRows = try stageIQTreeRows(
                    records: parseTreeAlignedFASTA(at: msaBundleURL.appendingPathComponent("alignment/primary.aligned.fasta")),
                    bundle: bundle,
                    rows: rows,
                    columns: columns
                )
                let stagedRecords = stagedRows.map { TreeAlignedFASTARecord(name: $0.tipID, sequence: $0.sequence) }
                let selectedAlignedLength = stagedRecords.first?.sequence.count ?? 0
                guard selectedAlignedLength > 0 else {
                    throw ValidationError("Tree inference selection produced zero aligned columns.")
                }
                try validateTreeAlignedRecords(stagedRecords)
                try validateScope(rowCount: stagedRows.count, alignedLength: selectedAlignedLength, sequenceType: normalizedSequenceType)
                let outgroupRows = try resolvedOutgroup(in: stagedRows, bundle: bundle)

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

                let stagedAlignmentURL = stagingURL.appendingPathComponent("input.aligned.fasta")
                try writeTreeAlignedFASTA(records: stagedRecords, to: stagedAlignmentURL)
                try writeIQTreeTipMap(stagedRows, to: stagingURL.appendingPathComponent("tip-map.tsv"))

                emitter.emitProgress(0.20, message: "Resolving IQ-TREE executable.")
                let executableURL = try resolveIQTreeExecutable()
                let versionResult = try runProcess(executableURL: executableURL, arguments: ["--version"], workingDirectory: nil)
                let toolVersion = parseIQTreeVersion(stdout: versionResult.stdout, stderr: versionResult.stderr)
                // Ruling C2: AUTO only when --threads is omitted. It is not reproducible.
                let iqtreeThreads = globalOptions.threads.map(String.init) ?? "AUTO"

                let prefixURL = stagingURL.appendingPathComponent("run")
                var iqtreeArguments = [
                    "-s", stagedAlignmentURL.path,
                    "-m", model,
                    "--prefix", prefixURL.path,
                    "-T", iqtreeThreads,
                ]
                if let normalizedSequenceType {
                    iqtreeArguments += ["--seqtype", normalizedSequenceType]
                }
                if let bootstrap {
                    iqtreeArguments += ["-B", String(bootstrap)]
                }
                if let alrt {
                    iqtreeArguments += ["--alrt", String(alrt)]
                }
                if let seed {
                    iqtreeArguments += ["--seed", String(seed)]
                }
                if outgroupRows.isEmpty == false {
                    iqtreeArguments += ["-o", outgroupRows.map(\.tipID).joined(separator: ",")]
                }
                if safeMode {
                    iqtreeArguments.append("--safe")
                }
                if keepIdenticalSequences {
                    iqtreeArguments.append("--keep-ident")
                }
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
                let runLog = (try? String(contentsOf: stagingURL.appendingPathComponent("run.log"), encoding: .utf8)) ?? ""

                emitter.emitProgress(0.66, message: "Mapping tip IDs back to MSA names.")
                let labelled = try labelledTreefile(
                    treefileURL: treefileURL,
                    stagedRows: stagedRows,
                    outgroupRows: outgroupRows,
                    iqtreeOutput: runLog + "\n" + runResult.stdout,
                    stagingURL: stagingURL
                )
                var warnings: [String] = []
                if let warning = labelled.outgroupWarning {
                    warnings.append(warning)
                    emitter.emitLog(.warning, warning)
                }

                let argv = canonicalArgv(msaBundleURL: msaBundleURL, projectURL: projectURL, outputURL: outputURL)
                emitter.emitProgress(0.72, message: "Creating native .lungfishtree bundle.")
                _ = try PhylogeneticTreeBundleImporter.importTree(
                    from: labelled.url,
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
                var runOptions: [String: String] = [:]
                if let effectiveSeed = seed.map(String.init) ?? parseIQTreeSeed(log: runLog) {
                    runOptions["effectiveSeed"] = effectiveSeed
                }
                if let outgroup, outgroupRows.isEmpty == false {
                    runOptions["outgroup"] = outgroup
                    runOptions["outgroupTipIDs"] = outgroupRows.map(\.tipID).joined(separator: ",")
                    runOptions["rooting"] = labelled.rooted ? "outgroup" : "unrooted"
                }
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
                    selectedRowCount: stagedRows.count,
                    selectedAlignedLength: selectedAlignedLength,
                    rows: rows,
                    columns: columns,
                    runOptions: runOptions,
                    warnings: warnings,
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
            if let outgroup, outgroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                argv += ["--outgroup", outgroup]
            }
            if safeMode {
                argv.append("--safe")
            }
            if keepIdenticalSequences {
                argv.append("--keep-identical")
            }
            // Ruling C6: the hidden --extra-iqtree-options alias folds into --extra-args.
            let combinedExtraArgs = combinedExtraArgumentText()
            if combinedExtraArgs.isEmpty == false {
                argv += ["--extra-args", combinedExtraArgs]
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

        /// Genetic codes IQ-TREE 3.1.3 defines for `CODONn`. Codes 7, 8 and 17 to 20 are not
        /// NCBI tables, and IQ-TREE exits with "Wrong genetic code" for them.
        static let iqtreeGeneticCodes: Set<Int> = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14, 15, 16, 21, 22, 23, 24, 25]

        /// The IQ-TREE `--seqtype` value, or nil for auto-detection (ruling C7).
        static func normalizedSequenceType(_ value: String) throws -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed.lowercased() != "auto" else {
                return nil
            }
            let uppercased = trimmed.uppercased()
            if ["DNA", "AA", "CODON", "BIN", "MORPH", "NT2AA"].contains(uppercased) {
                return uppercased
            }
            if uppercased.hasPrefix("CODON"),
               uppercased.dropFirst(5).allSatisfy(\.isNumber),
               let code = Int(uppercased.dropFirst(5)),
               iqtreeGeneticCodes.contains(code) {
                return "CODON\(code)"
            }
            throw ValidationError(
                "Unsupported IQ-TREE sequence type '\(trimmed)'. Supported values: auto, DNA, AA, CODON, CODON1 to CODON25 except 7, 8 and 17 to 20, BIN, MORPH, NT2AA."
            )
        }

        /// IQ-TREE flags that a curated option already sets, mapped to that option (ruling C6).
        /// Extra text that repeats one would silently override the curated value.
        static let reservedIQTreeFlags: [String: String] = [
            "-s": "the input bundle argument",
            "--prefix": "--output",
            "-m": "--model",
            "-T": "--threads",
            "-nt": "--threads",
            "--seed": "--seed",
            "-B": "--bootstrap",
            "--alrt": "--alrt",
            "-alrt": "--alrt",
            "-o": "--outgroup",
            "-st": "--sequence-type",
            "--seqtype": "--sequence-type",
        ]

        /// Ruling C5. Checks that need only the options, run before the bundle is read.
        private func validateCuratedOptions() throws {
            if let bootstrap, bootstrap < 1000 {
                throw ValidationError("--bootstrap must be 1000 or more (the IQ-TREE ultrafast bootstrap minimum), got \(bootstrap).")
            }
            if let alrt, alrt < 1 {
                throw ValidationError("--alrt must be 1 or more, got \(alrt).")
            }
            let base = model.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "+", maxSplits: 1)
                .first
                .map { $0.uppercased() } ?? ""
            if base == "MF" || base.hasSuffix("ONLY") {
                throw ValidationError("--model \(model) is not allowed. MF/TESTONLY select a model without a tree search, use MFP or TEST.")
            }
        }

        /// Ruling C5 row minimums and the C7 codon frame check, on the in-scope rows and columns.
        private func validateScope(rowCount: Int, alignedLength: Int, sequenceType: String?) throws {
            if rowCount < 3 {
                throw ValidationError("IQ-TREE needs at least 3 sequences, but the selection has \(rowCount).")
            }
            if bootstrap != nil || alrt != nil, rowCount < 4 {
                throw ValidationError("Branch support (--bootstrap or --alrt) needs at least 4 sequences, but the selection has \(rowCount).")
            }
            if let sequenceType, sequenceType.hasPrefix("CODON"), alignedLength % 3 != 0 {
                throw ValidationError(
                    "Codon sequence types need whole codons, so the in-scope column count must be a multiple of 3 (got \(alignedLength))."
                )
            }
        }

        /// Ruling C4. Outgroup names resolve against the in-scope rows the way --rows does.
        private func resolvedOutgroup(in stagedRows: [IQTreeStagedRow], bundle: MultipleSequenceAlignmentBundle) throws -> [IQTreeStagedRow] {
            guard let outgroup, outgroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return []
            }
            let stagedByRowID = Dictionary(uniqueKeysWithValues: stagedRows.map { ($0.rowID, $0) })
            let inScope = bundle.rows.filter { stagedByRowID[$0.id] != nil }
            let matched = try resolveTreeRowSelectors(outgroup, among: inScope, option: "--outgroup")
                .compactMap { stagedByRowID[$0.id] }
            guard matched.count < stagedRows.count else {
                throw ValidationError("--outgroup must leave at least one in-scope sequence in the ingroup.")
            }
            return matched
        }

        /// Roots the IQ-TREE tree on the outgroup when it is a clade, then swaps the safe tip IDs
        /// back to MSA display names (rulings C3 and C4). The labelled file keeps the name
        /// run.treefile so the manifest's source file name matches the IQ-TREE artifact.
        private func labelledTreefile(
            treefileURL: URL,
            stagedRows: [IQTreeStagedRow],
            outgroupRows: [IQTreeStagedRow],
            iqtreeOutput: String,
            stagingURL: URL
        ) throws -> (url: URL, rooted: Bool, outgroupWarning: String?) {
            var newick = try String(contentsOf: treefileURL, encoding: .utf8)
            var rooted = false
            var warning: String?
            if outgroupRows.isEmpty == false {
                let idTree = try PhylogeneticTreeBundleImporter.importTree(
                    from: treefileURL,
                    to: stagingURL.appendingPathComponent("tip-ids.lungfishtree", isDirectory: true)
                )
                let rootNodeID = iqtreeOutput.contains("Branch separating outgroup is not found")
                    ? nil
                    : iqtreeOutgroupRootNodeID(tipIDs: Set(outgroupRows.map(\.tipID)), in: idTree.normalizedTree)
                if let rootNodeID {
                    let rerooted = try idTree.rerootedBundle(
                        on: rootNodeID,
                        to: stagingURL.appendingPathComponent("rooted.lungfishtree", isDirectory: true),
                        provenance: .init(toolName: "lungfish tree infer iqtree", argv: [])
                    )
                    newick = try String(contentsOf: rerooted.url.appendingPathComponent("tree/primary.nwk"), encoding: .utf8)
                    rooted = true
                } else {
                    let names = outgroupRows.map(\.displayName).joined(separator: ", ")
                    warning = "The outgroup (\(names)) is not monophyletic in the inferred tree, so the tree was saved unrooted."
                }
            }
            let labels = Dictionary(uniqueKeysWithValues: stagedRows.map { ($0.tipID, $0.displayName) })
            let labelledDirectory = stagingURL.appendingPathComponent("labelled", isDirectory: true)
            try FileManager.default.createDirectory(at: labelledDirectory, withIntermediateDirectories: true)
            let url = labelledDirectory.appendingPathComponent("run.treefile")
            try relabelIQTreeTips(in: newick, labels: labels).write(to: url, atomically: true, encoding: .utf8)
            return (url, rooted, warning)
        }

        private func combinedExtraArgumentText() -> String {
            [extraIQTreeOptions, extraArgs]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private func parsedAdvancedArguments() throws -> [String] {
            let arguments = try AdvancedCommandLineOptions.parse(combinedExtraArgumentText())
            for argument in arguments {
                let flag = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
                if let curated = Self.reservedIQTreeFlags[flag] {
                    throw ValidationError("--extra-args must not set \(flag). Use \(curated) instead.")
                }
            }
            return arguments
        }
    }
}
