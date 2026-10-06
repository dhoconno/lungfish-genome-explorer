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
            --threads sets IQ-TREE -T, and without it IQ-TREE runs with -T AUTO. Only \
            --threads 1 with a fixed --seed reproduces a tree byte for byte. With more threads, \
            or with AUTO, the same seed gives slightly different branch lengths or support on \
            each run.
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

        @Option(name: .customLong("seed"), help: "Random seed from 1 to 2147483647 (default: IQ-TREE draws one, and provenance records it as effectiveSeed)")
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
            help: "Additional IQ-TREE arguments passed verbatim. Flags that have a curated option (-s, --msa, --aln, --prefix, -pre, -m, --model, --modelomatic, -T, --threads, -nt, --seed, -seed, -B, -bb, --ufboot, --alrt, -alrt, -o, -st, --seqtype) are rejected. With -b or --lbp no support labels are recorded."
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
                try validateScope(
                    rowCount: stagedRows.count,
                    columnRanges: try codonFrameRanges(alignedLength: bundle.manifest.alignedLength),
                    sequenceType: normalizedSequenceType
                )
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
                let runReport = (try? String(contentsOf: stagingURL.appendingPathComponent("run.iqtree"), encoding: .utf8)) ?? ""
                // Fix F2 (m8): -b and --lbp add support values in an order LGE does not know.
                let addsUnorderedSupport = IQTreeOptionRules.addsUnorderedSupport(advancedArguments)
                let supportLabels = addsUnorderedSupport
                    ? nil
                    : iqtreeSupportLabels(alrt: alrt, bootstrap: bootstrap, advancedArguments: advancedArguments)
                let effectiveSeed = seed.map(String.init) ?? parseIQTreeSeed(log: runLog)

                emitter.emitProgress(0.66, message: "Rooting the tree on the outgroup.")
                let rooting = try rootedTreefile(
                    treefileURL: treefileURL,
                    outgroupRows: outgroupRows,
                    supportLabels: supportLabels,
                    iqtreeOutput: runLog + "\n" + runResult.stdout,
                    stagingURL: stagingURL
                )
                var warnings: [String] = []
                if addsUnorderedSupport {
                    warnings.append(IQTreeOptionRules.unorderedSupportWarning)
                    emitter.emitLog(.warning, IQTreeOptionRules.unorderedSupportWarning)
                }
                if let warning = rooting.outgroupWarning {
                    warnings.append(warning)
                    emitter.emitLog(.warning, warning)
                }

                let argv = canonicalArgv(
                    msaBundleURL: msaBundleURL,
                    projectURL: projectURL,
                    outputURL: outputURL,
                    sequenceType: normalizedSequenceType
                )
                let inference = iqtreeInferenceSummary(
                    report: runReport,
                    run: IQTreeInferenceRunDetails(
                        programVersion: toolVersion,
                        requestedModel: model,
                        sequenceType: normalizedSequenceType,
                        effectiveSeed: effectiveSeed,
                        threads: globalOptions.threads,
                        ufBootReplicates: bootstrap,
                        shALRTReplicates: alrt,
                        outgroupRows: outgroupRows,
                        outgroupWarning: rooting.outgroupWarning,
                        msaBundleURL: msaBundleURL,
                        msaManifest: bundle.manifest,
                        selectedRowCount: stagedRows.count,
                        selectedColumns: columns,
                        selectedAlignedLength: selectedAlignedLength
                    )
                )
                emitter.emitProgress(0.72, message: "Creating native .lungfishtree bundle with MSA tip names.")
                // Ruling C3: the importer swaps the safe tip IDs back to MSA display names.
                _ = try PhylogeneticTreeBundleImporter.importTree(
                    from: rooting.url,
                    to: buildTargetURL,
                    options: .init(
                        name: name ?? outputURL.deletingPathExtension().lastPathComponent,
                        argv: argv,
                        command: treeCLIShellCommand(argv),
                        sourceFormat: "newick",
                        toolName: wrapperToolName,
                        toolVersion: wrapperToolVersion,
                        supportLabels: supportLabels,
                        branchLengthUnit: "substitutions per site",
                        inference: inference,
                        tipLabelMap: Dictionary(uniqueKeysWithValues: stagedRows.map { ($0.tipID, $0.displayName) })
                    )
                )

                emitter.emitProgress(0.84, message: "Preserving IQ-TREE artifacts.")
                let artifactPaths = try copyIQTreeArtifacts(from: stagingURL, to: buildTargetURL)
                let externalArgumentPathRewrites = [
                    stagedAlignmentURL.path: outputURL.appendingPathComponent("artifacts/iqtree/input.aligned.fasta").path,
                    prefixURL.path: outputURL.appendingPathComponent("artifacts/iqtree/run").path,
                ]
                var runOptions: [String: String] = [:]
                if let effectiveSeed {
                    runOptions["effectiveSeed"] = effectiveSeed
                }
                if let outgroup, outgroupRows.isEmpty == false {
                    runOptions["outgroup"] = outgroup
                    runOptions["outgroupTipIDs"] = outgroupRows.map(\.tipID).joined(separator: ",")
                    runOptions["outgroupNames"] = outgroupRows.map(\.displayName).joined(separator: ", ")
                    runOptions["rooting"] = rooting.rooted ? "outgroup" : "unrooted"
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

        /// `sequenceType` is the normalized value (ruling C7), so the recorded command, the
        /// provenance options and the IQ-TREE argv spell it the same way.
        private func canonicalArgv(msaBundleURL: URL, projectURL: URL, outputURL: URL, sequenceType: String?) -> [String] {
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
            if let sequenceType {
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

        /// Ruling C5. Checks that need only the options, run before the bundle is read.
        private func validateCuratedOptions() throws {
            if let bootstrap, bootstrap < 1000 {
                throw ValidationError("--bootstrap must be 1000 or more (the IQ-TREE ultrafast bootstrap minimum), got \(bootstrap).")
            }
            if let alrt, alrt < 1 {
                throw ValidationError("--alrt must be 1 or more, got \(alrt).")
            }
            if let seed, (1...Int(Int32.max)).contains(seed) == false {
                throw ValidationError("--seed must be 1 to 2147483647, got \(seed).")
            }
            if IQTreeOptionRules.isModelSelectionOnly(model) {
                throw ValidationError("--model \(model) is not allowed. MF and TESTONLY select a model without a tree search. Use MFP or TEST.")
            }
        }

        /// Ruling C5 row minimums and the C7 codon frame check, on the in-scope rows and columns.
        private func validateScope(rowCount: Int, columnRanges: [ClosedRange<Int>], sequenceType: String?) throws {
            if rowCount < 3 {
                throw ValidationError("IQ-TREE needs at least 3 sequences, but the selection has \(rowCount).")
            }
            if bootstrap != nil || alrt != nil, rowCount < 4 {
                throw ValidationError("Branch support (--bootstrap or --alrt) needs at least 4 sequences, but the selection has \(rowCount).")
            }
            if let sequenceType, sequenceType.hasPrefix("CODON"),
               let message = IQTreeOptionRules.codonFrameMessage(
                   columnRanges: columnRanges,
                   wholeAlignment: (columns ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               ) {
                throw ValidationError(message)
            }
        }

        /// The 1-based in-scope column ranges in --columns order, or the whole alignment as one
        /// range from column 1 (fix F2, m9).
        private func codonFrameRanges(alignedLength: Int) throws -> [ClosedRange<Int>] {
            let ranges = try parseTreeColumnRanges(columns, alignedLength: alignedLength)
                .map { ($0.lowerBound + 1)...($0.upperBound + 1) }
            return ranges.isEmpty ? [1...alignedLength] : ranges
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

        /// Roots the IQ-TREE tree on the outgroup when it is a clade (ruling C4). The reroot runs on
        /// the tip-ID tree, and the importer relabels the result afterwards. A rooted file keeps
        /// the name run.treefile so the manifest's source file name matches the IQ-TREE artifact.
        private func rootedTreefile(
            treefileURL: URL,
            outgroupRows: [IQTreeStagedRow],
            supportLabels: [String]?,
            iqtreeOutput: String,
            stagingURL: URL
        ) throws -> (url: URL, rooted: Bool, outgroupWarning: String?) {
            guard outgroupRows.isEmpty == false else {
                return (treefileURL, false, nil)
            }
            let idTree = try PhylogeneticTreeBundleImporter.importTree(
                from: treefileURL,
                to: stagingURL.appendingPathComponent("tip-ids.lungfishtree", isDirectory: true),
                options: .init(supportLabels: supportLabels)
            )
            let rootNodeID = iqtreeOutput.contains("Branch separating outgroup is not found")
                ? nil
                : iqtreeOutgroupRootNodeID(tipIDs: Set(outgroupRows.map(\.tipID)), in: idTree.normalizedTree)
            guard let rootNodeID else {
                let names = outgroupRows.map(\.displayName).joined(separator: ", ")
                return (treefileURL, false, "The outgroup (\(names)) is not monophyletic in the inferred tree, so the tree was saved unrooted.")
            }
            let rerooted = try idTree.rerootedBundle(
                on: rootNodeID,
                to: stagingURL.appendingPathComponent("rooted.lungfishtree", isDirectory: true),
                provenance: .init(toolName: "lungfish tree infer iqtree", argv: [])
            )
            let rootedDirectory = stagingURL.appendingPathComponent("rooted", isDirectory: true)
            try FileManager.default.createDirectory(at: rootedDirectory, withIntermediateDirectories: true)
            let url = rootedDirectory.appendingPathComponent("run.treefile")
            try FileManager.default.copyItem(at: rerooted.url.appendingPathComponent("tree/primary.nwk"), to: url)
            return (url, true, nil)
        }

        private func combinedExtraArgumentText() -> String {
            [extraIQTreeOptions, extraArgs]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        private func parsedAdvancedArguments() throws -> [String] {
            let arguments = try AdvancedCommandLineOptions.parse(combinedExtraArgumentText())
            if let reserved = IQTreeOptionRules.firstReservedFlag(in: arguments) {
                throw ValidationError("--extra-args must not set \(reserved.flag). Use \(reserved.option.cliName) instead.")
            }
            return arguments
        }
    }
}
