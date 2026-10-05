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
                let emitter = CLIEventEmitter(
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
                    CLICommandIdentity.executableName,
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

        func run() throws {
            try executeForTesting { print($0) }
        }

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

        func run() throws {
            try executeForTesting { print($0) }
        }

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

        func run() throws {
            try executeForTesting { print($0) }
        }

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

private func executeTreeTransform(
    bundlePath: String,
    outputPath: String,
    toolName: String,
    argv: [String],
    globalOptions: GlobalOptions,
    emit: @escaping (String) -> Void,
    transform: (PhylogeneticTreeBundle, URL, PhylogeneticTreeBundleTransformProvenance) throws -> PhylogeneticTreeBundle
) throws {
    let emitter = CLIEventEmitter(
        enabled: globalOptions.outputFormat == .json,
        emit: emit
    )
    let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    emitter.emitStart(message: "Starting tree transform.")
    do {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw ValidationError("Input tree bundle not found: \(bundleURL.path)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) == false else {
            throw ValidationError("Output bundle already exists: \(outputURL.path)")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        emitter.emitProgress(0.25, message: "Loading tree bundle.")
        let bundle = try PhylogeneticTreeBundle.load(from: bundleURL)
        emitter.emitProgress(0.65, message: "Writing transformed tree bundle.")
        _ = try transform(
            bundle,
            outputURL,
            PhylogeneticTreeBundleTransformProvenance(
                toolName: toolName,
                argv: argv,
                command: shellCommand(argv)
            )
        )
        emitter.emitComplete(output: outputURL.path)
        if globalOptions.outputFormat != .json && !globalOptions.quiet {
            emit("Wrote tree bundle: \(outputURL.path)")
            emit("Provenance: \(outputURL.appendingPathComponent(".lungfish-provenance.json").path)")
        }
    } catch {
        emitter.emitFailed(treeCommandErrorDescription(error))
        try? FileManager.default.removeItem(at: outputURL)
        throw error
    }
}

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

func runProcess(
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

    // Drain both pipes concurrently on background threads *before* waiting
    // for exit. IQ-TREE (e.g. with `-m MFP`) can write more to stdout/stderr
    // than the pipe buffer holds; reading only after `waitUntilExit()` can
    // deadlock forever once the child blocks on a full pipe.
    final class PipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
        func collected() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
    let stdoutCollector = PipeCollector()
    let stderrCollector = PipeCollector()
    let drainGroup = DispatchGroup()

    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        let handle = stdoutPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            stdoutCollector.append(chunk)
        }
        drainGroup.leave()
    }
    drainGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        let handle = stderrPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            stderrCollector.append(chunk)
        }
        drainGroup.leave()
    }

    try process.run()
    process.waitUntilExit()
    drainGroup.wait()

    let stdout = String(data: stdoutCollector.collected(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrCollector.collected(), encoding: .utf8) ?? ""
    return TreeProcessResult(
        exitStatus: process.terminationStatus,
        stdout: stdout,
        stderr: stderr,
        wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
    )
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

/// One in-scope MSA row as IQ-TREE sees it. IQ-TREE rewrites or truncates names with spaces,
/// `|`, `:`, parentheses or commas, so every row is staged under a safe tip ID (`t0001`, ...)
/// and mapped back to its display name after the run (ruling C3).
struct IQTreeStagedRow {
    let tipID: String
    let rowID: String
    let displayName: String
    let header: String
    let sequence: String
}

/// Resolves comma-separated row selectors against MSA rows. A selector matches a row ID first,
/// then a display name, then a source header. A name shared by several rows is an error that
/// names the candidate row IDs. Returns the matched rows in selector order without repeats.
func resolveTreeRowSelectors(
    _ text: String,
    among rows: [MultipleSequenceAlignmentBundle.Row],
    option: String
) throws -> [MultipleSequenceAlignmentBundle.Row] {
    let selectors = text.split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
    var matched: [MultipleSequenceAlignmentBundle.Row] = []
    for selector in selectors {
        let row: MultipleSequenceAlignmentBundle.Row
        if let byID = rows.first(where: { $0.id == selector }) {
            row = byID
        } else {
            let byName = rows.filter { $0.displayName == selector }
            let candidates = byName.isEmpty ? rows.filter { $0.sourceName == selector } : byName
            guard candidates.isEmpty == false else {
                throw ValidationError("No in-scope MSA row matches '\(selector)' in \(option).")
            }
            guard candidates.count == 1 else {
                let ids = candidates.map(\.id).joined(separator: ", ")
                throw ValidationError("'\(selector)' in \(option) is ambiguous. It names rows \(ids). Use a row ID instead.")
            }
            row = candidates[0]
        }
        if matched.contains(where: { $0.id == row.id }) == false {
            matched.append(row)
        }
    }
    return matched
}

/// Picks the in-scope rows and columns, in MSA row order, and assigns safe tip IDs.
func stageIQTreeRows(
    records: [TreeAlignedFASTARecord],
    bundle: MultipleSequenceAlignmentBundle,
    rows: String?,
    columns: String?
) throws -> [IQTreeStagedRow] {
    let orderedRows = bundle.rows.sorted { $0.order < $1.order }
    guard orderedRows.count == records.count else {
        throw ValidationError("MSA bundle lists \(orderedRows.count) rows but its aligned FASTA has \(records.count) records.")
    }
    var inScope = Array(zip(orderedRows, records))
    if let rows, rows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        let selectedIDs = Set(try resolveTreeRowSelectors(rows, among: orderedRows, option: "--rows").map(\.id))
        inScope = inScope.filter { selectedIDs.contains($0.0.id) }
    }
    guard inScope.isEmpty == false else {
        throw ValidationError("No MSA rows matched --rows selection.")
    }
    let rowsByDisplayName = Dictionary(grouping: inScope.map(\.0), by: \.displayName)
    if let duplicate = rowsByDisplayName.filter({ $0.value.count > 1 }).min(by: { $0.key < $1.key }) {
        let ids = duplicate.value.map(\.id).joined(separator: ", ")
        throw ValidationError(
            "In-scope rows \(ids) share the display name '\(duplicate.key)'. Tree tips need distinct names, so rename one or leave it out with --rows."
        )
    }
    let columnRanges = try parseTreeColumnRanges(columns, alignedLength: bundle.manifest.alignedLength)
    return inScope.enumerated().map { index, pair in
        let (row, record) = pair
        var sequence = record.sequence
        if columnRanges.isEmpty == false {
            let characters = Array(record.sequence)
            sequence = String(columnRanges.flatMap { range in range.map { characters[$0] } })
        }
        return IQTreeStagedRow(
            tipID: String(format: "t%04d", index + 1),
            rowID: row.id,
            displayName: row.displayName,
            header: record.name,
            sequence: sequence
        )
    }
}

/// Writes artifacts/iqtree/tip-map.tsv so the raw IQ-TREE treefile stays interpretable.
func writeIQTreeTipMap(_ rows: [IQTreeStagedRow], to url: URL) throws {
    func field(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
    let lines = ["tip_id\trow_id\tdisplay_name\theader"] + rows.map { row in
        [row.tipID, row.rowID, row.displayName, row.header].map(field).joined(separator: "\t")
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

/// Replaces safe tip IDs in a Newick string with quoted display names. Tip labels follow `(` or
/// `,`, and the IDs never need quoting, so a token match is exact.
func relabelIQTreeTips(in newick: String, labels: [String: String]) throws -> String {
    let regex = try NSRegularExpression(pattern: #"(?<=[(,])t[0-9]{4,}(?=[:,);\[])"#)
    let source = newick as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: newick, range: NSRange(location: 0, length: source.length)) {
        let tipID = source.substring(with: match.range)
        guard let label = labels[tipID] else {
            throw TreeCommandRuntimeError("IQ-TREE wrote an unknown tip \(tipID).")
        }
        result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        result += newickQuotedLabel(label)
        cursor = match.range.location + match.range.length
    }
    result += source.substring(from: cursor)
    return result
}

/// Quotes a Newick label unless it is plain letters, digits, `_`, `.` or `-`.
func newickQuotedLabel(_ label: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    if label.isEmpty == false, label.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return label
    }
    return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
}

/// The node to root on so the outgroup tips form one side of the root (ruling C4), or nil when
/// the outgroup is not a clade of the unrooted tree. The drawn root of an IQ-TREE tree is
/// arbitrary, so a clade whose complement is a drawn subtree counts too.
func iqtreeOutgroupRootNodeID(tipIDs: Set<String>, in tree: PhylogeneticTreeNormalizedTree) -> String? {
    let nodesByID = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.id, $0) })
    var tipsBelow: [String: Set<String>] = [:]
    func tips(_ id: String) -> Set<String> {
        if let cached = tipsBelow[id] { return cached }
        guard let node = nodesByID[id] else { return [] }
        let result = node.isTip ? [node.displayLabel] : node.childIDs.reduce(into: Set<String>()) { $0.formUnion(tips($1)) }
        tipsBelow[id] = result
        return result
    }
    let allTips = Set(tree.nodes.filter(\.isTip).map(\.displayLabel))
    let ingroup = allTips.subtracting(tipIDs)
    let candidates = tree.nodes.filter { $0.parentID != nil }
    if let node = candidates.first(where: { tips($0.id) == tipIDs }) {
        return node.id
    }
    return candidates.first(where: { tips($0.id) == ingroup })?.id
}

/// The `Seed:` value IQ-TREE logged, which is the seed it drew when none was given (ruling C1).
func parseIQTreeSeed(log: String) -> String? {
    guard let range = log.range(of: #"(?m)^Seed:\s+([0-9]+)"#, options: .regularExpression) else {
        return nil
    }
    return log[range].split(whereSeparator: \.isWhitespace).last.map(String.init)
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
