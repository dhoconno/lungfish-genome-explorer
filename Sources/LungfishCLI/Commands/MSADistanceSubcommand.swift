import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension MSACommand {
    struct DistanceSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "distance",
            abstract: "Compute identity or distance matrices from a .lungfishmsa bundle",
            discussion: """
            Gaps and ambiguous characters are missing data. A nucleotide site compares only \
            when both characters are A, C, G, T or U. A protein site skips X, B, Z, J, ? and *. \
            The alphabet comes from the bundle manifest. A cell with no comparable sites is \
            written as nan, and a saturated corrected distance is written as inf.
            """
        )

        @Argument(help: "Input .lungfishmsa bundle")
        var bundlePath: String

        @Option(
            name: .customLong("model"),
            help: "Distance model: identity, p-distance, jc69 or k2p for nucleotides, identity, p-distance or poisson for protein"
        )
        var model: String = "identity"

        @Option(
            name: .customLong("gaps"),
            help: "Gap and ambiguity deletion: pairwise (each pair skips its own missing sites) or complete (skip every column with a missing site in any selected row)"
        )
        var gaps: String = MSAGapPolicy.pairwise.rawValue

        @Option(
            name: .customLong("order"),
            help: "Row and column order: alignment or average-linkage (UPGMA leaf order on p-distance)"
        )
        var order: String = MSADistanceOrder.alignment.rawValue

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
            try execute(emit: { printEventLine($0) })
        }

        func executeForTesting(emit: @escaping (String) -> Void) throws {
            try execute(emit: emit)
        }

        private func execute(emit: @escaping (String) -> Void) throws {
            let runClock = ProvenanceRunClock()
            let actionID = "msa.phylogenetics.distance-matrix"
            let emitter = MSAActionCLIEventEmitter(enabled: globalOptions.outputFormat == .json, emit: emit)
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            emitter.emitStart(actionID: actionID, message: "Starting MSA distance matrix.")

            do {
                guard let distanceModel = MSADistanceModel(rawValue: model) else {
                    throw ValidationError("Unsupported MSA distance model '\(model)'. Supported values: \(supportedMSADistanceModels.joined(separator: ", ")).")
                }
                guard let gapPolicy = MSAGapPolicy(rawValue: gaps) else {
                    throw ValidationError("Unsupported --gaps value '\(gaps)'. Supported values: \(MSAGapPolicy.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                guard let distanceOrder = MSADistanceOrder(rawValue: order) else {
                    throw ValidationError("Unsupported --order value '\(order)'. Supported values: \(MSADistanceOrder.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                if FileManager.default.fileExists(atPath: outputURL.path), force == false {
                    throw ValidationError("Output file already exists: \(outputURL.path). Use --force to overwrite.")
                }

                emitter.emitProgress(actionID: actionID, progress: 0.15, message: "Loading MSA bundle.")
                let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
                let fastaURL = bundleURL.appendingPathComponent("alignment/primary.aligned.fasta")
                let records = try selectAlignedRecords(
                    records: parseAlignedFASTA(at: fastaURL, keepingInteriorWhitespace: false),
                    bundle: bundle,
                    rows: rows,
                    columns: columns,
                    renameColumnSubsets: false
                )
                try validateRectangular(records)

                let alphabet = MSASequenceAlphabet(manifestAlphabet: bundle.manifest.alphabet)
                guard distanceModel.isValid(for: alphabet) else {
                    throw ValidationError(
                        MSADistanceMatrixError.modelNotValidForAlphabet(distanceModel, alphabet).localizedDescription
                    )
                }
                let options = MSADistanceOptions(
                    model: distanceModel,
                    gaps: gapPolicy,
                    order: distanceOrder,
                    alphabet: alphabet
                )

                emitter.emitProgress(actionID: actionID, progress: 0.55, message: "Computing pairwise \(model) matrix.")
                let matrix = try formatDistanceMatrix(records: records, options: options)
                let output = matrix.tsv
                let warnings = distanceMatrixWarnings(for: matrix)
                for warning in warnings {
                    emitter.emitWarning(actionID: actionID, message: warning, warningCount: warnings.count)
                }
                let argv = canonicalDistanceArgv(bundleURL: bundleURL, outputURL: outputURL)
                let snapshot = try msaStandaloneFilePublicationSnapshot(
                    for: outputURL,
                    backupNamePrefix: "lungfish-msa-distance"
                )
                defer { snapshot.discard() }
                do {
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(output.utf8).write(to: outputURL, options: .atomic)

                    emitter.emitProgress(actionID: actionID, progress: 0.82, message: "Writing distance-matrix provenance.")
                    try writeJSON(
                        try MSAFileExportProvenance(
                            workflowName: "multiple-sequence-alignment-distance-matrix",
                            actionID: actionID,
                            toolName: "lungfish msa distance",
                            argv: argv,
                            reproducibleCommand: msaShellCommand(argv),
                            inputBundle: .init(
                                path: bundleURL.path,
                                checksumSHA256: msaBundleDigest(from: bundle.manifest),
                                fileSize: bundle.manifest.fileSizes.values.reduce(0, +)
                            ),
                            inputAlignmentFile: msaFileRecord(at: fastaURL),
                            outputFile: msaFileRecord(at: outputURL),
                            options: .init(
                                outputFormat: "tsv",
                                rows: rows,
                                columns: columns,
                                selectedRowCount: records.count,
                                selectedColumnCount: records.first?.sequence.count ?? 0,
                                outputKind: "distance-matrix",
                                name: nil,
                                threshold: nil,
                                gapPolicy: gapPolicy.provenanceValue,
                                distanceModel: model,
                                order: distanceOrder.rawValue,
                                alphabet: alphabet.rawValue,
                                ambiguityPolicy: "skip",
                                undefinedPairCount: matrix.undefinedPairCount,
                                saturatedPairCount: matrix.saturatedPairCount,
                                retainedColumnCount: matrix.retainedColumnCount
                            ),
                            exitStatus: 0,
                            wallTimeSeconds: runClock.elapsed,
                            warnings: warnings
                        ),
                        to: outputURL.appendingPathExtension("lungfish-provenance.json")
                    )
                } catch {
                    try snapshot.restore()
                    throw error
                }

                emitter.emitComplete(actionID: actionID, output: outputURL.path, warningCount: warnings.count)
                if globalOptions.outputFormat != .json && !globalOptions.quiet {
                    emit("Wrote \(model) matrix \(outputURL.path)")
                    for warning in warnings {
                        emit("Warning: \(warning)")
                    }
                }
            } catch {
                emitter.emitFailed(actionID: actionID, message: error.localizedDescription)
                throw error
            }
        }

        private func canonicalDistanceArgv(bundleURL: URL, outputURL: URL) -> [String] {
            var argv = [
                CLICommandIdentity.executableName,
                "msa",
                "distance",
                bundleURL.path,
                "--model",
                model,
            ]
            if gaps != MSAGapPolicy.pairwise.rawValue {
                argv += ["--gaps", gaps]
            }
            if order != MSADistanceOrder.alignment.rawValue {
                argv += ["--order", order]
            }
            argv += ["--output", outputURL.path]
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
}

/// The `--model` spellings accepted by `msa distance`, in declaration order. The computation
/// itself lives in `MSADistanceMatrix` (LungfishIO) so the GUI shows the same numbers.
private let supportedMSADistanceModels: [String] = MSADistanceModel.allCases.map(\.rawValue)

/// Delegates to the shared `MSADistanceMatrix` so the CLI TSV and the GUI matrix are computed
/// by one implementation. Matrix errors surface as validation errors with their own wording.
private func formatDistanceMatrix(records: [AlignedFASTARecord], options: MSADistanceOptions) throws -> MSADistanceMatrix {
    try validateRectangular(records)
    let alignedRecords = records.map { MSAAlignedRecord(name: $0.name, sequence: $0.sequence) }
    do {
        return try MSADistanceMatrix(records: alignedRecords, options: options)
    } catch let error as MSADistanceMatrixError {
        throw ValidationError(error.localizedDescription)
    }
}

/// One warning per kind of non-value in the matrix, so a reader of the TSV knows why a cell
/// reads nan or inf.
private func distanceMatrixWarnings(for matrix: MSADistanceMatrix) -> [String] {
    var warnings: [String] = []
    if matrix.undefinedPairCount > 0 {
        let pairs = matrix.undefinedPairCount == 1 ? "1 pair has" : "\(matrix.undefinedPairCount) pairs have"
        warnings.append("\(pairs) no comparable sites and \(matrix.undefinedPairCount == 1 ? "is" : "are") written as nan.")
    }
    if matrix.saturatedPairCount > 0 {
        let pairs = matrix.saturatedPairCount == 1 ? "1 pair is" : "\(matrix.saturatedPairCount) pairs are"
        warnings.append("\(pairs) saturated under \(matrix.model.rawValue), so the distance is not estimable and is written as inf.")
    }
    return warnings
}
