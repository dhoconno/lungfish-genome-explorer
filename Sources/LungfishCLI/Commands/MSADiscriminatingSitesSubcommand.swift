import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension MSACommand {
    /// Reports the alignment columns that separate a target lineage from the
    /// sequences an assay must not amplify.
    ///
    /// Targets and exclusions may both live in one alignment bundle, selected
    /// by row, or the exclusions may come from a separate FASTA or reference
    /// bundle, in which case they are added onto the target alignment with the
    /// managed MAFFT before the columns are scored.
    struct DiscriminatingSitesSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "discriminating-sites",
            abstract: "Find alignment columns where all targets differ from every exclusion sequence"
        )

        static let actionID = "msa.inspection.discriminating-sites"

        @Argument(help: "Input .lungfishmsa bundle holding the target alignment")
        var bundlePath: String

        @Option(
            name: .customLong("targets"),
            help: "Comma-separated target row IDs, display names, or source names. Defaults to every row not named by --exclusions."
        )
        var targets: String?

        @Option(
            name: .customLong("exclusions"),
            help: "Comma-separated exclusion row IDs, display names, or source names, for rows already inside the bundle."
        )
        var exclusions: String?

        @Option(
            name: .customLong("exclusion-sequences"),
            help: "A FASTA file or .lungfishref bundle of exclusion sequences to align onto the target alignment with the managed MAFFT."
        )
        var exclusionSequencesPath: String?

        @Option(
            name: .customLong("template"),
            help: "The target row whose 1-based coordinates the report uses. Defaults to the first target."
        )
        var template: String?

        @Option(
            name: .customLong("target-mismatch-tolerance"),
            help: "How many target rows may differ from the consensus base and still let a column qualify."
        )
        var targetMismatchTolerance: Int = 0

        @Option(
            name: .customLong("min-exclusion-differences"),
            help: "How many exclusion sequences must differ. Defaults to all of them."
        )
        var minimumExclusionDifferences: Int?

        @Option(
            name: .customLong("window-length"),
            help: "Length in template bases used to group clustered columns into candidate oligo windows."
        )
        var windowLength: Int = 25

        @Option(name: .customLong("output"), help: "Output TSV path for the per-column table")
        var outputPath: String

        @Option(
            name: .customLong("windows-output"),
            help: "Optional TSV path for the candidate-window table. Defaults to the output path with a .windows.tsv extension."
        )
        var windowsOutputPath: String?

        @Option(
            name: .customLong("json-output"),
            help: "Optional JSON path for the full report. Defaults to the output path with a .json extension."
        )
        var jsonOutputPath: String?

        @Flag(name: .customLong("force"), help: "Overwrite existing output files")
        var force: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            try execute(emit: { printEventLine($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private var resolvedWindowsOutputPath: String {
            windowsOutputPath ?? URL(fileURLWithPath: outputPath)
                .deletingPathExtension()
                .appendingPathExtension("windows.tsv").path
        }

        private var resolvedJSONOutputPath: String {
            jsonOutputPath ?? URL(fileURLWithPath: outputPath)
                .deletingPathExtension()
                .appendingPathExtension("json").path
        }

        private func execute(emit: @escaping (String) -> Void) throws {
            let runClock = ProvenanceRunClock()
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            let windowsURL = URL(fileURLWithPath: resolvedWindowsOutputPath).standardizedFileURL
            let jsonURL = URL(fileURLWithPath: resolvedJSONOutputPath).standardizedFileURL
            emitter.emitStart(actionID: Self.actionID, message: "Starting discriminating-sites analysis.")

            do {
                for candidate in [outputURL, windowsURL, jsonURL]
                where FileManager.default.fileExists(atPath: candidate.path) && force == false {
                    throw ValidationError("Output file already exists: \(candidate.path). Use --force to overwrite.")
                }
                guard exclusions != nil || exclusionSequencesPath != nil else {
                    throw ValidationError(
                        "Name the exclusion sequences with --exclusions (rows already in the bundle) or --exclusion-sequences (a FASTA or .lungfishref to align on).")
                }
                guard exclusions == nil || exclusionSequencesPath == nil else {
                    throw ValidationError("Use either --exclusions or --exclusion-sequences, not both.")
                }

                emitter.emitProgress(actionID: Self.actionID, progress: 0.1, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let alignedURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let bundleRows = try parseAlignedFASTA(at: alignedURL, keepingInteriorWhitespace: true).map { (name: $0.name, sequence: $0.sequence) }

                let resolution: MSADiscriminatingSitesRowResolution
                var alignmentCommand: String?
                var resolvedExclusionFASTAURL: URL?
                if let exclusionSequencesPath {
                    emitter.emitProgress(
                        actionID: Self.actionID, progress: 0.35,
                        message: "Aligning exclusion sequences onto the target alignment.")
                    let added = try MSADiscriminatingSitesExclusionAligner.align(
                        targetAlignmentURL: alignedURL,
                        exclusionsURL: URL(fileURLWithPath: exclusionSequencesPath).standardizedFileURL)
                    alignmentCommand = added.command
                    resolvedExclusionFASTAURL = added.resolvedExclusionFASTAURL
                    resolution = try MSADiscriminatingSitesRowResolver.resolve(
                        targetRows: bundleRows, addedExclusionRows: added.rows,
                        bundle: bundle, targets: targets, template: template)
                } else {
                    resolution = try MSADiscriminatingSitesRowResolver.resolve(
                        rows: bundleRows, bundle: bundle,
                        targets: targets, exclusions: exclusions, template: template)
                }

                emitter.emitProgress(actionID: Self.actionID, progress: 0.6, message: "Scoring alignment columns.")
                let report = try DiscriminatingSitesAnalysis.analyze(
                    targets: resolution.targets,
                    exclusions: resolution.exclusions,
                    templateIndex: resolution.templateIndex,
                    options: .init(
                        targetMismatchTolerance: targetMismatchTolerance,
                        minimumExclusionDifferences: minimumExclusionDifferences,
                        windowLength: windowLength))

                emitter.emitProgress(actionID: Self.actionID, progress: 0.85, message: "Writing report.")
                let argv = canonicalArgv(bundleURL: bundleURL, outputURL: outputURL)
                let snapshots = try [outputURL, windowsURL, jsonURL].map {
                    try msaStandaloneFilePublicationSnapshot(
                        for: $0, backupNamePrefix: "lungfish-msa-discriminating-sites")
                }
                defer { snapshots.forEach { $0.discard() } }
                do {
                    for url in [outputURL, windowsURL, jsonURL] {
                        try FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    }
                    try Data(DiscriminatingSitesReportFormatter.siteTSV(for: report).utf8)
                        .write(to: outputURL, options: .atomic)
                    try Data(DiscriminatingSitesReportFormatter.windowTSV(for: report).utf8)
                        .write(to: windowsURL, options: .atomic)
                    try DiscriminatingSitesReportFormatter.json(for: report)
                        .write(to: jsonURL, options: .atomic)

                    try writeJSON(
                        MSADiscriminatingSitesProvenance(
                            actionID: Self.actionID,
                            argv: argv,
                            reproducibleCommand: discriminatingSitesShellCommand(argv),
                            inputBundle: .init(
                                path: bundleURL.path,
                                checksumSHA256: MSADiscriminatingSitesProvenance.digest(of: bundle.manifest),
                                fileSize: bundle.manifest.fileSizes.values.reduce(0, +)),
                            inputAlignmentFile: try MSADiscriminatingSitesProvenance.FileRecord.make(at: alignedURL),
                            exclusionSequencesFile: try resolvedExclusionFASTAURL.map {
                                try MSADiscriminatingSitesProvenance.FileRecord.make(at: $0)
                            },
                            exclusionAlignmentCommand: alignmentCommand,
                            outputFiles: try [outputURL, windowsURL, jsonURL].map { try MSADiscriminatingSitesProvenance.FileRecord.make(at: $0) },
                            options: .init(
                                targetNames: report.targetNames,
                                exclusionNames: report.exclusionNames,
                                templateName: report.templateName,
                                targetMismatchTolerance: targetMismatchTolerance,
                                minimumExclusionDifferences: minimumExclusionDifferences ?? report.exclusionNames.count,
                                windowLength: windowLength),
                            discriminatingColumnCount: report.siteCount,
                            candidateWindowCount: report.windows.count,
                            exitStatus: 0,
                            wallTimeSeconds: runClock.elapsed),
                        to: outputURL.appendingPathExtension("lungfish-provenance.json"))
                } catch {
                    try snapshots.reversed().forEach { try $0.restore() }
                    throw error
                }

                emitter.emitComplete(actionID: Self.actionID, output: outputURL.path, warningCount: 0)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    DiscriminatingSitesReportFormatter.summaryLines(for: report).forEach(emit)
                    emit("Wrote \(outputURL.path)")
                    emit("Wrote \(windowsURL.path)")
                    emit("Wrote \(jsonURL.path)")
                }
            } catch {
                emitter.emitFailed(actionID: Self.actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                CLICommandIdentity.executableName, "msa", "discriminating-sites", bundleURL.path,
            ]
            if let targets { argv += ["--targets", targets] }
            if let exclusions { argv += ["--exclusions", exclusions] }
            if let exclusionSequencesPath {
                argv += ["--exclusion-sequences", URL(fileURLWithPath: exclusionSequencesPath).standardizedFileURL.path]
            }
            if let template { argv += ["--template", template] }
            argv += ["--target-mismatch-tolerance", String(targetMismatchTolerance)]
            if let minimumExclusionDifferences {
                argv += ["--min-exclusion-differences", String(minimumExclusionDifferences)]
            }
            argv += ["--window-length", String(windowLength)]
            argv += ["--output", outputURL.path]
            argv += ["--windows-output", URL(fileURLWithPath: resolvedWindowsOutputPath).standardizedFileURL.path]
            argv += ["--json-output", URL(fileURLWithPath: resolvedJSONOutputPath).standardizedFileURL.path]
            if force { argv += ["--force"] }
            if globalOptions.outputFormat == .json { argv += ["--format", "json"] }
            return argv
        }
    }
}

/// The target and exclusion rows an invocation selected, ready to analyze.
struct MSADiscriminatingSitesRowResolution: Equatable {
    let targets: [DiscriminatingSitesAnalysis.Row]
    let exclusions: [DiscriminatingSitesAnalysis.Row]
    let templateIndex: Int
}

/// Maps the CLI's name-based selections onto alignment rows.
///
/// Row names are matched the way the rest of the MSA commands match them, by
/// display name, row ID, or source name, so a caller can paste whichever name
/// the viewer or the bundle metadata showed them.
enum MSADiscriminatingSitesRowResolver {
    /// Both roles come from rows inside one bundle.
    static func resolve(
        rows: [(name: String, sequence: String)],
        bundle: MultipleSequenceAlignmentBundle,
        targets: String?,
        exclusions: String?,
        template: String?
    ) throws -> MSADiscriminatingSitesRowResolution {
        let aliases = aliasMap(for: bundle)
        let exclusionNames = try match(names: exclusions, rows: rows, aliases: aliases, role: "exclusion")
        let targetNames: [String]
        if let requested = try optionalMatch(names: targets, rows: rows, aliases: aliases, role: "target") {
            targetNames = requested
        } else {
            // With no explicit target list the remaining rows are the targets,
            // which is what marking a few rows as exclusions in the viewer means.
            targetNames = rows.map(\.name).filter { !exclusionNames.contains($0) }
        }
        let overlap = Set(targetNames).intersection(exclusionNames)
        guard overlap.isEmpty else {
            throw ValidationError(
                "Row(s) \(overlap.sorted().joined(separator: ", ")) are named as both target and exclusion.")
        }
        guard !targetNames.isEmpty else { throw ValidationError("No rows matched the target selection.") }

        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.sequence) })
        return try resolution(
            targetNames: targetNames, exclusionNames: exclusionNames,
            sequence: { byName[$0] ?? "" }, aliases: aliases, template: template)
    }

    /// Targets come from the bundle; exclusions were just aligned onto it.
    static func resolve(
        targetRows: [(name: String, sequence: String)],
        addedExclusionRows: [(name: String, sequence: String)],
        bundle: MultipleSequenceAlignmentBundle,
        targets: String?,
        template: String?
    ) throws -> MSADiscriminatingSitesRowResolution {
        let aliases = aliasMap(for: bundle)
        let targetNames = try optionalMatch(names: targets, rows: targetRows, aliases: aliases, role: "target")
            ?? targetRows.map(\.name)
        guard !targetNames.isEmpty else { throw ValidationError("No rows matched the target selection.") }
        guard !addedExclusionRows.isEmpty else {
            throw ValidationError("The exclusion input contributed no sequences.")
        }
        let byName = Dictionary(
            uniqueKeysWithValues: (targetRows + addedExclusionRows).map { ($0.name, $0.sequence) })
        return try resolution(
            targetNames: targetNames, exclusionNames: addedExclusionRows.map(\.name),
            sequence: { byName[$0] ?? "" }, aliases: aliases, template: template)
    }

    private static func resolution(
        targetNames: [String],
        exclusionNames: [String],
        sequence: (String) -> String,
        aliases: [String: Set<String>],
        template: String?
    ) throws -> MSADiscriminatingSitesRowResolution {
        var templateIndex = 0
        if let template {
            guard let index = targetNames.firstIndex(where: { matches(request: template, row: $0, aliases: aliases) }) else {
                throw ValidationError("Template row '\(template)' is not one of the target rows.")
            }
            templateIndex = index
        }
        return MSADiscriminatingSitesRowResolution(
            targets: targetNames.map { .init(name: $0, sequence: sequence($0)) },
            exclusions: exclusionNames.map { .init(name: $0, sequence: sequence($0)) },
            templateIndex: templateIndex)
    }

    /// Display name, row ID, and source name all address the same row.
    private static func aliasMap(for bundle: MultipleSequenceAlignmentBundle) -> [String: Set<String>] {
        var aliases: [String: Set<String>] = [:]
        for row in bundle.rows {
            aliases[row.displayName, default: []].formUnion([row.displayName, row.id, row.sourceName])
        }
        return aliases
    }

    private static func matches(request: String, row: String, aliases: [String: Set<String>]) -> Bool {
        row == request || (aliases[row]?.contains(request) ?? false)
    }

    private static func optionalMatch(
        names: String?,
        rows: [(name: String, sequence: String)],
        aliases: [String: Set<String>],
        role: String
    ) throws -> [String]? {
        guard let names, !names.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try match(names: names, rows: rows, aliases: aliases, role: role)
    }

    private static func match(
        names: String?,
        rows: [(name: String, sequence: String)],
        aliases: [String: Set<String>],
        role: String
    ) throws -> [String] {
        guard let names, !names.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let requested = names.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var resolved: [String] = []
        for request in requested {
            guard let row = rows.first(where: { matches(request: request, row: $0.name, aliases: aliases) }) else {
                throw ValidationError("No alignment row matched \(role) '\(request)'.")
            }
            if !resolved.contains(row.name) { resolved.append(row.name) }
        }
        return resolved
    }
}

struct MSADiscriminatingSitesProvenance: Codable, Equatable {
    struct FileRecord: Codable, Equatable {
        let path: String
        let checksumSHA256: String
        let fileSize: Int64

        /// Hashes the file at `url` so a reader can prove which bytes were used.
        static func make(at url: URL) throws -> FileRecord {
            let data = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return FileRecord(
                path: url.path,
                checksumSHA256: MultipleSequenceAlignmentBundle.sha256Hex(for: data),
                fileSize: (attributes[.size] as? NSNumber)?.int64Value ?? Int64(data.count))
        }
    }

    struct RuntimeIdentity: Codable, Equatable {
        let executablePath: String?
        let operatingSystemVersion: String
        let processIdentifier: Int32
        let condaEnvironment: String?
        let containerImage: String?
    }

    /// One digest standing for the whole input bundle, over its per-file
    /// checksums in a fixed order.
    static func digest(of manifest: MultipleSequenceAlignmentBundle.Manifest) -> String {
        let source = manifest.checksums
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        return MultipleSequenceAlignmentBundle.sha256Hex(for: Data(source.utf8))
    }

    struct Options: Codable, Equatable {
        let targetNames: [String]
        let exclusionNames: [String]
        let templateName: String
        let targetMismatchTolerance: Int
        let minimumExclusionDifferences: Int
        let windowLength: Int
    }

    let schemaVersion: Int
    let workflowName: String
    let actionID: String
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let reproducibleCommand: String
    let inputBundle: MSADiscriminatingSitesProvenance.FileRecord
    let inputAlignmentFile: MSADiscriminatingSitesProvenance.FileRecord
    let exclusionSequencesFile: MSADiscriminatingSitesProvenance.FileRecord?
    /// The MAFFT command that added the exclusion sequences, when one ran.
    let exclusionAlignmentCommand: String?
    let outputFiles: [MSADiscriminatingSitesProvenance.FileRecord]
    let options: Options
    let discriminatingColumnCount: Int
    let candidateWindowCount: Int
    let runtimeIdentity: MSADiscriminatingSitesProvenance.RuntimeIdentity
    let exitStatus: Int
    let wallTimeSeconds: Double
    let createdAt: Date

    init(
        actionID: String,
        argv: [String],
        reproducibleCommand: String,
        inputBundle: MSADiscriminatingSitesProvenance.FileRecord,
        inputAlignmentFile: MSADiscriminatingSitesProvenance.FileRecord,
        exclusionSequencesFile: MSADiscriminatingSitesProvenance.FileRecord?,
        exclusionAlignmentCommand: String?,
        outputFiles: [MSADiscriminatingSitesProvenance.FileRecord],
        options: Options,
        discriminatingColumnCount: Int,
        candidateWindowCount: Int,
        exitStatus: Int,
        wallTimeSeconds: Double
    ) {
        schemaVersion = 1
        workflowName = "multiple-sequence-alignment-discriminating-sites"
        toolName = "lungfish msa discriminating-sites"
        toolVersion = MultipleSequenceAlignmentBundle.toolVersion
        self.actionID = actionID
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.inputBundle = inputBundle
        self.inputAlignmentFile = inputAlignmentFile
        self.exclusionSequencesFile = exclusionSequencesFile
        self.exclusionAlignmentCommand = exclusionAlignmentCommand
        self.outputFiles = outputFiles
        self.options = options
        self.discriminatingColumnCount = discriminatingColumnCount
        self.candidateWindowCount = candidateWindowCount
        runtimeIdentity = MSADiscriminatingSitesProvenance.RuntimeIdentity(
            executablePath: ProcessInfo.processInfo.arguments.first,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            condaEnvironment: ProcessInfo.processInfo.environment["CONDA_DEFAULT_ENV"],
            containerImage: ProcessInfo.processInfo.environment["LUNGFISH_CONTAINER_IMAGE"])
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        createdAt = Date()
    }
}

/// Renders argv as a command a reader can paste into a shell.
func discriminatingSitesShellCommand(_ argv: [String]) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=/:.,")
    return argv.map { value in
        guard !value.isEmpty else { return "''" }
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }.joined(separator: " ")
}
