import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct MSACommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msa",
        abstract: "Inspect and run multiple sequence alignment actions",
        subcommands: [
            ActionsSubcommand.self,
            DescribeSubcommand.self,
            AnnotateSubcommand.self,
            ExportSubcommand.self,
            ConsensusSubcommand.self,
            ExtractSubcommand.self,
            MaskSubcommand.self,
            TrimSubcommand.self,
            DistanceSubcommand.self,
        ]
    )

    struct ActionsPayload: Codable, Equatable {
        let schemaVersion: Int
        let count: Int
        let references: [String]
        let actions: [MultipleSequenceAlignmentActionDescriptor]
    }
}

extension MSACommand {
    struct AnnotateSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotate",
            abstract: "Create and manage multiple sequence alignment annotations",
            subcommands: [
                AddSubcommand.self,
                EditSubcommand.self,
                DeleteSubcommand.self,
                ProjectSubcommand.self,
            ]
        )
    }

    struct AddSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add an annotation from aligned MSA columns"
        )

        @Argument(help: "Input .lungfishmsa bundle to update")
        var bundlePath: String

        @Option(name: .customLong("row"), help: "Row ID, display name, or source name")
        var row: String

        @Option(name: .customLong("columns"), help: "1-based aligned column ranges, e.g. 10-40,55")
        var columns: String

        @Option(name: .customLong("name"), help: "Annotation name")
        var name: String

        @Option(name: .customLong("type"), help: "Annotation type, e.g. gene, CDS, motif")
        var type: String

        @Option(name: .customLong("strand"), help: "Annotation strand: +, -, or .")
        var strand: String = "."

        @Option(name: .customLong("note"), help: "Optional annotation note")
        var note: String?

        @Option(name: .customLong("qualifier"), help: "Repeatable key=value qualifier")
        var qualifierOptions: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            try execute(emit: { print($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private func execute(emit: @escaping (String) -> Void) throws {
            let emitter = MSAActionCLIEventEmitter(
                enabled: globalOptions.outputFormat == .json,
                emit: emit
            )
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let actionID = "msa.annotation.add"
            emitter.emitStart(actionID: actionID, message: "Starting MSA annotation add.")

            do {
                guard ["+", "-", "."].contains(strand) else {
                    throw ValidationError("Unsupported annotation strand '\(strand)'. Supported values: +, -, .")
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let resolvedRow = try resolveMSARow(row, in: bundle)
                let alignedIntervals = try parseColumnRanges(columns, alignedLength: bundle.manifest.alignedLength)
                    .map { AnnotationInterval(start: $0.lowerBound, end: $0.upperBound + 1) }
                guard alignedIntervals.isEmpty == false else {
                    throw ValidationError("At least one aligned column range is required.")
                }
                let qualifiers = try parseQualifierOptions(qualifierOptions)

                emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Creating aligned annotation.")
                let annotation = try bundle.makeAnnotationFromAlignedSelection(
                    rowID: resolvedRow.id,
                    alignedIntervals: alignedIntervals,
                    name: name,
                    type: type,
                    strand: strand,
                    qualifiers: qualifiers,
                    note: note
                )

                emitter.emitProgress(actionID: actionID, progress: 0.82, message: "Writing annotation SQLite store and provenance.")
                let argv = canonicalAnnotateAddArgv(bundleURL: bundleURL)
                let updated = try bundle.appendingAnnotations(
                    [annotation],
                    editDescription: "Add annotation from MSA selection",
                    argv: argv,
                    workflowName: "multiple-sequence-alignment-annotation-add",
                    toolName: "lungfish msa annotate add"
                )

                emitter.emitComplete(actionID: actionID, output: updated.url.path, warningCount: annotation.warnings.count)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Added annotation \(annotation.id)")
                    emit("Bundle: \(updated.url.path)")
                    emit("Row: \(annotation.rowName)")
                    emit("Aligned intervals: \(formatIntervals(annotation.alignedIntervals))")
                    emit("Source intervals: \(formatIntervals(annotation.sourceIntervals))")
                    if annotation.warnings.isEmpty == false {
                        emit("Warnings: \(annotation.warnings.joined(separator: "; "))")
                    }
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalAnnotateAddArgv(bundleURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "annotate",
                "add",
                bundleURL.path,
                "--row",
                row,
                "--columns",
                columns,
                "--name",
                name,
                "--type",
                type,
                "--strand",
                strand,
            ]
            if let note {
                argv += ["--note", note]
            }
            for qualifier in qualifierOptions {
                argv += ["--qualifier", qualifier]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct EditSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit an MSA annotation"
        )

        @Argument(help: "Input .lungfishmsa bundle to update")
        var bundlePath: String

        @Option(name: .customLong("annotation"), help: "Annotation ID or source annotation ID")
        var annotation: String

        @Option(name: .customLong("name"), help: "Replacement annotation name")
        var name: String?

        @Option(name: .customLong("type"), help: "Replacement annotation type")
        var type: String?

        @Option(name: .customLong("strand"), help: "Replacement strand: +, -, or .")
        var strand: String?

        @Option(name: .customLong("note"), help: "Replacement annotation note")
        var note: String?

        @Option(name: .customLong("qualifier"), help: "Repeatable replacement qualifier key=value")
        var qualifierOptions: [String] = []

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            try execute(emit: { print($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private func execute(emit: @escaping (String) -> Void) throws {
            let actionID = "msa.annotation.edit"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA annotation edit.")

            do {
                guard name != nil || type != nil || strand != nil || note != nil || qualifierOptions.isEmpty == false else {
                    throw ValidationError("At least one edit option is required.")
                }
                if let strand, ["+", "-", "."].contains(strand) == false {
                    throw ValidationError("Unsupported annotation strand '\(strand)'. Supported values: +, -, .")
                }

                emitter.emitProgress(actionID: actionID, progress: 0.20, message: "Loading MSA annotation store.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let store = try bundle.loadAnnotationStore()
                let existing = try resolveMSAAnnotation(annotation, in: store)
                var qualifiers = existing.qualifiers
                for (key, values) in try parseQualifierOptions(qualifierOptions) {
                    qualifiers[key] = values
                }
                let edited = MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord(
                    id: existing.id,
                    origin: existing.origin,
                    rowID: existing.rowID,
                    rowName: existing.rowName,
                    sourceSequenceName: existing.sourceSequenceName,
                    sourceFilePath: existing.sourceFilePath,
                    sourceTrackID: existing.sourceTrackID,
                    sourceTrackName: existing.sourceTrackName,
                    sourceAnnotationID: existing.sourceAnnotationID,
                    name: name ?? existing.name,
                    type: type ?? existing.type,
                    strand: strand ?? existing.strand,
                    sourceIntervals: existing.sourceIntervals,
                    alignedIntervals: existing.alignedIntervals,
                    qualifiers: qualifiers,
                    note: note ?? existing.note,
                    projection: existing.projection,
                    warnings: existing.warnings
                )

                emitter.emitProgress(actionID: actionID, progress: 0.75, message: "Writing edited annotation and provenance.")
                let updated = try bundle.appendingAnnotations(
                    [edited],
                    editDescription: "Edit MSA annotation \(existing.id)",
                    argv: canonicalAnnotateEditArgv(bundleURL: bundleURL),
                    workflowName: "multiple-sequence-alignment-annotation-edit",
                    toolName: "lungfish msa annotate edit"
                )

                emitter.emitComplete(actionID: actionID, output: updated.url.path, warningCount: edited.warnings.count)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Edited annotation \(edited.id)")
                    emit("Bundle: \(updated.url.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalAnnotateEditArgv(bundleURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "annotate",
                "edit",
                bundleURL.path,
                "--annotation",
                annotation,
            ]
            if let name {
                argv += ["--name", name]
            }
            if let type {
                argv += ["--type", type]
            }
            if let strand {
                argv += ["--strand", strand]
            }
            if let note {
                argv += ["--note", note]
            }
            for qualifier in qualifierOptions {
                argv += ["--qualifier", qualifier]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct DeleteSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete an MSA annotation"
        )

        @Argument(help: "Input .lungfishmsa bundle to update")
        var bundlePath: String

        @Option(name: .customLong("annotation"), help: "Annotation ID or source annotation ID")
        var annotation: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            try execute(emit: { print($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private func execute(emit: @escaping (String) -> Void) throws {
            let actionID = "msa.annotation.delete"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA annotation delete.")

            do {
                emitter.emitProgress(actionID: actionID, progress: 0.20, message: "Loading MSA annotation store.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let store = try bundle.loadAnnotationStore()
                let existing = try resolveMSAAnnotation(annotation, in: store)
                let updatedStore = MultipleSequenceAlignmentBundle.AnnotationStore(
                    schemaVersion: store.schemaVersion,
                    sourceAnnotations: store.sourceAnnotations.filter { $0.id != existing.id },
                    projectedAnnotations: store.projectedAnnotations.filter { $0.id != existing.id }
                )

                emitter.emitProgress(actionID: actionID, progress: 0.75, message: "Writing annotation deletion and provenance.")
                let updated = try bundle.replacingAnnotationStore(
                    updatedStore,
                    editDescription: "Delete MSA annotation \(existing.id)",
                    argv: canonicalAnnotateDeleteArgv(bundleURL: bundleURL),
                    workflowName: "multiple-sequence-alignment-annotation-delete",
                    toolName: "lungfish msa annotate delete"
                )

                emitter.emitComplete(actionID: actionID, output: updated.url.path, warningCount: 0)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Deleted annotation \(existing.id)")
                    emit("Bundle: \(updated.url.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalAnnotateDeleteArgv(bundleURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "annotate",
                "delete",
                bundleURL.path,
                "--annotation",
                annotation,
            ]
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct ProjectSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "project",
            abstract: "Project an MSA annotation to target rows"
        )

        @Argument(help: "Input .lungfishmsa bundle to update")
        var bundlePath: String

        @Option(name: .customLong("source-annotation"), help: "Source annotation ID or source annotation ID")
        var sourceAnnotation: String

        @Option(name: .customLong("target-rows"), help: "Comma-separated target row IDs, display names, source names, or 'all'")
        var targetRows: String

        @Option(name: .customLong("conflict-policy"), help: "Conflict policy. Currently supported: append")
        var conflictPolicy: String = "append"

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            try execute(emit: { print($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private func execute(emit: @escaping (String) -> Void) throws {
            let emitter = MSAActionCLIEventEmitter(
                enabled: globalOptions.outputFormat == .json,
                emit: emit
            )
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let actionID = "msa.annotation.project"
            emitter.emitStart(actionID: actionID, message: "Starting MSA annotation projection.")

            do {
                guard conflictPolicy == MultipleSequenceAlignmentBundle.AnnotationProjectionConflictPolicy.append.rawValue else {
                    throw ValidationError("Unsupported MSA annotation projection conflict policy '\(conflictPolicy)'. Currently supported: append.")
                }
                let parsedConflictPolicy = MultipleSequenceAlignmentBundle.AnnotationProjectionConflictPolicy.append

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle and annotation store.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let store = try bundle.loadAnnotationStore()
                let annotation = try resolveMSAAnnotation(sourceAnnotation, in: store)
                let targetRows = try resolveMSATargetRows(targetRows, in: bundle)
                    .filter { $0.id != annotation.rowID }
                guard targetRows.isEmpty == false else {
                    throw ValidationError("No target rows remain after excluding the source annotation row.")
                }
                let coordinateMaps = try bundle.loadCoordinateMaps()
                let mapsByRowID = Dictionary(uniqueKeysWithValues: coordinateMaps.map { ($0.rowID, $0) })

                emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Projecting annotation through aligned columns.")
                let projected = try targetRows.map { row in
                    guard let targetMap = mapsByRowID[row.id] else {
                        throw ValidationError("No coordinate map found for target row \(row.displayName).")
                    }
                    return MultipleSequenceAlignmentBundle.projectAnnotation(
                        annotation,
                        to: targetMap,
                        conflictPolicy: parsedConflictPolicy
                    )
                }

                emitter.emitProgress(actionID: actionID, progress: 0.82, message: "Writing projected annotations and provenance.")
                let argv = canonicalAnnotateProjectArgv(bundleURL: bundleURL)
                let updated = try bundle.appendingAnnotations(
                    projected,
                    editDescription: "Apply MSA annotation to selected rows",
                    argv: argv,
                    workflowName: "multiple-sequence-alignment-annotation-project",
                    toolName: "lungfish msa annotate project"
                )

                let warningCount = projected.reduce(0) { $0 + $1.warnings.count }
                emitter.emitComplete(actionID: actionID, output: updated.url.path, warningCount: warningCount)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Projected annotation \(annotation.id)")
                    emit("Bundle: \(updated.url.path)")
                    emit("Target rows: \(projected.map(\.rowName).joined(separator: ", "))")
                    if warningCount > 0 {
                        emit("Warnings: \(projected.flatMap(\.warnings).joined(separator: "; "))")
                    }
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalAnnotateProjectArgv(bundleURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "annotate",
                "project",
                bundleURL.path,
                "--source-annotation",
                sourceAnnotation,
                "--target-rows",
                targetRows,
                "--conflict-policy",
                conflictPolicy,
            ]
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct ExportSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export a .lungfishmsa alignment with provenance"
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var bundlePath: String

        @Option(name: .customLong("output-format"), help: "Output format: fasta, aligned-fasta, phylip, nexus, clustal, stockholm, a2m, or a3m")
        var outputFormat: String = "fasta"

        @Option(name: .customLong("output"), help: "Output file path")
        var outputPath: String

        @Option(name: .customLong("rows"), help: "Optional comma-separated row IDs or display names")
        var rows: String?

        @Option(name: .customLong("columns"), help: "Optional 1-based aligned column ranges, e.g. 10-40,55")
        var columns: String?

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
            let emitter = MSAActionCLIEventEmitter(
                enabled: globalOptions.outputFormat == .json,
                emit: emit
            )
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            let actionID: String = switch outputFormat {
            case "fasta":
                "msa.export.fasta"
            case "aligned-fasta":
                "msa.export.aligned-fasta"
            default:
                "msa.export.alignment-formats"
            }
            emitter.emitStart(actionID: actionID, message: "Starting MSA export.")

            do {
                guard supportedAlignmentExportFormats.contains(outputFormat) else {
                    throw ValidationError("Unsupported MSA export format '\(outputFormat)'. Supported formats: \(supportedAlignmentExportFormats.sorted().joined(separator: ", ")).")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let records = try parseAlignedFASTA(at: fastaURL)
                let selectedRecords = try selectAlignedRecords(
                    records: records,
                    bundle: bundle,
                    rows: rows,
                    columns: columns,
                    renameColumnSubsets: false
                )
                let sequenceLayout = outputFormat == "fasta" ? "ungapped" : "aligned"
                let outputRecords = outputFormat == "fasta"
                    ? ungappedRecords(selectedRecords)
                    : selectedRecords
                let warnings = exportWarnings(for: bundle, outputFormat: outputFormat)
                for warning in warnings {
                    emitter.emitWarning(actionID: actionID, message: warning, warningCount: warnings.count)
                }

                emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Writing \(outputFormat) alignment.")
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let output = try formatAlignment(records: outputRecords, outputFormat: outputFormat)
                try Data(output.utf8).write(to: outputURL, options: .atomic)

                emitter.emitProgress(actionID: actionID, progress: 0.82, message: "Writing export provenance.")
                let argv = canonicalExportArgv(bundleURL: bundleURL, outputURL: outputURL)
                let provenanceURL = outputURL.appendingPathExtension("lungfish-provenance.json")
                let provenance = try MSAFileExportProvenance(
                    actionID: actionID,
                    argv: argv,
                    reproducibleCommand: shellCommand(argv),
                    inputBundle: .init(
                        path: bundleURL.path,
                        checksumSHA256: bundleDigest(from: bundle.manifest),
                        fileSize: bundle.manifest.fileSizes.values.reduce(0, +)
                    ),
                    inputAlignmentFile: fileRecord(at: fastaURL),
                    outputFile: fileRecord(at: outputURL),
                    options: .init(
                        outputFormat: outputFormat,
                        rows: rows,
                        columns: columns,
                        selectedRowCount: selectedRecords.count,
                        selectedColumnCount: selectedRecords.first?.sequence.count ?? 0,
                        outputKind: nil,
                        name: nil,
                        threshold: nil,
                        gapPolicy: nil,
                        distanceModel: nil,
                        sequenceLayout: sequenceLayout
                    ),
                    exitStatus: 0,
                    wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt)),
                    warnings: warnings
                )
                try writeJSON(provenance, to: provenanceURL)

                emitter.emitComplete(actionID: actionID, output: outputURL.path, warningCount: warnings.count)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Exported \(outputURL.path)")
                    emit("Rows: \(outputRecords.count)")
                    emit("Columns: \(outputRecords.first?.sequence.count ?? 0)")
                    if warnings.isEmpty == false {
                        emit("Warnings: \(warnings.joined(separator: "; "))")
                    }
                    emit("Provenance: \(provenanceURL.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalExportArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "export",
                bundleURL.path,
                "--output-format",
                outputFormat,
                "--output",
                outputURL.path,
            ]
            if let rows {
                argv += ["--rows", rows]
            }
            if let columns {
                argv += ["--columns", columns]
            }
            if force {
                argv += ["--force"]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }

        private func exportWarnings(
            for bundle: MultipleSequenceAlignmentBundle,
            outputFormat: String
        ) -> [String] {
            let annotationCount = (try? bundle.loadAnnotationStore().allAnnotations.count) ?? 0
            guard annotationCount > 0 else { return [] }
            return [
                "Export format \(outputFormat) does not preserve MSA annotations; \(annotationCount) annotation(s) remain in the source .lungfishmsa bundle.",
            ]
        }
    }

    struct ConsensusSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "consensus",
            abstract: "Create a consensus sequence from a .lungfishmsa bundle"
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var bundlePath: String

        @Option(name: .customLong("output-kind"), help: "Output kind: fasta or reference")
        var outputKind: String = "fasta"

        @Option(name: .customLong("output"), help: "Output FASTA path or .lungfishref bundle path")
        var outputPath: String

        @Option(name: .customLong("name"), help: "Consensus FASTA record name")
        var name: String?

        @Option(name: .customLong("rows"), help: "Optional comma-separated row IDs or display names")
        var rows: String?

        @Option(name: .customLong("threshold"), help: "Minimum non-gap residue fraction required for a consensus base")
        var threshold: Double = 0.6

        @Option(name: .customLong("gap-policy"), help: "Gap policy: omit or include")
        var gapPolicy: String = "omit"

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
            let actionID = "msa.transform.consensus"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA consensus.")

            do {
                guard threshold > 0, threshold <= 1 else {
                    throw ValidationError("--threshold must be > 0 and <= 1.")
                }
                guard ["omit", "include"].contains(gapPolicy) else {
                    throw ValidationError("Unsupported gap policy '\(gapPolicy)'. Supported values: omit, include.")
                }
                guard ["fasta", "reference"].contains(outputKind) else {
                    throw ValidationError("Unsupported MSA consensus output kind '\(outputKind)'. Supported values: fasta, reference.")
                }
                if outputKind == "reference", gapPolicy != "omit" {
                    throw ValidationError("MSA consensus reference output requires --gap-policy omit.")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let records = try selectAlignedRecords(
                    records: parseAlignedFASTA(at: fastaURL),
                    bundle: bundle,
                    rows: rows,
                    columns: nil,
                    renameColumnSubsets: false
                )

                emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Computing consensus.")
                let consensus = try consensusSequence(records: records, threshold: threshold, gapPolicy: gapPolicy)
                let recordName = name ?? "\(bundle.manifest.name)-consensus"
                let argv = canonicalConsensusArgv(bundleURL: bundleURL, outputURL: outputURL)

                switch outputKind {
                case "fasta":
                    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(formatFASTA(records: [AlignedFASTARecord(name: recordName, sequence: consensus)]).utf8)
                        .write(to: outputURL, options: .atomic)

                    emitter.emitProgress(actionID: actionID, progress: 0.82, message: "Writing consensus provenance.")
                    try writeJSON(
                        try MSAFileExportProvenance(
                            workflowName: "multiple-sequence-alignment-consensus",
                            actionID: actionID,
                            toolName: "lungfish msa consensus",
                            argv: argv,
                            reproducibleCommand: shellCommand(argv),
                            inputBundle: .init(
                                path: bundleURL.path,
                                checksumSHA256: bundleDigest(from: bundle.manifest),
                                fileSize: bundle.manifest.fileSizes.values.reduce(0, +)
                            ),
                            inputAlignmentFile: fileRecord(at: fastaURL),
                            outputFile: fileRecord(at: outputURL),
                            options: .init(
                                outputFormat: "fasta",
                                rows: rows,
                                columns: nil,
                                selectedRowCount: records.count,
                                selectedColumnCount: consensus.count,
                                outputKind: "fasta",
                                name: recordName,
                                threshold: threshold,
                                gapPolicy: gapPolicy,
                                distanceModel: nil
                            ),
                            exitStatus: 0,
                            wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
                        ),
                        to: outputURL.appendingPathExtension("lungfish-provenance.json")
                    )
                case "reference":
                    emitter.emitProgress(actionID: actionID, progress: 0.82, message: "Writing consensus .lungfishref bundle.")
                    _ = try MSAReferenceBundleBuilder.buildConsensus(
                        request: MSAConsensusReferenceBundleBuildRequest(
                            sourceBundleURL: bundleURL,
                            sourceBundleName: bundle.manifest.name,
                            sourceBundleChecksumSHA256: bundleDigest(from: bundle.manifest),
                            sourceBundleFileSize: bundle.manifest.fileSizes.values.reduce(0, +),
                            inputAlignmentFileURL: fastaURL,
                            outputBundleURL: outputURL,
                            name: recordName,
                            consensusSequence: consensus,
                            alignmentColumns: Array(0..<bundle.manifest.alignedLength),
                            rowsOption: rows,
                            threshold: threshold,
                            gapPolicy: gapPolicy,
                            argv: argv,
                            reproducibleCommand: shellCommand(argv),
                            workflowName: "multiple-sequence-alignment-consensus-reference",
                            actionID: actionID,
                            toolName: "lungfish msa consensus",
                            startedAt: startedAt,
                            force: force
                        )
                    )
                default:
                    break
                }

                emitter.emitComplete(actionID: actionID, output: outputURL.path, warningCount: 0)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Wrote consensus \(outputURL.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalConsensusArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "consensus",
                bundleURL.path,
                "--output-kind",
                outputKind,
                "--output",
                outputURL.path,
                "--threshold",
                String(threshold),
                "--gap-policy",
                gapPolicy,
            ]
            if let name {
                argv += ["--name", name]
            }
            if let rows {
                argv += ["--rows", rows]
            }
            if force {
                argv += ["--force"]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct ExtractSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "extract",
            abstract: "Extract selected rows and columns from a .lungfishmsa bundle"
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var bundlePath: String

        @Option(name: .customLong("output-kind"), help: "Output kind: fasta or msa")
        var outputKind: String = "fasta"

        @Option(name: .customLong("output"), help: "Output file or .lungfishmsa bundle path")
        var outputPath: String

        @Option(name: .customLong("rows"), help: "Optional comma-separated row IDs or display names")
        var rows: String?

        @Option(name: .customLong("columns"), help: "Optional 1-based aligned column ranges, e.g. 10-40,55")
        var columns: String?

        @Option(name: .customLong("name"), help: "Output bundle or FASTA record-set name")
        var name: String?

        @Flag(name: .customLong("force"), help: "Overwrite an existing output")
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
            let actionID = "msa.transform.extract-selection"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA extraction.")

            do {
                guard ["fasta", "msa", "reference"].contains(outputKind) else {
                    throw ValidationError("Unsupported MSA extraction output kind '\(outputKind)'. Supported values: fasta, msa, reference.")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output already exists: \(outputURL.path). Use --force to overwrite.")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force {
                    try FileManager.default.removeItem(at: outputURL)
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let alignedRecords = try parseAlignedFASTA(at: fastaURL)
                let selectedRecords = try selectAlignedRecords(
                    records: alignedRecords,
                    bundle: bundle,
                    rows: rows,
                    columns: columns,
                    renameColumnSubsets: true
                )
                let argv = canonicalExtractArgv(bundleURL: bundleURL, outputURL: outputURL)

                switch outputKind {
                case "fasta":
                    emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Writing extracted FASTA.")
                    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let outputRecords = ungappedRecords(selectedRecords)
                    try Data(formatFASTA(records: outputRecords).utf8).write(to: outputURL, options: .atomic)
                    try writeJSON(
                        try MSAFileExportProvenance(
                            workflowName: "multiple-sequence-alignment-extract",
                            actionID: actionID,
                            toolName: "lungfish msa extract",
                            argv: argv,
                            reproducibleCommand: shellCommand(argv),
                            inputBundle: .init(
                                path: bundleURL.path,
                                checksumSHA256: bundleDigest(from: bundle.manifest),
                                fileSize: bundle.manifest.fileSizes.values.reduce(0, +)
                            ),
                            inputAlignmentFile: fileRecord(at: fastaURL),
                            outputFile: fileRecord(at: outputURL),
                            options: .init(
                                outputFormat: "fasta",
                                rows: rows,
                                columns: columns,
                                selectedRowCount: selectedRecords.count,
                                selectedColumnCount: selectedRecords.first?.sequence.count ?? 0,
                                outputKind: outputKind,
                                name: name,
                                threshold: nil,
                                gapPolicy: nil,
                                distanceModel: nil,
                                sequenceLayout: "ungapped"
                            ),
                            exitStatus: 0,
                            wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
                        ),
                        to: outputURL.appendingPathExtension("lungfish-provenance.json")
                    )
                case "msa":
                    emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Writing derived .lungfishmsa bundle.")
                    let stagingURL = try writeStagedAlignmentInput(
                        records: selectedRecords,
                        outputURL: outputURL
                    )
                    defer { try? FileManager.default.removeItem(at: stagingURL.deletingLastPathComponent()) }
                    _ = try MultipleSequenceAlignmentBundle.importAlignment(
                        from: stagingURL,
                        to: outputURL,
                        options: .init(
                            name: name ?? outputURL.deletingPathExtension().lastPathComponent,
                            sourceFormat: .alignedFASTA,
                            argv: argv,
                            reproducibleCommand: shellCommand(argv),
                            workflowName: "multiple-sequence-alignment-extract",
                            toolName: "lungfish msa extract",
                            inputFiles: [try MultipleSequenceAlignmentBundle.fileRecordForProvenance(at: bundleURL)],
                            extraWarnings: extractWarnings(),
                            sourceRowMetadata: derivedSourceRowMetadata(
                                records: selectedRecords,
                                sourceBundleURL: bundleURL
                            )
                        )
                    )
                    try addSelectionMetadataToBundleProvenance(
                        bundleURL: outputURL,
                        rows: rows,
                        columns: columns,
                        outputKind: outputKind
                    )
                case "reference":
                    emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Writing native .lungfishref bundle.")
                    let columnRanges = try parseColumnRanges(columns, alignedLength: bundle.manifest.alignedLength)
                    let referenceInputs = try selectMSAReferenceSequenceInputs(
                        records: alignedRecords,
                        bundle: bundle,
                        rows: rows,
                        columnRanges: columnRanges
                    )
                    _ = try MSAReferenceBundleBuilder.build(
                        request: MSAReferenceBundleBuildRequest(
                            sourceBundleURL: bundleURL,
                            sourceBundleName: bundle.manifest.name,
                            sourceBundleChecksumSHA256: bundleDigest(from: bundle.manifest),
                            sourceBundleFileSize: bundle.manifest.fileSizes.values.reduce(0, +),
                            inputAlignmentFileURL: fastaURL,
                            outputBundleURL: outputURL,
                            name: name ?? outputURL.deletingPathExtension().lastPathComponent,
                            rowsOption: rows,
                            columnsOption: columns,
                            selectedColumnIntervals: columnRangesForReferenceMetadata(
                                columnRanges,
                                alignedLength: bundle.manifest.alignedLength
                            ),
                            sequences: referenceInputs,
                            sourceAnnotations: (try? bundle.loadAnnotationStore().allAnnotations) ?? [],
                            argv: argv,
                            reproducibleCommand: shellCommand(argv),
                            workflowName: "multiple-sequence-alignment-extract-reference",
                            actionID: actionID,
                            toolName: "lungfish msa extract",
                            startedAt: startedAt,
                            force: force
                        )
                    )
                default:
                    break
                }

                emitter.emitProgress(actionID: actionID, progress: 0.92, message: "Extraction complete.")
                emitter.emitComplete(actionID: actionID, output: outputURL.path, warningCount: 0)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Extracted \(outputURL.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func extractWarnings() -> [String] {
            columns == nil ? [] : ["Derived alignment contains selected alignment columns only."]
        }

        private func canonicalExtractArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "extract",
                bundleURL.path,
                "--output-kind",
                outputKind,
                "--output",
                outputURL.path,
            ]
            if let rows {
                argv += ["--rows", rows]
            }
            if let columns {
                argv += ["--columns", columns]
            }
            if let name {
                argv += ["--name", name]
            }
            if force {
                argv += ["--force"]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct MaskSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mask",
            abstract: "Create derived MSA bundles with non-destructive masks",
            subcommands: [
                MaskColumnsSubcommand.self,
            ]
        )
    }

    struct MaskColumnsSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "columns",
            abstract: "Create a derived .lungfishmsa bundle with masked alignment columns"
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var bundlePath: String

        @Option(name: .customLong("ranges"), help: "1-based aligned column ranges to mask, e.g. 10-40,55")
        var ranges: String?

        @Option(name: .customLong("gap-threshold"), help: "Mask columns with gap fraction greater than or equal to this value")
        var gapThreshold: Double?

        @Option(name: .customLong("conservation-below"), help: "Mask columns whose non-gap majority residue fraction is below this value")
        var conservationBelow: Double?

        @Flag(name: .customLong("parsimony-uninformative"), help: "Mask columns that are not parsimony-informative")
        var parsimonyUninformative: Bool = false

        @Option(name: .customLong("annotation"), help: "Mask columns spanned by an MSA annotation ID or source annotation ID")
        var annotation: String?

        @Option(name: .customLong("codon-position"), help: "Mask columns corresponding to CDS codon position 1, 2, or 3")
        var codonPosition: Int?

        @Option(name: .customLong("output"), help: "Output .lungfishmsa bundle path")
        var outputPath: String

        @Option(name: .customLong("name"), help: "Output bundle name")
        var name: String?

        @Option(name: .customLong("reason"), help: "Optional mask reason")
        var reason: String?

        @Flag(name: .customLong("force"), help: "Overwrite an existing output bundle")
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
            let actionID = "msa.transform.mask-columns"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA column masking.")

            do {
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output already exists: \(outputURL.path). Use --force to overwrite.")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force {
                    try FileManager.default.removeItem(at: outputURL)
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let records = try parseAlignedFASTA(at: fastaURL)
                try validateRectangular(records)
                let resolvedMask = try resolveMaskColumns(bundle: bundle, records: records)
                let columnRanges = resolvedMask.ranges
                guard columnRanges.isEmpty == false else {
                    throw ValidationError("Mask selector did not match any alignment columns.")
                }
                let maskedColumnCount = Set(columnRanges.flatMap { range in Array(range) }).count
                let maskID = "mask-\(UUID().uuidString)"
                let maskMetadata = MSAColumnMaskMetadata(
                    masks: [
                        MSAColumnMaskRecord(
                            id: maskID,
                            mode: resolvedMask.selector,
                            ranges: oneBasedColumnMaskRanges(columnRanges),
                            maskedColumnCount: maskedColumnCount,
                            gapThreshold: resolvedMask.gapThreshold,
                            conservationThreshold: resolvedMask.conservationThreshold,
                            sourceAnnotationID: resolvedMask.annotationID,
                            codonPosition: resolvedMask.codonPosition,
                            siteClass: resolvedMask.siteClass,
                            reason: reason,
                            createdAt: startedAt
                        ),
                    ]
                )

                emitter.emitProgress(actionID: actionID, progress: 0.50, message: "Writing derived bundle inputs.")
                let stagingAlignmentURL = try writeStagedAlignmentInput(records: records, outputURL: outputURL)
                let stagingDir = stagingAlignmentURL.deletingLastPathComponent()
                defer { try? FileManager.default.removeItem(at: stagingDir) }
                let stagingMasksURL = stagingDir.appendingPathComponent("masks.json")
                try writeJSON(maskMetadata, to: stagingMasksURL)

                let argv = canonicalMaskColumnsArgv(bundleURL: bundleURL, outputURL: outputURL)
                emitter.emitProgress(actionID: actionID, progress: 0.72, message: "Creating derived .lungfishmsa bundle.")
                _ = try MultipleSequenceAlignmentBundle.importAlignment(
                    from: stagingAlignmentURL,
                    to: outputURL,
                    options: .init(
                        name: name ?? outputURL.deletingPathExtension().lastPathComponent,
                        sourceFormat: .alignedFASTA,
                        argv: argv,
                        reproducibleCommand: shellCommand(argv),
                        workflowName: "multiple-sequence-alignment-mask-columns",
                        toolName: "lungfish msa mask columns",
                        inputFiles: [try MultipleSequenceAlignmentBundle.fileRecordForProvenance(at: bundleURL)],
                        additionalFiles: [
                            .init(sourceURL: stagingMasksURL, relativePath: "metadata/masks.json"),
                        ],
                        sourceRowMetadata: derivedSourceRowMetadata(
                            records: records,
                            sourceBundleURL: bundleURL
                        ),
                        extraCapabilities: ["column-masks", "derived-alignment"]
                    )
                )
                try addMaskMetadataToBundleProvenance(
                    bundleURL: outputURL,
                    maskID: maskID,
                    selector: resolvedMask.selector,
                    ranges: resolvedMask.rangeDescription,
                    gapThreshold: resolvedMask.gapThreshold,
                    conservationThreshold: resolvedMask.conservationThreshold,
                    annotationID: resolvedMask.annotationID,
                    codonPosition: resolvedMask.codonPosition,
                    siteClass: resolvedMask.siteClass,
                    maskedColumnCount: maskedColumnCount,
                    reason: reason
                )

                emitter.emitComplete(actionID: actionID, output: outputURL.path, warningCount: 0)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Masked \(maskedColumnCount) alignment column(s)")
                    emit("Bundle: \(outputURL.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalMaskColumnsArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "mask",
                "columns",
                bundleURL.path,
            ]
            if let ranges {
                argv += ["--ranges", ranges]
            }
            if let gapThreshold {
                argv += ["--gap-threshold", String(gapThreshold)]
            }
            if let conservationBelow {
                argv += ["--conservation-below", String(conservationBelow)]
            }
            if parsimonyUninformative {
                argv += ["--parsimony-uninformative"]
            }
            if let annotation {
                argv += ["--annotation", annotation]
            }
            if let codonPosition {
                argv += ["--codon-position", String(codonPosition)]
            }
            argv += ["--output", outputURL.path]
            if let name {
                argv += ["--name", name]
            }
            if let reason {
                argv += ["--reason", reason]
            }
            if force {
                argv += ["--force"]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }

        private func resolveMaskColumns(
            bundle: MultipleSequenceAlignmentBundle,
            records: [AlignedFASTARecord]
        ) throws -> (ranges: [ClosedRange<Int>], selector: String, rangeDescription: String, gapThreshold: Double?, conservationThreshold: Double?, annotationID: String?, codonPosition: Int?, siteClass: String?) {
            let selectors = [
                ranges?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                gapThreshold != nil,
                conservationBelow != nil,
                parsimonyUninformative,
                annotation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                codonPosition != nil,
            ].filter { $0 }.count
            guard selectors == 1 else {
                throw ValidationError("Specify exactly one MSA mask selector: --ranges, --gap-threshold, --conservation-below, --parsimony-uninformative, --annotation, or --codon-position.")
            }

            if let ranges {
                let parsed = try parseColumnRanges(ranges, alignedLength: bundle.manifest.alignedLength)
                return (parsed, "columns", ranges, nil, nil, nil, nil, nil)
            }

            if let gapThreshold {
                guard gapThreshold >= 0, gapThreshold <= 1 else {
                    throw ValidationError("--gap-threshold must be >= 0 and <= 1.")
                }
                let selected = try columnGapFractions(records).enumerated()
                    .filter { $0.element >= gapThreshold }
                    .map { $0.offset...$0.offset }
                return (
                    selected,
                    "gap-threshold",
                    oneBasedColumnRangesFromIndexes(selected.map(\.lowerBound))
                        .map { "\($0.startColumn)-\($0.endColumn)" }
                        .joined(separator: ","),
                    gapThreshold,
                    nil,
                    nil,
                    nil,
                    nil
                )
            }

            if let conservationBelow {
                guard conservationBelow >= 0, conservationBelow <= 1 else {
                    throw ValidationError("--conservation-below must be >= 0 and <= 1.")
                }
                let selected = try columnConservationFractions(records).enumerated()
                    .filter { $0.element < conservationBelow }
                    .map { $0.offset...$0.offset }
                return (
                    selected,
                    "conservation-below",
                    oneBasedColumnRangesFromIndexes(selected.map(\.lowerBound))
                        .map { "\($0.startColumn)-\($0.endColumn)" }
                        .joined(separator: ","),
                    nil,
                    conservationBelow,
                    nil,
                    nil,
                    nil
                )
            }

            if parsimonyUninformative {
                let selected = try parsimonyInformativeColumns(records).enumerated()
                    .filter { !$0.element }
                    .map { $0.offset...$0.offset }
                return (
                    selected,
                    "parsimony-uninformative",
                    oneBasedColumnRangesFromIndexes(selected.map(\.lowerBound))
                        .map { "\($0.startColumn)-\($0.endColumn)" }
                        .joined(separator: ","),
                    nil,
                    nil,
                    nil,
                    nil,
                    "parsimony-uninformative"
                )
            }

            if let codonPosition {
                guard (1...3).contains(codonPosition) else {
                    throw ValidationError("--codon-position must be 1, 2, or 3.")
                }
                let resolved = try resolveCodonPositionMaskColumns(
                    codonPosition: codonPosition,
                    bundle: bundle
                )
                return (
                    resolved.ranges,
                    "codon-position",
                    resolved.ranges.map { "\($0.lowerBound + 1)-\($0.upperBound + 1)" }.joined(separator: ","),
                    nil,
                    nil,
                    resolved.annotationIDs.joined(separator: ","),
                    codonPosition,
                    nil
                )
            }

            let annotationSelection = annotation ?? ""
            let store = try bundle.loadAnnotationStore()
            let resolvedAnnotation = try resolveMSAAnnotation(annotationSelection, in: store)
            let annotationRanges = try resolvedAnnotation.alignedIntervals.map { interval -> ClosedRange<Int> in
                guard interval.start >= 0,
                      interval.end > interval.start,
                      interval.end <= bundle.manifest.alignedLength else {
                    throw ValidationError("MSA annotation \(resolvedAnnotation.id) contains an invalid aligned interval.")
                }
                return interval.start...(interval.end - 1)
            }
            return (
                annotationRanges,
                "annotation",
                annotationRanges.map { "\($0.lowerBound + 1)-\($0.upperBound + 1)" }.joined(separator: ","),
                nil,
                nil,
                resolvedAnnotation.id,
                nil,
                nil
            )
        }

        private func resolveCodonPositionMaskColumns(
            codonPosition: Int,
            bundle: MultipleSequenceAlignmentBundle
        ) throws -> (ranges: [ClosedRange<Int>], annotationIDs: [String]) {
            let store = try bundle.loadAnnotationStore()
            let cdsAnnotations = store.allAnnotations.filter { $0.type.caseInsensitiveCompare("CDS") == .orderedSame }
            guard cdsAnnotations.isEmpty == false else {
                throw ValidationError("No CDS annotations are available for --codon-position masking.")
            }

            let coordinateMaps = try bundle.loadCoordinateMaps()
            let mapsByRowID = Dictionary(uniqueKeysWithValues: coordinateMaps.map { ($0.rowID, $0) })
            var selectedColumns = Set<Int>()
            var usedAnnotationIDs: [String] = []

            for annotation in cdsAnnotations.sorted(by: { $0.id < $1.id }) {
                guard let coordinateMap = mapsByRowID[annotation.rowID] else { continue }
                var frameOffset = 0
                var annotationSelectedColumnCount = 0
                for interval in annotation.sourceIntervals.sorted(by: { lhs, rhs in
                    lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
                }) {
                    guard interval.start < interval.end else { continue }
                    for ungappedCoordinate in interval.start..<interval.end {
                        defer { frameOffset += 1 }
                        guard (frameOffset % 3) + 1 == codonPosition,
                              coordinateMap.ungappedToAlignment.indices.contains(ungappedCoordinate) else {
                            continue
                        }
                        let alignmentColumn = coordinateMap.ungappedToAlignment[ungappedCoordinate]
                        guard alignmentColumn >= 0,
                              alignmentColumn < bundle.manifest.alignedLength else {
                            continue
                        }
                        selectedColumns.insert(alignmentColumn)
                        annotationSelectedColumnCount += 1
                    }
                }
                if annotationSelectedColumnCount > 0 {
                    usedAnnotationIDs.append(annotation.id)
                }
            }

            let ranges = closedColumnRanges(fromIndexes: Array(selectedColumns))
            guard ranges.isEmpty == false else {
                throw ValidationError("CDS annotations did not contain any codon position \(codonPosition) bases.")
            }
            return (ranges, usedAnnotationIDs)
        }
    }

    struct TrimSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "trim",
            abstract: "Create derived MSA bundles with removed columns",
            subcommands: [
                TrimColumnsSubcommand.self,
            ]
        )
    }

    struct TrimColumnsSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "columns",
            abstract: "Create a derived .lungfishmsa bundle with trimmed alignment columns"
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var bundlePath: String

        @Flag(name: .customLong("gap-only"), help: "Remove columns where every row has a gap")
        var gapOnly: Bool = false

        @Option(name: .customLong("gap-threshold"), help: "Remove columns with gap fraction greater than this value")
        var gapThreshold: Double?

        @Option(name: .customLong("output"), help: "Output .lungfishmsa bundle path")
        var outputPath: String

        @Option(name: .customLong("name"), help: "Output bundle name")
        var name: String?

        @Flag(name: .customLong("force"), help: "Overwrite an existing output bundle")
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
            let actionID = "msa.transform.trim-columns"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA column trimming.")

            do {
                guard gapOnly != (gapThreshold != nil) else {
                    throw ValidationError("Specify exactly one trim mode: --gap-only or --gap-threshold.")
                }
                if let gapThreshold, gapThreshold < 0 || gapThreshold > 1 {
                    throw ValidationError("--gap-threshold must be >= 0 and <= 1.")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output already exists: \(outputURL.path). Use --force to overwrite.")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force {
                    try FileManager.default.removeItem(at: outputURL)
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                _ = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let records = try parseAlignedFASTA(at: fastaURL)
                try validateRectangular(records)
                let gapFractions = try columnGapFractions(records)
                let removedColumns: [Int]
                let mode: String
                if gapOnly {
                    mode = "gap-only"
                    removedColumns = gapFractions.enumerated()
                        .filter { $0.element == 1 }
                        .map(\.offset)
                } else {
                    let threshold = gapThreshold ?? 1
                    mode = "gap-threshold"
                    removedColumns = gapFractions.enumerated()
                        .filter { $0.element > threshold }
                        .map(\.offset)
                }
                let removedSet = Set(removedColumns)
                let retainedColumnCount = (records.first?.sequence.count ?? 0) - removedSet.count
                guard retainedColumnCount > 0 else {
                    throw ValidationError("Trim would remove every alignment column.")
                }

                emitter.emitProgress(actionID: actionID, progress: 0.45, message: "Writing trimmed alignment.")
                let trimmed = trimRecords(records, removingColumns: removedSet)
                let trimMetadata = MSATrimMetadata(
                    mode: mode,
                    gapThreshold: gapThreshold,
                    originalColumnCount: records.first?.sequence.count ?? 0,
                    retainedColumnCount: retainedColumnCount,
                    removedColumnCount: removedSet.count,
                    removedRanges: oneBasedColumnRangesFromIndexes(removedColumns),
                    createdAt: startedAt
                )
                let stagingAlignmentURL = try writeStagedAlignmentInput(records: trimmed, outputURL: outputURL)
                let stagingDir = stagingAlignmentURL.deletingLastPathComponent()
                defer { try? FileManager.default.removeItem(at: stagingDir) }
                let stagingTrimURL = stagingDir.appendingPathComponent("trim.json")
                try writeJSON(trimMetadata, to: stagingTrimURL)

                let argv = canonicalTrimColumnsArgv(bundleURL: bundleURL, outputURL: outputURL)
                emitter.emitProgress(actionID: actionID, progress: 0.72, message: "Creating derived .lungfishmsa bundle.")
                _ = try MultipleSequenceAlignmentBundle.importAlignment(
                    from: stagingAlignmentURL,
                    to: outputURL,
                    options: .init(
                        name: name ?? outputURL.deletingPathExtension().lastPathComponent,
                        sourceFormat: .alignedFASTA,
                        argv: argv,
                        reproducibleCommand: shellCommand(argv),
                        workflowName: "multiple-sequence-alignment-trim-columns",
                        toolName: "lungfish msa trim columns",
                        inputFiles: [try MultipleSequenceAlignmentBundle.fileRecordForProvenance(at: bundleURL)],
                        additionalFiles: [
                            .init(sourceURL: stagingTrimURL, relativePath: "metadata/trim.json"),
                        ],
                        sourceRowMetadata: derivedSourceRowMetadata(
                            records: trimmed,
                            sourceBundleURL: bundleURL
                        ),
                        extraCapabilities: ["column-trimming", "derived-alignment"]
                    )
                )
                try addTrimMetadataToBundleProvenance(
                    bundleURL: outputURL,
                    mode: mode,
                    gapThreshold: gapThreshold,
                    removedColumnCount: removedSet.count,
                    retainedColumnCount: retainedColumnCount
                )

                emitter.emitComplete(actionID: actionID, output: outputURL.path, warningCount: 0)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Trimmed \(removedSet.count) alignment column(s)")
                    emit("Bundle: \(outputURL.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalTrimColumnsArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "trim",
                "columns",
                bundleURL.path,
            ]
            if gapOnly {
                argv += ["--gap-only"]
            }
            if let gapThreshold {
                argv += ["--gap-threshold", String(gapThreshold)]
            }
            argv += ["--output", outputURL.path]
            if let name {
                argv += ["--name", name]
            }
            if force {
                argv += ["--force"]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct DistanceSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "distance",
            abstract: "Compute identity or p-distance matrices from a .lungfishmsa bundle"
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var bundlePath: String

        @Option(name: .customLong("model"), help: "Distance model: identity or p-distance")
        var model: String = "identity"

        @Option(name: .customLong("output"), help: "Output TSV matrix path")
        var outputPath: String

        @Option(name: .customLong("rows"), help: "Optional comma-separated row IDs or display names")
        var rows: String?

        @Option(name: .customLong("columns"), help: "Optional 1-based aligned column ranges, e.g. 10-40,55")
        var columns: String?

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
            let actionID = "msa.phylogenetics.distance-matrix"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA distance matrix.")

            do {
                guard supportedMSADistanceModels.contains(model) else {
                    throw ValidationError("Unsupported MSA distance model '\(model)'. Supported values: \(supportedMSADistanceModels.sorted().joined(separator: ", ")).")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let records = try selectAlignedRecords(
                    records: parseAlignedFASTA(at: fastaURL),
                    bundle: bundle,
                    rows: rows,
                    columns: columns,
                    renameColumnSubsets: false
                )
                try validateRectangular(records)

                emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Computing pairwise \(model) matrix.")
                let output = try formatDistanceMatrix(records: records, model: model)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(output.utf8).write(to: outputURL, options: .atomic)

                emitter.emitProgress(actionID: actionID, progress: 0.82, message: "Writing distance-matrix provenance.")
                let argv = canonicalDistanceArgv(bundleURL: bundleURL, outputURL: outputURL)
                try writeJSON(
                    try MSAFileExportProvenance(
                        workflowName: "multiple-sequence-alignment-distance-matrix",
                        actionID: actionID,
                        toolName: "lungfish msa distance",
                        argv: argv,
                        reproducibleCommand: shellCommand(argv),
                        inputBundle: .init(
                            path: bundleURL.path,
                            checksumSHA256: bundleDigest(from: bundle.manifest),
                            fileSize: bundle.manifest.fileSizes.values.reduce(0, +)
                        ),
                        inputAlignmentFile: fileRecord(at: fastaURL),
                        outputFile: fileRecord(at: outputURL),
                        options: .init(
                            outputFormat: "tsv",
                            rows: rows,
                            columns: columns,
                            selectedRowCount: records.count,
                            selectedColumnCount: records.first?.sequence.count ?? 0,
                            outputKind: "distance-matrix",
                            name: nil,
                            threshold: nil,
                            gapPolicy: "pairwise-delete",
                            distanceModel: model
                        ),
                        exitStatus: 0,
                        wallTimeSeconds: max(0, Date().timeIntervalSince(startedAt))
                    ),
                    to: outputURL.appendingPathExtension("lungfish-provenance.json")
                )

                emitter.emitComplete(actionID: actionID, output: outputURL.path, warningCount: 0)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Wrote \(model) matrix \(outputURL.path)")
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalDistanceArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                "lungfish",
                "msa",
                "distance",
                bundleURL.path,
                "--model",
                model,
                "--output",
                outputURL.path,
            ]
            if let rows {
                argv += ["--rows", rows]
            }
            if let columns {
                argv += ["--columns", columns]
            }
            if force {
                argv += ["--force"]
            }
            if globalOptions.outputFormat == .json {
                argv += ["--format", "json"]
            }
            return argv
        }
    }

    struct ActionsSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "actions",
            abstract: "List registered multiple sequence alignment actions"
        )

        @Option(name: .customLong("category"), help: "Optional category filter")
        var category: String?

        @Flag(name: .customLong("cli-backed"), help: "Only show actions with a CLI contract")
        var cliBackedOnly: Bool = false

        @Flag(name: .customLong("data-changing"), help: "Only show actions that create or modify scientific data")
        var dataChangingOnly: Bool = false

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            try execute(emit: { print($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private func execute(emit: (String) -> Void) throws {
            let selected = try selectedActions()
            let payload = MSACommand.ActionsPayload(
                schemaVersion: MultipleSequenceAlignmentActionRegistry.schemaVersion,
                count: selected.count,
                references: MultipleSequenceAlignmentActionRegistry.surveyReferences,
                actions: selected
            )

            switch globalOptions.outputFormat {
            case .json:
                try emitJSON(payload, emit: emit)
            case .tsv:
                emit("id\ttitle\tcategory\tpriority\tstatus\tprovenanceRequired\tcliCommand")
                for action in selected {
                    emit([
                        action.id,
                        action.title,
                        action.category.rawValue,
                        action.priority.rawValue,
                        action.implementationStatus.rawValue,
                        action.requiresProvenance ? "true" : "false",
                        action.cli?.command ?? "",
                    ].joined(separator: "\t"))
                }
            case .text:
                emit("Multiple Sequence Alignment Actions (\(selected.count))")
                for action in selected {
                    emit("- \(action.id) [\(action.priority.rawValue), \(action.category.rawValue), \(action.implementationStatus.rawValue)]: \(action.title)")
                    if let cli = action.cli {
                        emit("  CLI: \(cli.command)")
                    }
                    if action.requiresProvenance {
                        emit("  Provenance: required")
                    }
                }
            }
        }

        private func selectedActions() throws -> [MultipleSequenceAlignmentActionDescriptor] {
            var selected = MultipleSequenceAlignmentActionRegistry.actions
            if let category {
                guard let parsed = MultipleSequenceAlignmentActionDescriptor.Category(rawValue: category) else {
                    let supported = MultipleSequenceAlignmentActionDescriptor.Category.allCases
                        .map(\.rawValue)
                        .joined(separator: ", ")
                    throw ValidationError("Unsupported MSA action category '\(category)'. Supported categories: \(supported)")
                }
                selected = selected.filter { $0.category == parsed }
            }
            if cliBackedOnly {
                selected = selected.filter { $0.cli != nil }
            }
            if dataChangingOnly {
                selected = selected.filter(\.createsOrModifiesScientificData)
            }
            return selected
        }
    }

    struct DescribeSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "describe",
            abstract: "Describe one registered multiple sequence alignment action"
        )

        @Argument(help: "Action identifier, for example msa.alignment.mafft")
        var actionID: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() throws {
            try execute(emit: { print($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private func execute(emit: (String) -> Void) throws {
            guard let action = MultipleSequenceAlignmentActionRegistry.action(id: actionID) else {
                throw ValidationError("Unknown MSA action '\(actionID)'. Run `lungfish msa actions` to list supported actions.")
            }

            switch globalOptions.outputFormat {
            case .json:
                try emitJSON(action, emit: emit)
            case .tsv:
                emit("id\ttitle\tcategory\tpriority\tstatus\tprovenanceRequired\tcliCommand")
                emit([
                    action.id,
                    action.title,
                    action.category.rawValue,
                    action.priority.rawValue,
                    action.implementationStatus.rawValue,
                    action.requiresProvenance ? "true" : "false",
                    action.cli?.command ?? "",
                ].joined(separator: "\t"))
            case .text:
                emit("\(action.title) (\(action.id))")
                emit("Category: \(action.category.rawValue)")
                emit("Priority: \(action.priority.rawValue)")
                emit("Status: \(action.implementationStatus.rawValue)")
                emit("Summary: \(action.summary)")
                emit("User intent: \(action.userIntent)")
                emit("Surfaces: \(action.surfaces.map(\.rawValue).joined(separator: ", "))")
                emit("Creates or modifies scientific data: \(action.createsOrModifiesScientificData ? "yes" : "no")")
                emit("Provenance required: \(action.requiresProvenance ? "yes" : "no")")
                if let cli = action.cli {
                    emit("CLI: \(cli.command)")
                    emit("Output: \(cli.outputContract)")
                    if cli.requiredPluginPackIDs.isEmpty == false {
                        emit("Plugin packs: \(cli.requiredPluginPackIDs.joined(separator: ", "))")
                    }
                }
                emit("Accessibility: \(action.accessibilityRequirement)")
                emit("Tests: \(action.testRequirement)")
            }
        }
    }

    private static func emitJSON<T: Encodable>(_ value: T, emit: (String) -> Void) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("Failed to encode JSON output.")
        }
        emit(text)
    }
}

private struct AlignedFASTARecord: Equatable {
    let name: String
    let sequence: String
}

private let supportedAlignmentExportFormats: Set<String> = [
    "fasta",
    "aligned-fasta",
    "phylip",
    "nexus",
    "clustal",
    "stockholm",
    "a2m",
    "a3m",
]

private let supportedMSADistanceModels: Set<String> = [
    "identity",
    "p-distance",
]

private struct MSAFileExportProvenance: Codable, Equatable {
    struct RuntimeIdentity: Codable, Equatable {
        let executablePath: String?
        let operatingSystemVersion: String
        let processIdentifier: Int32
        let condaEnvironment: String?
        let containerImage: String?
    }

    struct FileRecord: Codable, Equatable {
        let path: String
        let checksumSHA256: String
        let fileSize: Int64
    }

    struct Options: Codable, Equatable {
        let outputFormat: String
        let rows: String?
        let columns: String?
        let selectedRowCount: Int
        let selectedColumnCount: Int
        let outputKind: String?
        let name: String?
        let threshold: Double?
        let gapPolicy: String?
        let distanceModel: String?
        let sequenceLayout: String?

        init(
            outputFormat: String,
            rows: String?,
            columns: String?,
            selectedRowCount: Int,
            selectedColumnCount: Int,
            outputKind: String?,
            name: String?,
            threshold: Double?,
            gapPolicy: String?,
            distanceModel: String?,
            sequenceLayout: String? = nil
        ) {
            self.outputFormat = outputFormat
            self.rows = rows
            self.columns = columns
            self.selectedRowCount = selectedRowCount
            self.selectedColumnCount = selectedColumnCount
            self.outputKind = outputKind
            self.name = name
            self.threshold = threshold
            self.gapPolicy = gapPolicy
            self.distanceModel = distanceModel
            self.sequenceLayout = sequenceLayout
        }
    }

    let schemaVersion: Int
    let workflowName: String
    let actionID: String
    let toolName: String
    let toolVersion: String
    let argv: [String]
    let reproducibleCommand: String
    let options: Options
    let runtimeIdentity: RuntimeIdentity
    let inputBundle: FileRecord
    let inputAlignmentFile: FileRecord
    let outputFile: FileRecord
    let exitStatus: Int
    let wallTimeSeconds: Double
    let warnings: [String]
    let stderr: String?
    let createdAt: Date

    init(
        workflowName: String = "multiple-sequence-alignment-export",
        actionID: String,
        toolName: String = "lungfish msa export",
        argv: [String],
        reproducibleCommand: String,
        inputBundle: FileRecord,
        inputAlignmentFile: FileRecord,
        outputFile: FileRecord,
        options: Options,
        exitStatus: Int,
        wallTimeSeconds: Double,
        warnings: [String] = [],
        stderr: String? = nil
    ) {
        self.schemaVersion = 1
        self.workflowName = workflowName
        self.actionID = actionID
        self.toolName = toolName
        self.toolVersion = MultipleSequenceAlignmentBundle.toolVersion
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.options = options
        self.runtimeIdentity = RuntimeIdentity(
            executablePath: ProcessInfo.processInfo.arguments.first,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            condaEnvironment: ProcessInfo.processInfo.environment["CONDA_DEFAULT_ENV"],
            containerImage: ProcessInfo.processInfo.environment["LUNGFISH_CONTAINER_IMAGE"]
        )
        self.inputBundle = inputBundle
        self.inputAlignmentFile = inputAlignmentFile
        self.outputFile = outputFile
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.warnings = warnings
        self.stderr = stderr
        self.createdAt = Date()
    }
}

private struct MSAColumnMaskMetadata: Codable, Equatable {
    let schemaVersion: Int
    let masks: [MSAColumnMaskRecord]

    init(schemaVersion: Int = 1, masks: [MSAColumnMaskRecord]) {
        self.schemaVersion = schemaVersion
        self.masks = masks
    }
}

private struct MSAColumnMaskRecord: Codable, Equatable {
    let id: String
    let mode: String
    let ranges: [MSAColumnMaskRange]
    let maskedColumnCount: Int
    let gapThreshold: Double?
    let conservationThreshold: Double?
    let sourceAnnotationID: String?
    let codonPosition: Int?
    let siteClass: String?
    let reason: String?
    let createdAt: Date

    init(
        id: String,
        mode: String = "columns",
        ranges: [MSAColumnMaskRange],
        maskedColumnCount: Int,
        gapThreshold: Double? = nil,
        conservationThreshold: Double? = nil,
        sourceAnnotationID: String? = nil,
        codonPosition: Int? = nil,
        siteClass: String? = nil,
        reason: String?,
        createdAt: Date
    ) {
        self.id = id
        self.mode = mode
        self.ranges = ranges
        self.maskedColumnCount = maskedColumnCount
        self.gapThreshold = gapThreshold
        self.conservationThreshold = conservationThreshold
        self.sourceAnnotationID = sourceAnnotationID
        self.codonPosition = codonPosition
        self.siteClass = siteClass
        self.reason = reason
        self.createdAt = createdAt
    }
}

private struct MSAColumnMaskRange: Codable, Equatable {
    let startColumn: Int
    let endColumn: Int
}

private struct MSATrimMetadata: Codable, Equatable {
    let schemaVersion: Int
    let mode: String
    let gapThreshold: Double?
    let originalColumnCount: Int
    let retainedColumnCount: Int
    let removedColumnCount: Int
    let removedRanges: [MSAColumnMaskRange]
    let createdAt: Date

    init(
        schemaVersion: Int = 1,
        mode: String,
        gapThreshold: Double?,
        originalColumnCount: Int,
        retainedColumnCount: Int,
        removedColumnCount: Int,
        removedRanges: [MSAColumnMaskRange],
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.gapThreshold = gapThreshold
        self.originalColumnCount = originalColumnCount
        self.retainedColumnCount = retainedColumnCount
        self.removedColumnCount = removedColumnCount
        self.removedRanges = removedRanges
        self.createdAt = createdAt
    }
}

private final class MSAActionCLIEventEmitter: @unchecked Sendable {
    private struct Event: Encodable {
        let event: String
        let actionID: String
        let operationID: String
        let progress: Double?
        let message: String?
        let output: String?
        let warningCount: Int?
        let error: String?
    }

    private let enabled: Bool
    private let emitLine: (String) -> Void
    private let lock = NSLock()
    private let operationID: String

    init(
        enabled: Bool,
        operationID: String = UUID().uuidString,
        emit: @escaping (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }) {
        self.enabled = enabled
        self.operationID = operationID
        self.emitLine = emit
    }

    func emitStart(actionID: String, message: String) {
        emit(Event(event: "msaActionStart", actionID: actionID, operationID: operationID, progress: 0, message: message, output: nil, warningCount: nil, error: nil))
    }

    func emitProgress(actionID: String, progress: Double, message: String) {
        emit(Event(event: "msaActionProgress", actionID: actionID, operationID: operationID, progress: max(0, min(1, progress)), message: message, output: nil, warningCount: nil, error: nil))
    }

    func emitWarning(actionID: String, message: String, warningCount: Int? = nil) {
        emit(Event(event: "msaActionWarning", actionID: actionID, operationID: operationID, progress: nil, message: message, output: nil, warningCount: warningCount, error: nil))
    }

    func emitComplete(actionID: String, output: String, warningCount: Int) {
        emit(Event(event: "msaActionComplete", actionID: actionID, operationID: operationID, progress: 1, message: nil, output: output, warningCount: warningCount, error: nil))
    }

    func emitFailed(actionID: String, message: String) {
        emit(Event(event: "msaActionFailed", actionID: actionID, operationID: operationID, progress: nil, message: nil, output: nil, warningCount: nil, error: message))
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

private func parseAlignedFASTA(at url: URL) throws -> [AlignedFASTARecord] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var records: [AlignedFASTARecord] = []
    var currentName: String?
    var currentSequence = ""

    func flush() {
        guard let currentName else { return }
        records.append(AlignedFASTARecord(name: currentName, sequence: currentSequence))
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

private func selectAlignedRecords(
    records: [AlignedFASTARecord],
    bundle: MultipleSequenceAlignmentBundle,
    rows: String?,
    columns: String?,
    renameColumnSubsets: Bool
) throws -> [AlignedFASTARecord] {
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
    if selected.isEmpty {
        throw ValidationError("No MSA rows matched --rows selection.")
    }

    let columnRanges = try parseColumnRanges(columns, alignedLength: bundle.manifest.alignedLength)
    if columnRanges.isEmpty == false {
        let suffix = columnSelectionNameSuffix(columnRanges)
        selected = selected.map { record in
            let characters = Array(record.sequence)
            let subset = columnRanges.flatMap { range in
                range.map { characters[$0] }
            }
            let name = renameColumnSubsets ? "\(record.name)_\(suffix)" : record.name
            return AlignedFASTARecord(name: name, sequence: String(subset))
        }
    }
    return selected
}

private func selectMSAReferenceSequenceInputs(
    records: [AlignedFASTARecord],
    bundle: MultipleSequenceAlignmentBundle,
    rows: String?,
    columnRanges: [ClosedRange<Int>]
) throws -> [MSAReferenceSequenceInput] {
    let requestedRows: Set<String>?
    if let rows, rows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        requestedRows = Set(rows.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
    } else {
        requestedRows = nil
    }

    let rowByDisplayName = Dictionary(uniqueKeysWithValues: bundle.rows.map { ($0.displayName, $0) })
    let coordinateMapByRowID = Dictionary(uniqueKeysWithValues: try bundle.loadCoordinateMaps().map { ($0.rowID, $0) })
    let selectedColumns: [Int] = if columnRanges.isEmpty {
        Array(0..<bundle.manifest.alignedLength)
    } else {
        columnRanges.flatMap { Array($0) }
    }
    let suffix = columnRanges.isEmpty ? nil : columnSelectionNameSuffix(columnRanges)

    let selected = try records.compactMap { record -> MSAReferenceSequenceInput? in
        guard let row = rowByDisplayName[record.name] else {
            return nil
        }
        if let requestedRows,
           requestedRows.contains(row.displayName) == false,
           requestedRows.contains(row.id) == false,
           requestedRows.contains(row.sourceName) == false {
            return nil
        }
        guard let coordinateMap = coordinateMapByRowID[row.id] else {
            throw ValidationError("No coordinate map found for MSA row \(row.displayName).")
        }
        let characters = Array(record.sequence)
        let alignedSequence = String(selectedColumns.map { characters[$0] })
        let outputName = suffix.map { "\(record.name)_\($0)" } ?? record.name
        return MSAReferenceSequenceInput(
            rowID: row.id,
            rowName: row.displayName,
            sourceName: row.sourceName,
            outputName: outputName,
            alignedSequence: alignedSequence,
            alignedColumns: selectedColumns,
            coordinateMap: coordinateMap
        )
    }
    guard selected.isEmpty == false else {
        throw ValidationError("No MSA rows matched --rows selection.")
    }
    return selected
}

private func columnRangesForReferenceMetadata(
    _ columnRanges: [ClosedRange<Int>],
    alignedLength: Int
) -> [MSAReferenceColumnInterval] {
    let ranges = columnRanges.isEmpty ? [0...(alignedLength - 1)] : columnRanges
    return ranges.map { MSAReferenceColumnInterval(start: $0.lowerBound, end: $0.upperBound + 1) }
}

private func columnSelectionNameSuffix(_ ranges: [ClosedRange<Int>]) -> String {
    let text = ranges.map { "\($0.lowerBound + 1)-\($0.upperBound + 1)" }.joined(separator: "_")
    return "columns_\(text)"
}

private func formatAlignment(records: [AlignedFASTARecord], outputFormat: String) throws -> String {
    switch outputFormat {
    case "fasta":
        return formatFASTA(records: records)
    case "aligned-fasta", "a2m", "a3m":
        try validateRectangular(records)
        return formatFASTA(records: records)
    case "phylip":
        try validateRectangular(records)
        let alignedLength = records.first?.sequence.count ?? 0
        return "\(records.count) \(alignedLength)\n"
            + records.map { "\($0.name) \($0.sequence)" }.joined(separator: "\n")
            + "\n"
    case "nexus":
        try validateRectangular(records)
        let alignedLength = records.first?.sequence.count ?? 0
        return """
        #NEXUS
        begin data;
        dimensions ntax=\(records.count) nchar=\(alignedLength);
        format datatype=dna missing=? gap=-;
        matrix
        \(records.map { "\($0.name) \($0.sequence)" }.joined(separator: "\n"))
        ;
        end;

        """
    case "clustal":
        try validateRectangular(records)
        return "CLUSTAL W multiple sequence alignment\n\n"
            + records.map { "\($0.name)    \($0.sequence)" }.joined(separator: "\n")
            + "\n"
    case "stockholm":
        try validateRectangular(records)
        return "# STOCKHOLM 1.0\n"
            + records.map { "\($0.name) \($0.sequence)" }.joined(separator: "\n")
            + "\n//\n"
    default:
        throw ValidationError("Unsupported MSA export format '\(outputFormat)'.")
    }
}

private func ungappedRecords(_ records: [AlignedFASTARecord]) -> [AlignedFASTARecord] {
    records.map { record in
        AlignedFASTARecord(
            name: record.name,
            sequence: String(record.sequence.filter { !isAlignmentGap($0) })
        )
    }
}

private func formatDistanceMatrix(records: [AlignedFASTARecord], model: String) throws -> String {
    try validateRectangular(records)
    let header = "row\t" + records.map(\.name).joined(separator: "\t")
    let rows = try records.map { lhs in
        let values = try records.map { rhs in
            try formatDistanceValue(pairwiseDistanceValue(lhs: lhs, rhs: rhs, model: model))
        }
        return ([lhs.name] + values).joined(separator: "\t")
    }
    return ([header] + rows).joined(separator: "\n") + "\n"
}

private func pairwiseDistanceValue(
    lhs: AlignedFASTARecord,
    rhs: AlignedFASTARecord,
    model: String
) throws -> Double {
    let lhsCharacters = Array(lhs.sequence.uppercased())
    let rhsCharacters = Array(rhs.sequence.uppercased())
    guard lhsCharacters.count == rhsCharacters.count else {
        throw ValidationError("Selected MSA rows do not have equal aligned lengths.")
    }

    var comparable = 0
    var matches = 0
    for index in lhsCharacters.indices {
        let left = lhsCharacters[index]
        let right = rhsCharacters[index]
        if isAlignmentGap(left) || isAlignmentGap(right) {
            continue
        }
        comparable += 1
        if left == right {
            matches += 1
        }
    }
    guard comparable > 0 else {
        return Double.nan
    }

    let identity = Double(matches) / Double(comparable)
    switch model {
    case "identity":
        return identity
    case "p-distance":
        return 1 - identity
    default:
        throw ValidationError("Unsupported MSA distance model '\(model)'.")
    }
}

private func formatDistanceValue(_ value: Double) -> String {
    value.isNaN ? "nan" : String(format: "%.6f", value)
}

private func validateRectangular(_ records: [AlignedFASTARecord]) throws {
    guard let expected = records.first?.sequence.count else { return }
    let unequal = records.filter { $0.sequence.count != expected }
    if unequal.isEmpty == false {
        throw ValidationError("Selected MSA rows do not have equal aligned lengths.")
    }
}

private func consensusSequence(
    records: [AlignedFASTARecord],
    threshold: Double,
    gapPolicy: String
) throws -> String {
    try validateRectangular(records)
    guard let alignedLength = records.first?.sequence.count else { return "" }
    let charactersByRecord = records.map { Array($0.sequence) }
    var consensus = ""
    for column in 0..<alignedLength {
        var counts: [Character: Int] = [:]
        for characters in charactersByRecord {
            let residue = Character(String(characters[column]).uppercased())
            if gapPolicy == "omit", isAlignmentGap(residue) {
                continue
            }
            counts[residue, default: 0] += 1
        }
        let denominator = counts.values.reduce(0, +)
        guard denominator > 0 else {
            consensus.append("-")
            continue
        }
        let winner = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? String(lhs.key) < String(rhs.key) : lhs.value > rhs.value
        }.first!
        let fraction = Double(winner.value) / Double(denominator)
        consensus.append(fraction >= threshold ? winner.key : "N")
    }
    return consensus
}

private func isAlignmentGap(_ residue: Character) -> Bool {
    residue == "-" || residue == "."
}

private func writeStagedAlignmentInput(
    records: [AlignedFASTARecord],
    outputURL: URL
) throws -> URL {
    let stagingDir = outputURL.deletingLastPathComponent()
        .appendingPathComponent(".tmp", isDirectory: true)
        .appendingPathComponent("lungfish-msa-extract-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    let stagingURL = stagingDir.appendingPathComponent("selected.aligned.fasta")
    try Data(formatFASTA(records: records).utf8).write(to: stagingURL, options: .atomic)
    return stagingURL
}

private func derivedSourceRowMetadata(
    records: [AlignedFASTARecord],
    sourceBundleURL: URL
) -> [MultipleSequenceAlignmentBundle.SourceRowMetadataInput] {
    let sourceAlignmentPath = sourceBundleURL
        .appendingPathComponent("alignment/primary.aligned.fasta")
        .path
    return records.map { record in
        let ungapped = String(record.sequence.filter { !isAlignmentGap($0) })
        return MultipleSequenceAlignmentBundle.SourceRowMetadataInput(
            rowName: record.name,
            originalName: record.name,
            sourceSequenceName: record.name,
            sourceFilePath: sourceAlignmentPath,
            sourceFormat: "lungfishmsa-derived",
            sourceChecksumSHA256: MultipleSequenceAlignmentBundle.sha256Hex(for: Data(ungapped.utf8))
        )
    }
}

private func oneBasedColumnMaskRanges(_ ranges: [ClosedRange<Int>]) -> [MSAColumnMaskRange] {
    ranges.map { range in
        MSAColumnMaskRange(startColumn: range.lowerBound + 1, endColumn: range.upperBound + 1)
    }
}

private func oneBasedColumnRangesFromIndexes(_ indexes: [Int]) -> [MSAColumnMaskRange] {
    let sorted = Array(Set(indexes)).sorted()
    guard var start = sorted.first else { return [] }
    var previous = start
    var ranges: [MSAColumnMaskRange] = []

    for index in sorted.dropFirst() {
        if index == previous + 1 {
            previous = index
        } else {
            ranges.append(MSAColumnMaskRange(startColumn: start + 1, endColumn: previous + 1))
            start = index
            previous = index
        }
    }
    ranges.append(MSAColumnMaskRange(startColumn: start + 1, endColumn: previous + 1))
    return ranges
}

private func closedColumnRanges(fromIndexes indexes: [Int]) -> [ClosedRange<Int>] {
    let sorted = Array(Set(indexes)).sorted()
    guard var start = sorted.first else { return [] }
    var previous = start
    var ranges: [ClosedRange<Int>] = []

    for index in sorted.dropFirst() {
        if index == previous + 1 {
            previous = index
        } else {
            ranges.append(start...previous)
            start = index
            previous = index
        }
    }
    ranges.append(start...previous)
    return ranges
}

private func columnGapFractions(_ records: [AlignedFASTARecord]) throws -> [Double] {
    try validateRectangular(records)
    guard let alignedLength = records.first?.sequence.count else { return [] }
    let charactersByRecord = records.map { Array($0.sequence) }
    return (0..<alignedLength).map { column in
        let gapCount = charactersByRecord.reduce(0) { partial, characters in
            partial + (isAlignmentGap(characters[column]) ? 1 : 0)
        }
        return Double(gapCount) / Double(records.count)
    }
}

private func columnConservationFractions(_ records: [AlignedFASTARecord]) throws -> [Double] {
    try validateRectangular(records)
    guard let alignedLength = records.first?.sequence.count else { return [] }
    let charactersByRecord = records.map { Array($0.sequence) }
    return (0..<alignedLength).map { column in
        var counts: [Character: Int] = [:]
        for characters in charactersByRecord {
            let residue = Character(String(characters[column]).uppercased())
            guard !isAlignmentGap(residue) else { continue }
            counts[residue, default: 0] += 1
        }
        let denominator = counts.values.reduce(0, +)
        guard denominator > 0, let maximum = counts.values.max() else { return 0 }
        return Double(maximum) / Double(denominator)
    }
}

private func parsimonyInformativeColumns(_ records: [AlignedFASTARecord]) throws -> [Bool] {
    try validateRectangular(records)
    guard let alignedLength = records.first?.sequence.count else { return [] }
    let charactersByRecord = records.map { Array($0.sequence) }
    return (0..<alignedLength).map { column in
        var counts: [Character: Int] = [:]
        for characters in charactersByRecord {
            let residue = Character(String(characters[column]).uppercased())
            guard !isAlignmentGap(residue) else { continue }
            counts[residue, default: 0] += 1
        }
        return counts.values.filter { $0 >= 2 }.count >= 2
    }
}

private func trimRecords(
    _ records: [AlignedFASTARecord],
    removingColumns removedColumns: Set<Int>
) -> [AlignedFASTARecord] {
    records.map { record in
        let retained = Array(record.sequence).enumerated()
            .filter { removedColumns.contains($0.offset) == false }
            .map(\.element)
        return AlignedFASTARecord(name: record.name, sequence: String(retained))
    }
}

private func addSelectionMetadataToBundleProvenance(
    bundleURL: URL,
    rows: String?,
    columns: String?,
    outputKind: String
) throws {
    let provenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")
    let data = try Data(contentsOf: provenanceURL)
    var object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
    var selection: [String: Any] = ["outputKind": outputKind]
    if let rows {
        selection["rows"] = rows
    }
    if let columns {
        selection["columns"] = columns
    }
    object["selection"] = selection
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: provenanceURL, options: .atomic)
}

private func addTrimMetadataToBundleProvenance(
    bundleURL: URL,
    mode: String,
    gapThreshold: Double?,
    removedColumnCount: Int,
    retainedColumnCount: Int
) throws {
    let provenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")
    let data = try Data(contentsOf: provenanceURL)
    var object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
    var trim: [String: Any] = [
        "mode": mode,
        "removedColumnCount": removedColumnCount,
        "retainedColumnCount": retainedColumnCount,
    ]
    if let gapThreshold {
        trim["gapThreshold"] = gapThreshold
    }
    object["trim"] = trim
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: provenanceURL, options: .atomic)
}

private func addMaskMetadataToBundleProvenance(
    bundleURL: URL,
    maskID: String,
    selector: String,
    ranges: String,
    gapThreshold: Double?,
    conservationThreshold: Double?,
    annotationID: String?,
    codonPosition: Int?,
    siteClass: String?,
    maskedColumnCount: Int,
    reason: String?
) throws {
    let provenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")
    let data = try Data(contentsOf: provenanceURL)
    var object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] ?? [:]
    var mask: [String: Any] = [
        "maskID": maskID,
        "mode": selector,
        "selector": selector,
        "ranges": ranges,
        "maskedColumnCount": maskedColumnCount,
    ]
    if let gapThreshold {
        mask["gapThreshold"] = gapThreshold
    }
    if let conservationThreshold {
        mask["conservationThreshold"] = conservationThreshold
    }
    if let annotationID {
        mask["sourceAnnotationID"] = annotationID
    }
    if let codonPosition {
        mask["codonPosition"] = codonPosition
    }
    if let siteClass {
        mask["siteClass"] = siteClass
    }
    if let reason {
        mask["reason"] = reason
    }
    object["mask"] = mask
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try updated.write(to: provenanceURL, options: .atomic)
}

private func parseColumnRanges(_ value: String?, alignedLength: Int) throws -> [ClosedRange<Int>] {
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

private func resolveMSARow(
    _ rowSelection: String,
    in bundle: MultipleSequenceAlignmentBundle
) throws -> MultipleSequenceAlignmentBundle.Row {
    let matches = bundle.rows.filter { row in
        row.id == rowSelection
            || row.displayName == rowSelection
            || row.sourceName == rowSelection
    }
    guard matches.isEmpty == false else {
        throw ValidationError("No MSA row matched '\(rowSelection)'.")
    }
    guard matches.count == 1 else {
        let names = matches.map { "\($0.displayName) (\($0.id))" }.joined(separator: ", ")
        throw ValidationError("MSA row selection '\(rowSelection)' is ambiguous: \(names)")
    }
    return matches[0]
}

private func resolveMSATargetRows(
    _ targetRows: String,
    in bundle: MultipleSequenceAlignmentBundle
) throws -> [MultipleSequenceAlignmentBundle.Row] {
    let tokens = targetRows
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
    guard tokens.isEmpty == false else {
        throw ValidationError("At least one target row is required.")
    }
    if tokens.count == 1, tokens[0].lowercased() == "all" {
        return bundle.rows
    }

    var resolved: [MultipleSequenceAlignmentBundle.Row] = []
    var seen = Set<String>()
    for token in tokens {
        let row = try resolveMSARow(token, in: bundle)
        if seen.insert(row.id).inserted {
            resolved.append(row)
        }
    }
    return resolved
}

private func resolveMSAAnnotation(
    _ annotationSelection: String,
    in store: MultipleSequenceAlignmentBundle.AnnotationStore
) throws -> MultipleSequenceAlignmentBundle.AlignmentAnnotationRecord {
    let exactMatches = store.allAnnotations.filter { $0.id == annotationSelection }
    if exactMatches.count == 1 {
        return exactMatches[0]
    }
    if exactMatches.count > 1 {
        throw ValidationError("MSA annotation selection '\(annotationSelection)' matched multiple annotation IDs.")
    }

    let sourceMatches = store.allAnnotations.filter { $0.sourceAnnotationID == annotationSelection }
    guard sourceMatches.isEmpty == false else {
        throw ValidationError("No MSA annotation matched '\(annotationSelection)'.")
    }
    guard sourceMatches.count == 1 else {
        let names = sourceMatches.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        throw ValidationError("MSA annotation selection '\(annotationSelection)' is ambiguous: \(names)")
    }
    return sourceMatches[0]
}

private func parseQualifierOptions(_ qualifierOptions: [String]) throws -> [String: [String]] {
    var qualifiers: [String: [String]] = [:]
    for option in qualifierOptions {
        let parts = option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ValidationError("Invalid qualifier '\(option)'. Expected key=value.")
        }
        let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false else {
            throw ValidationError("Invalid qualifier '\(option)'. Qualifier key cannot be empty.")
        }
        qualifiers[key, default: []].append(value)
    }
    return qualifiers
}

private func formatIntervals(_ intervals: [AnnotationInterval]) -> String {
    intervals
        .map { "\($0.start + 1)-\($0.end)" }
        .joined(separator: ",")
}

private func formatFASTA(records: [AlignedFASTARecord]) -> String {
    records.map { record in
        ">\(record.name)\n\(wrappedSequence(record.sequence))"
    }
    .joined(separator: "\n") + "\n"
}

private func wrappedSequence(_ sequence: String, lineLength: Int = 80) -> String {
    guard sequence.count > lineLength else { return sequence }
    var lines: [String] = []
    var current = ""
    current.reserveCapacity(lineLength)
    for character in sequence {
        current.append(character)
        if current.count == lineLength {
            lines.append(current)
            current = ""
        }
    }
    if current.isEmpty == false {
        lines.append(current)
    }
    return lines.joined(separator: "\n")
}

private func fileRecord(at url: URL) throws -> MSAFileExportProvenance.FileRecord {
    let data = try Data(contentsOf: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
    return MSAFileExportProvenance.FileRecord(
        path: url.path,
        checksumSHA256: MultipleSequenceAlignmentBundle.sha256Hex(for: data),
        fileSize: size
    )
}

private func bundleDigest(from manifest: MultipleSequenceAlignmentBundle.Manifest) -> String {
    let digestSource = manifest.checksums
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "\n")
    return MultipleSequenceAlignmentBundle.sha256Hex(for: Data(digestSource.utf8))
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
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
