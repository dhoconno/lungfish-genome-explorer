// FastqCommand.swift - FASTQ processing CLI commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ONTImportStorageMode: ExpressibleByArgument {}
extension QualityBinningScheme: ExpressibleByArgument {}

/// FASTQ processing operations
struct FastqCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fastq",
        abstract: "FASTQ read processing and quality control",
        discussion: """
            Process FASTQ files using bundled bioinformatics tools (seqkit, fastp,
            bbtools). All tools are embedded — no external installations required.

            Operations include subsetting, quality/adapter trimming, contaminant
            and low-complexity filtering, error correction, primer removal, and
            paired-end utilities.

            Examples:
              lungfish-cli fastq subsample --proportion 0.1 reads.fastq -o subset.fastq
              lungfish-cli fastq quality-trim --threshold 20 reads.fastq -o trimmed.fastq
              lungfish-cli fastq contaminant-filter --mode phix reads.fastq -o clean.fastq
              lungfish-cli fastq entropy-filter --entropy 0.6 reads.fastq -o complex.fastq
              lungfish-cli fastq error-correct reads.fastq -o corrected.fastq
            """,
        subcommands: [
            FastqSubsampleSubcommand.self,
            FastqLengthFilterSubcommand.self,
            FastqTrimSubcommand.self,
            FastqQualityTrimSubcommand.self,
            FastqAdapterTrimSubcommand.self,
            FastqFixedTrimSubcommand.self,
            FastqContaminantFilterSubcommand.self,
            FastqEntropyFilterSubcommand.self,
            FastqPrimerRemovalSubcommand.self,
            FastqErrorCorrectSubcommand.self,
            FastqMergeSubcommand.self,
            FastqRepairSubcommand.self,
            FastqDeinterleaveSubcommand.self,
            FastqInterleaveSubcommand.self,
            FastqDeduplicateSubcommand.self,
            FastqDemultiplexSubcommand.self,
            FastqONTFluidigmSamplesSubcommand.self,
            FastqONTPacBioBarcodeDemuxSubcommand.self,
            FastqScoutSubcommand.self,
            FastqImportONTSubcommand.self,
            FastqMaterializeSubcommand.self,
            FastqPlatformSubcommand.self,
            FastqQCSummarySubcommand.self,
            FastqPBAAClusterSubcommand.self,
            FastqSavontClusterSubcommand.self,
            FastqFullLengthONTMHCGenotypingSubcommand.self,
            FastqGenotypingSubcommand.self,
            FastqGenotypingCohortSubcommand.self,
            FastqONTGenotypingSubcommand.self,
            FastqONTBarcodeGenotypingSubcommand.self,
            FastqMHCReferenceBundleSubcommand.self,
            FastqTwelveSReferenceMetadataSubcommand.self,
            FastqTwelveSReferenceBundleSubcommand.self,
            FastqTwelveSMatchSubcommand.self,
            FastqTwelveSExportSubcommand.self,
            FastqTwelveSExportUnresolvedSubcommand.self,
            FastqSearchTextSubcommand.self,
            FastqSearchMotifSubcommand.self,
            FastqOrientSubcommand.self,
            FastqScrubHumanSubcommand.self,
            FastqSequenceFilterSubcommand.self,
            FastqRiboDetectorSubcommand.self,
            FastqDeaconRiboSubcommand.self,
            FastqReverseComplementSubcommand.self,
            FastqTranslateSubcommand.self,
        ]
    )
}

// MARK: - Helpers

/// Builds the environment variables needed for BBTools shell scripts.
func bbToolsEnvironment(runner: NativeToolRunner) async -> [String: String] {
    var env: [String: String] = [:]
    if let toolsDir = await runner.getToolsDirectory() {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let jreBinDir = toolsDir.appendingPathComponent("jre/bin")
        env["PATH"] = "\(toolsDir.path):\(jreBinDir.path):\(existingPath)"
        let javaURL = jreBinDir.appendingPathComponent("java")
        let javaHome = toolsDir.appendingPathComponent("jre")
        if FileManager.default.fileExists(atPath: javaURL.path) {
            env["JAVA_HOME"] = javaHome.path
            env["BBMAP_JAVA"] = javaURL.path
        }
    }
    return env
}

/// Parses a `--mode` token (`cut-right`, `cut-front`, `cut-tail`, `cut-both`).
func parseQualityTrimMode(_ token: String) throws -> FASTQQualityTrimMode {
    guard let mode = FASTQQualityTrimMode(cliToken: token) else {
        throw ValidationError("Invalid trim mode: \(token). Use: \(FASTQQualityTrimMode.cliTokens.joined(separator: ", "))")
    }
    return mode
}

func validateInput(_ path: String) throws -> URL {
    guard FileManager.default.fileExists(atPath: path) else {
        throw CLIError.inputFileNotFound(path: path)
    }
    return URL(fileURLWithPath: path)
}

private let barcodeKitIDsHelpText = BarcodeKitRegistry.builtinKits()
    .map(\.id)
    .joined(separator: ", ")

private let barcodeDefinitionFormatHelpText = """
Custom definitions can be CSV, TSV, or whitespace text with columns id,sequence[,secondary_sequence][,sample_name]; a header line may name the columns instead (id,sequence,sample_name). Example: FLD0001<TAB>GTATCGTCGT.
"""

private let barcodeKitHelpText = """
Barcode kit: \(barcodeKitIDsHelpText), or path to custom CSV/TSV/text barcode definition. \(barcodeDefinitionFormatHelpText)
"""

func resolveBarcodeKitArgument(_ kit: String) throws -> (definition: BarcodeKitDefinition, customURL: URL?) {
    if let builtin = BarcodeKitRegistry.kit(byID: kit) {
        return (builtin, nil)
    }
    if FileManager.default.fileExists(atPath: kit) {
        let csvURL = URL(fileURLWithPath: kit)
        let name = csvURL.deletingPathExtension().lastPathComponent
        return (try BarcodeKitRegistry.loadCustomKit(from: csvURL, name: name), csvURL)
    }
    throw ValidationError(
        "Unknown barcode kit '\(kit)'. Use one of: \(barcodeKitIDsHelpText), "
        + "or a path to a custom CSV/TSV/text barcode definition. "
        + "Expected columns: id,sequence[,secondary_sequence][,sample_name]."
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Demultiplex

struct FastqDemultiplexSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demultiplex",
        abstract: "Demultiplex reads by internal barcodes",
        discussion: """
            Splits multiplexed FASTA or FASTQ reads into per-barcode output files using
            embedded cutadapt. Supports single- and dual-indexed Illumina kits,
            Fluidigm Access Array indexes, custom barcode definition files, and
            terminally anchored barcode location (5', 3', or both ends) for
            cutadapt demultiplexing. Cutadapt runs 4 threads unless --threads sets another count.

            Useful for internal Illumina barcodes within ONT reads, re-demultiplexing,
            or demultiplexing with custom barcode sets.

            Built-in kits: \(barcodeKitIDsHelpText).

            Custom definitions can be CSV, TSV, or whitespace-delimited text:
              id,sequence[,secondary_sequence][,sample_name]
              FLD0001<TAB>GTATCGTCGT
            A header line may name the columns instead, so id,sequence,sample_name
            puts sample names in the third column.

            Long-read kits (ONT native, rapid, PCR and 16S barcoding, PacBio) are
            searched as the platform's full adapter and barcode construct at both
            read ends in both orientations; a read is assigned only when both ends
            carry the same barcode. --location and --max-distance-* do not apply
            to those kits.

            Engines:
              cutadapt    Established fuzzy adapter matcher; supports error rate and indels.
              exact-bare  Swift-native exact matching for bare A/C/G/T barcodes; scans whole reads,
                          searches reverse complements, and preserves reads.

            Examples:
              lungfish-cli fastq demultiplex reads.fastq.gz --kit truseq-single-a -o demux-out/
              lungfish-cli fastq demultiplex reads.fastq.gz --kit fluidigm-access-array -o demux-out/ --engine exact-bare
              lungfish-cli fastq demultiplex reads.fastq.gz --kit custom.csv -o demux-out/ --location bothends
            """
    )

    @Argument(help: "Input FASTA/FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("kit"),
            help: .init(barcodeKitHelpText))
    var kit: String

    @Option(name: [.customLong("output"), .customShort("o")],
            help: "Output directory for per-barcode bundles")
    var output: String

    @Option(name: .customLong("location"),
            help: "Cutadapt barcode location: 5prime, 3prime, bothends (default: bothends)")
    var location: String = "bothends"

    @Option(name: .customLong("max-distance-5prime"),
            help: "Cutadapt max bases from 5' terminus where barcodes may start (default: 0)")
    var maxDistanceFrom5Prime: Int = 0

    @Option(name: .customLong("max-distance-3prime"),
            help: "Cutadapt max bases from 3' terminus where barcodes may end (default: 0)")
    var maxDistanceFrom3Prime: Int = 0

    @Option(name: .customLong("error-rate"),
            help: "Cutadapt maximum error rate for barcode matching (default: 0.15)")
    var errorRate: Double = 0.15

    @Option(name: .customLong("overlap"),
            help: "Cutadapt minimum overlap length (default: 3)")
    var overlap: Int = 3

    @Option(name: .customLong("engine"),
            help: "Demultiplexing engine: cutadapt or exact-bare (default: cutadapt)")
    var engine: String = DemultiplexEngine.cutadapt.rawValue

    @Flag(name: .customLong("no-trim"),
          help: "Cutadapt only: keep barcode sequences in output reads (exact-bare always preserves reads)")
    var noTrim: Bool = false

    @Flag(name: .customLong("discard-unassigned"),
          help: "Discard reads that do not match any barcode")
    var discardUnassigned: Bool = false

    @OptionGroup var globalOptions: GlobalOptions
    var threads: Int { globalOptions.threads ?? 4 }

    @Flag(name: .customLong("replace"),
          help: "Delete an existing, non-empty output directory before writing. Without it the command refuses to overwrite earlier results and names the directory.")
    var replace: Bool = false

    /// Refuses to write into a directory that already holds files unless
    /// `replace` is set, in which case the directory is deleted first. A
    /// rerun used to overwrite the earlier barcode bundles in place.
    static func prepareOutputDirectory(_ outputURL: URL, replace: Bool) throws {
        if try checkOutputDirectory(outputURL, replace: replace) {
            try FileManager.default.removeItem(at: outputURL)
        }
    }

    /// The refusals of ``prepareOutputDirectory(_:replace:)`` without the
    /// delete. Returns whether the directory holds earlier results that
    /// `replace` deletes, so `run` deletes them only after the input and
    /// every argument have passed and a refused run keeps them (R3, final
    /// review B2).
    static func checkOutputDirectory(_ outputURL: URL, replace: Bool) throws -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: outputURL.path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else {
            throw ValidationError("Output path \(outputURL.path) is a file, not a directory")
        }
        let contents = (try? fm.contentsOfDirectory(atPath: outputURL.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !contents.isEmpty else { return false }
        guard replace else {
            let preview = contents.sorted().prefix(5).joined(separator: ", ")
            let more = contents.count > 5 ? ", ..." : ""
            throw ValidationError(
                "Output directory \(outputURL.path) already holds \(contents.count) item(s) (\(preview)\(more)). "
                + "Choose a new --output to keep them, or pass --replace to delete them first."
            )
        }
        return true
    }

    /// Refuses a `--replace` run that would delete a file it reads: the
    /// input, its bundle, the bundles its reads come from, or a custom kit
    /// inside the output folder. The folder used to be deleted with them.
    static func refuseReadFiles(inside outputURL: URL, _ readFiles: [URL]) throws {
        for file in readFiles where CanonicalFilePath.isPath(file, within: outputURL) {
            throw CLIError.outputWriteFailed(
                path: outputURL.path,
                reason: "--replace would delete \(file.path), which this run reads. Choose an --output folder that does not hold it."
            )
        }
    }

    func run() async throws {
        guard errorRate >= 0 && errorRate <= 1 else {
            throw ValidationError("Error rate must be between 0 and 1 (got \(errorRate))")
        }
        guard maxDistanceFrom5Prime >= 0, maxDistanceFrom3Prime >= 0 else {
            throw ValidationError("Max barcode distances must be non-negative")
        }

        let outputURL = URL(fileURLWithPath: output)
        // The output is checked before a bundle is joined for the run, and
        // earlier results are deleted only below, once the input, the kit,
        // the location and the engine have passed (R3, final review B2).
        let replacesEarlierOutput = try Self.checkOutputDirectory(outputURL, replace: replace)
        // A bundle is demultiplexed as its reads (every file of a multi-file
        // bundle, the materialized reads of a virtual one), with the bundle
        // kept as the lineage source (R3, lane 1x).
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "demultiplex", contextURL: outputURL)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL

        // Resolve barcode kit
        let resolvedKit = try resolveBarcodeKitArgument(kit)
        let barcodeKit = resolvedKit.definition
        let customKitURL = resolvedKit.customURL

        let sourceBundleURL = resolvedInput.wasMaterialized || FASTQBundle.isBundleURL(resolvedInput.originalURL)
            ? resolvedInput.bundleURL
            : nil
        let sourceManifest = sourceBundleURL.flatMap { FASTQBundle.loadDerivedManifest(in: $0) }
        // A source that holds its reads as files (a merge, repair or
        // deinterleave bundle) is the barcode bundles' root, never its own
        // raw root (D1, Phase 1.5 lane A7).
        let childRoot = sourceBundleURL.flatMap {
            FASTQDerivedPayloadRoot.childRoot(ofSource: $0, manifest: sourceManifest)
        }
        let rootBundleURL = childRoot?.bundleURL
        let rootFASTQFilename = childRoot?.rootFASTQFilename
        let inputPairingMode = sourceManifest?.pairingMode
            ?? sourceBundleURL
                .flatMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
                .flatMap { FASTQMetadataStore.load(for: $0)?.ingestion?.pairingMode }
        let inputSequenceFormat = sourceManifest?.sequenceFormat
            ?? SequenceInputResolver.inputSequenceFormat(for: inputURL)
        let fastaInput = inputSequenceFormat == .fasta

        // Parse barcode location
        let barcodeLocation: BarcodeLocation
        switch location.lowercased() {
        case "5prime", "five-prime", "fiveprime": barcodeLocation = .fivePrime
        case "3prime", "three-prime", "threeprime": barcodeLocation = .threePrime
        case "bothends", "both", "both-ends", "both_ends": barcodeLocation = .bothEnds
        default:
            throw ValidationError("Invalid barcode location '\(location)'. Use: 5prime, 3prime, bothends")
        }

        let demultiplexEngine: DemultiplexEngine
        switch engine.lowercased() {
        case "cutadapt":
            demultiplexEngine = .cutadapt
        case "exact-bare", "exact-bare-barcode", "exactbare", "bare":
            demultiplexEngine = .exactBareBarcode
        default:
            throw ValidationError("Invalid demultiplexing engine '\(engine)'. Use: cutadapt or exact-bare")
        }
        let effectiveTrimBarcodes = demultiplexEngine == .exactBareBarcode ? false : !noTrim

        if demultiplexEngine == .cutadapt, barcodeKit.searchesFullPlatformConstruct,
           barcodeLocation != .bothEnds || maxDistanceFrom5Prime != 0 || maxDistanceFrom3Prime != 0 {
            FileHandle.standardError.write(Data("""
                Note: \(barcodeKit.displayName) is searched as the platform's full adapter and barcode \
                construct at both read ends in both orientations, and a read is assigned only when both \
                ends carry the same barcode. --location and --max-distance-5prime/3prime do not apply \
                to this kit and are ignored.

                """.utf8))
        }

        func configuration(input: URL) -> DemultiplexConfig {
            DemultiplexConfig(
                inputURL: input,
                sourceBundleURL: fastaInput ? nil : sourceBundleURL,
                barcodeKit: barcodeKit,
                outputDirectory: outputURL,
                barcodeLocation: barcodeLocation,
                errorRate: errorRate,
                minimumOverlap: overlap,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                trimBarcodes: effectiveTrimBarcodes,
                unassignedDisposition: discardUnassigned ? .discard : .keep,
                threads: threads,
                engine: demultiplexEngine,
                // FASTA execution uses a synthetic FASTQ solely inside the tool boundary.
                // Publish complete FASTA bundles instead of virtual synthetic-quality previews.
                rootBundleURL: fastaInput ? nil : rootBundleURL,
                rootFASTQFilename: fastaInput ? nil : rootFASTQFilename,
                inputPairingMode: inputPairingMode,
                inputSequenceFormat: inputSequenceFormat
            )
        }

        // Every refusal comes before --replace deletes anything: a file the
        // run reads inside the output folder, then the pipeline's own (L5 item 0).
        let pipeline = DemultiplexingPipeline()
        if replacesEarlierOutput {
            let sourceParent = sourceBundleURL.flatMap { bundle in
                sourceManifest.map { FASTQBundle.resolveBundle(relativePath: $0.parentBundleRelativePath, from: bundle) }
            }
            let sourceRoot = sourceBundleURL.flatMap { bundle in
                sourceManifest.map { FASTQBundle.resolveBundle(relativePath: $0.rootBundleRelativePath, from: bundle) }
            }
            try Self.refuseReadFiles(
                inside: outputURL,
                [resolvedInput.originalURL, resolvedInput.executionURL, resolvedInput.bundleURL,
                 rootBundleURL, sourceParent, sourceRoot, customKitURL].compactMap { $0 }
            )
        }
        try await pipeline.preflight(config: configuration(input: inputURL))
        if replacesEarlierOutput {
            try FileManager.default.removeItem(at: outputURL)
        }
        let preparedFASTA = fastaInput
            ? try await FastqDemultiplexSequenceFormat.prepareFASTA(inputURL: inputURL, outputDirectory: outputURL)
            : nil

        let config = configuration(input: preparedFASTA?.url ?? inputURL)
        let startedAt = Date()
        let result = try await pipeline.run(config: config) { fraction, message in
            FileHandle.standardError.write(Data("[\(String(format: "%3.0f%%", fraction * 100))] \(message)\n".utf8))
        }
        var cliArguments = ["demultiplex", resolvedInput.originalURL.path, "--kit", kit, "--output", output]
        if demultiplexEngine == .exactBareBarcode {
            cliArguments += ["--engine", demultiplexEngine.rawValue]
            if threads != 4 {
                cliArguments += ["--threads", String(threads)]
            }
        } else {
            if location != "bothends" {
                cliArguments += ["--location", location]
            }
            if maxDistanceFrom5Prime != 0 {
                cliArguments += ["--max-distance-5prime", String(maxDistanceFrom5Prime)]
            }
            if maxDistanceFrom3Prime != 0 {
                cliArguments += ["--max-distance-3prime", String(maxDistanceFrom3Prime)]
            }
            if errorRate != 0.15 {
                cliArguments += ["--error-rate", String(errorRate)]
            }
            if overlap != 3 {
                cliArguments += ["--overlap", String(overlap)]
            }
            if noTrim {
                cliArguments.append("--no-trim")
            }
            if threads != 4 {
                cliArguments += ["--threads", String(threads)]
            }
        }
        if discardUnassigned {
            cliArguments.append("--discard-unassigned")
        }
        if replace {
            cliArguments.append("--replace")
        }
        let outputBundleURLs = result.outputBundleURLs
            + (result.unassignedBundleURL.map { [$0] } ?? [])
        let outputPayloads: [URL]
        if fastaInput {
            outputPayloads = try outputBundleURLs.map { try FastqDemultiplexSequenceFormat.retainToolPayload(in: $0) }
        } else {
            outputPayloads = outputBundleURLs.compactMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
        }
        let manifestURL = outputURL.appendingPathComponent(DemultiplexManifest.filename)
        let outputRecords = [ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output)]
            + outputPayloads.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) }
        let demultiplexToolName = result.manifest.parameters.tool
        let demultiplexToolVersion: String
        if demultiplexToolName == NativeTool.cutadapt.rawValue {
            demultiplexToolVersion = await NativeToolRunner.shared.getToolVersion(.cutadapt) ?? "unknown"
        } else {
            demultiplexToolVersion = LungfishCLI.configuration.version
        }
        let stepCommand = result.nativeCommand
            ?? result.manifest.parameters.commandLine?.split(separator: " ").map(String.init)
        let inputRecords = try resolvedInput.inputRecords()
            + (customKitURL.map { provenanceRecords(for: $0, format: .text, role: .reference) } ?? [])
        var provenanceParameters: [String: ParameterValue] = [
            "input": .file(resolvedInput.originalURL),
            "kit": .string(kit),
            "resolvedKit": .string(barcodeKit.id),
            "customBarcodeKit": customKitURL.map(ParameterValue.file) ?? .null,
            "output": .file(outputURL),
            "engine": .string(demultiplexEngine.rawValue),
            "inputFormat": .string((inputSequenceFormat ?? .fastq).rawValue),
            "outputFormat": .string((inputSequenceFormat ?? .fastq).rawValue),
            "discardUnassigned": .boolean(discardUnassigned),
        ]
        var provenanceDefaults: [String: ParameterValue] = [
            "engine": .string(DemultiplexEngine.cutadapt.rawValue),
            "discardUnassigned": .boolean(false),
            "customBarcodeKit": .null,
        ]
        if demultiplexEngine == .exactBareBarcode {
            provenanceParameters["searchMode"] = .string("whole-read")
            provenanceParameters["searchReverseComplement"] = .boolean(true)
            provenanceParameters["trimBarcodes"] = .boolean(false)
            provenanceParameters["threads"] = .integer(threads)
            provenanceDefaults["searchMode"] = .string("whole-read")
            provenanceDefaults["searchReverseComplement"] = .boolean(true)
            provenanceDefaults["trimBarcodes"] = .boolean(false)
            provenanceDefaults["threads"] = .integer(4)
        } else {
            provenanceParameters["location"] = .string(location)
            provenanceParameters["resolvedLocation"] = .string(barcodeLocation.rawValue)
            provenanceParameters["maxDistanceFrom5Prime"] = .integer(maxDistanceFrom5Prime)
            provenanceParameters["maxDistanceFrom3Prime"] = .integer(maxDistanceFrom3Prime)
            provenanceParameters["errorRate"] = .number(errorRate)
            provenanceParameters["overlap"] = .integer(overlap)
            provenanceParameters["trimBarcodes"] = .boolean(effectiveTrimBarcodes)
            provenanceParameters["threads"] = .integer(threads)
            provenanceDefaults["location"] = .string("bothends")
            provenanceDefaults["maxDistanceFrom5Prime"] = .integer(0)
            provenanceDefaults["maxDistanceFrom3Prime"] = .integer(0)
            provenanceDefaults["errorRate"] = .number(0.15)
            provenanceDefaults["overlap"] = .integer(3)
            provenanceDefaults["trimBarcodes"] = .boolean(true)
            provenanceDefaults["threads"] = .integer(4)
        }

        let demultiplexEnvelope = try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq demultiplex",
            parameters: provenanceParameters,
            defaults: provenanceDefaults,
            toolName: demultiplexToolName,
            toolVersion: demultiplexToolVersion,
            command: [CLICommandIdentity.executableName, "fastq"] + cliArguments,
            stepCommand: stepCommand,
            stepInputs: preparedFASTA.map { [ProvenanceRecorder.fileRecord(url: $0.url, format: .fastq, role: .input)] },
            extraSteps: (preparedFASTA?.steps ?? []) + (try resolvedInput.materializationSteps()),
            inputs: inputRecords,
            outputs: outputRecords,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputURL
        )

        if fastaInput {
            // Focused output sidecars omit prerequisites with different outputs.
            // Normalization needs the full bridge/materialization dependency chain.
            for payload in outputPayloads {
                try ProvenanceWriter(signingProvider: nil).write(
                    demultiplexEnvelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: payload)
                )
            }
            var normalizedBundles: [ProvenanceEnvelope] = []
            for (bundle, payload) in zip(outputBundleURLs, outputPayloads) {
                normalizedBundles.append(try await FastqDemultiplexSequenceFormat.publishFASTA(
                    bundleURL: bundle, toolPayload: payload,
                    toolName: demultiplexToolName, toolVersion: demultiplexToolVersion
                ))
            }
            try FastqDemultiplexSequenceFormat.publishDirectoryProvenance(outputURL, bundles: normalizedBundles)
        }

        // Summary output
        FileHandle.standardError.write(Data("\n--- Demultiplexing Summary ---\n".utf8))
        FileHandle.standardError.write(Data("Kit: \(barcodeKit.displayName)\n".utf8))
        FileHandle.standardError.write(Data("Input reads: \(result.manifest.inputReadCount)\n".utf8))
        FileHandle.standardError.write(Data("Assigned: \(result.manifest.assignedReadCount) (\(String(format: "%.1f%%", result.manifest.assignmentRate * 100)))\n".utf8))
        FileHandle.standardError.write(Data("Unassigned: \(result.manifest.unassigned.readCount)\n".utf8))
        FileHandle.standardError.write(Data("Barcodes with reads: \(result.manifest.barcodes.filter { $0.readCount > 0 }.count)\n".utf8))
        FileHandle.standardError.write(Data("Output: \(output)\n".utf8))
        FileHandle.standardError.write(Data("Time: \(String(format: "%.1f", result.wallClockSeconds))s\n".utf8))

        for barcode in result.manifest.barcodes where barcode.readCount > 0 {
            FileHandle.standardError.write(Data("  \(barcode.displayName): \(barcode.readCount) reads\n".utf8))
        }
    }
}

struct FastqScoutSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scout",
        abstract: "Scout barcode assignments before FASTQ demultiplexing",
        discussion: """
            Scans a subset of reads against a barcode kit and writes a
            scout-result.json file with per-barcode hit counts and suggested
            accept/reject dispositions.
            """
    )

    @Argument(help: "Input FASTQ file or .lungfishfastq bundle")
    var input: String

    @Option(name: .customLong("kit"), help: .init(barcodeKitHelpText))
    var kit: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output scout-result.json path")
    var output: String

    @Option(name: .customLong("read-limit"), help: "Maximum reads to scan (default: 10000)")
    var readLimit: Int = 10_000

    @Option(name: .customLong("accept-threshold"), help: "Minimum hits to auto-accept a barcode (default: 10)")
    var acceptThreshold: Int = 10

    @Option(name: .customLong("reject-threshold"), help: "Maximum hits to auto-reject a barcode (default: 3)")
    var rejectThreshold: Int = 3

    @Option(name: .customLong("error-rate"), help: "Override barcode matching error rate")
    var errorRate: Double?

    @Option(name: .customLong("overlap"), help: "Override minimum barcode overlap")
    var overlap: Int?

    @Option(name: .customLong("source-platform"), help: "Source platform: illumina, ont, pacbio, element, ultima, mgi")
    var sourcePlatform: String?

    @Flag(name: .customLong("no-indels"), help: "Disallow indels in barcode matching")
    var useNoIndels: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        guard readLimit > 0 else {
            throw ValidationError("--read-limit must be greater than zero")
        }
        guard acceptThreshold >= 0, rejectThreshold >= 0 else {
            throw ValidationError("Scout thresholds must be non-negative")
        }
        if let errorRate {
            guard errorRate >= 0 && errorRate <= 1 else {
                throw ValidationError("--error-rate must be between 0 and 1")
            }
        }
        if let overlap {
            guard overlap > 0 else {
                throw ValidationError("--overlap must be greater than zero")
            }
        }

        let outputURL = URL(fileURLWithPath: output)
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let resolvedInput = try await FASTQSubcommandInput.resolve(input, operationName: "scout", contextURL: outputURL)
        defer { resolvedInput.cleanup() }
        let inputURL = resolvedInput.executionURL
        let resolvedKit = try resolveBarcodeKitArgument(kit)
        let resolvedSourcePlatform: LungfishIO.SequencingPlatform?
        if let sourcePlatform {
            let parsed = LungfishIO.SequencingPlatform(vendor: sourcePlatform)
            guard parsed != .unknown else {
                throw ValidationError("Unknown source platform '\(sourcePlatform)'")
            }
            resolvedSourcePlatform = parsed
        } else {
            resolvedSourcePlatform = nil
        }

        let pipeline = DemultiplexingPipeline()
        let startedAt = Date()
        let result = try await pipeline.scout(
            inputURL: inputURL,
            kit: resolvedKit.definition,
            sourcePlatform: resolvedSourcePlatform,
            errorRate: errorRate,
            minimumOverlap: overlap,
            useNoIndels: useNoIndels,
            readLimit: readLimit,
            acceptThreshold: acceptThreshold,
            rejectThreshold: rejectThreshold
        ) { fraction, message in
            guard !globalOptions.quiet else { return }
            FileHandle.standardError.write(Data("[\(String(format: "%3.0f%%", fraction * 100))] \(message)\n".utf8))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: outputURL, options: .atomic)

        var command = [
            CLICommandIdentity.executableName, "fastq", "scout",
            resolvedInput.originalURL.path,
            "--kit", kit,
            "--output", outputURL.path,
        ]
        if readLimit != 10_000 {
            command += ["--read-limit", String(readLimit)]
        }
        if acceptThreshold != 10 {
            command += ["--accept-threshold", String(acceptThreshold)]
        }
        if rejectThreshold != 3 {
            command += ["--reject-threshold", String(rejectThreshold)]
        }
        if let errorRate {
            command += ["--error-rate", String(errorRate)]
        }
        if let overlap {
            command += ["--overlap", String(overlap)]
        }
        if let sourcePlatform {
            command += ["--source-platform", sourcePlatform]
        }
        if useNoIndels {
            command.append("--no-indels")
        }

        var inputRecords = try resolvedInput.inputRecords()
        if let customURL = resolvedKit.customURL {
            inputRecords += provenanceRecords(for: customURL, format: .text, role: .reference)
        }
        let customBarcodeKitParameter: ParameterValue = resolvedKit.customURL.map { .file($0) } ?? .null
        let errorRateParameter: ParameterValue = errorRate.map { .number($0) } ?? .null
        let overlapParameter: ParameterValue = overlap.map { .integer($0) } ?? .null
        let sourcePlatformParameter: ParameterValue = sourcePlatform.map { .string($0) } ?? .null
        let resolvedSourcePlatformParameter: ParameterValue = resolvedSourcePlatform.map { .string($0.rawValue) } ?? .null
        let parameters: [String: ParameterValue] = [
            "input": .file(resolvedInput.originalURL),
            "kit": .string(kit),
            "resolvedKit": .string(resolvedKit.definition.id),
            "customBarcodeKit": customBarcodeKitParameter,
            "output": .file(outputURL),
            "readLimit": .integer(readLimit),
            "acceptThreshold": .integer(acceptThreshold),
            "rejectThreshold": .integer(rejectThreshold),
            "errorRate": errorRateParameter,
            "overlap": overlapParameter,
            "sourcePlatform": sourcePlatformParameter,
            "resolvedSourcePlatform": resolvedSourcePlatformParameter,
            "noIndels": .boolean(useNoIndels),
        ]
        let defaults: [String: ParameterValue] = [
            "readLimit": .integer(10_000),
            "acceptThreshold": .integer(10),
            "rejectThreshold": .integer(3),
            "errorRate": .null,
            "overlap": .null,
            "sourcePlatform": .null,
            "noIndels": .boolean(false),
        ]
        let outputRecords = [
            ProvenanceRecorder.fileRecord(url: outputURL, format: .json, role: .output),
        ]
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq scout",
            parameters: parameters,
            defaults: defaults,
            toolName: "lungfish fastq scout",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            extraSteps: try resolvedInput.materializationSteps(),
            inputs: inputRecords,
            outputs: outputRecords,
            exitCode: 0,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: outputDirectory
        )

        if !globalOptions.quiet {
            FileHandle.standardError.write(Data("\n--- Barcode Scout Summary ---\n".utf8))
            FileHandle.standardError.write(Data("Kit: \(resolvedKit.definition.displayName)\n".utf8))
            FileHandle.standardError.write(Data("Reads scanned: \(result.readsScanned)\n".utf8))
            FileHandle.standardError.write(Data("Assigned: \(result.readsScanned - result.unassignedCount) (\(String(format: "%.1f%%", result.assignmentRate * 100)))\n".utf8))
            FileHandle.standardError.write(Data("Accepted barcodes: \(result.acceptedCount)\n".utf8))
            FileHandle.standardError.write(Data("Output: \(outputURL.path)\n".utf8))
        }
    }
}
