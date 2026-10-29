// ExtractReadsCommand.swift - CLI command for universal read extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Resolves the `ExtractionResult` ambiguity between LungfishWorkflow and LungfishCore.
typealias ReadExtractionResult = LungfishWorkflow.ExtractionResult

/// Extract reads from FASTQ, BAM, database, or classifier-result sources.
///
/// Supports four mutually exclusive extraction modes:
///
/// - **By read IDs** (`--by-id`): Extracts reads from FASTQ files by matching read IDs
///   listed in a text file. Supports paired-end data.
/// - **By BAM region** (`--by-region`): Extracts reads from a sorted, indexed BAM file
///   for one or more genomic regions.
/// - **By database query** (`--by-db`): Extracts reads stored in an NAO-MGS SQLite
///   database, filtered by taxonomy ID and/or accession.
/// - **By classifier selection** (`--by-classifier`): Extracts reads from a classifier
///   result (esviritu, taxtriage, kraken2, naomgs, nvd) by sample/accession/taxon
///   selection. Delegates to `ClassifierReadResolver` for unified extraction.
///
/// ## Examples
///
/// ```
/// # Extract by read IDs
/// lungfish extract reads --by-id --ids read_ids.txt --source input.fastq -o output.fastq
///
/// # Extract by BAM region
/// lungfish extract reads --by-region --bam aligned.bam --region NC_005831.2 -o output.fastq
///
/// # Extract from database
/// lungfish extract reads --by-db --database results.db --db-sample S1 --db-taxid 12345 -o output.fastq
///
/// # Extract from a classifier result
/// lungfish extract reads --by-classifier --tool esviritu --result results.sqlite \
///     --sample S1 --accession NC_001803 -o output.fastq
/// ```
struct ExtractReadsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reads",
        abstract: "Extract reads from FASTQ, BAM, database, or classifier-result sources",
        discussion: """
        Extract reads using one of four strategies. Exactly one of --by-id,
        --by-region, --by-db, or --by-classifier must be specified.

        By Read IDs (--by-id):
          Extracts reads from FASTQ files matching read IDs in a text file.
          Use --source (repeatable) for paired-end inputs and --keep-read-pairs
          to include both mates when either matches.

        By BAM Region (--by-region):
          Extracts reads from a sorted, indexed BAM file for one or more
          genomic regions. Requires samtools. Pass --exclude-unmapped to use
          the stricter samtools -F 0x404 filter (drops unmapped reads).

        By Database (--by-db):
          Queries an NAO-MGS SQLite database for reads matching taxonomy IDs
          and/or accessions. Use --db-sample, --db-taxid, --db-accession to
          filter the query. No external tools required.

        By Classifier Selection (--by-classifier):
          Routes a classifier result (esviritu/taxtriage/kraken2/naomgs/nvd)
          plus a per-sample selection through ClassifierReadResolver. The same
          resolver backs the GUI extraction dialog, so the CLI and GUI produce
          byte-identical output for the same selection.

        On Alignment Evidence (--index):
          With --index, --by-region and --by-id --bam read the alignment
          through that index and publish a .lungfishfastq bundle at --output
          with its record. A region keeps the reads that pass --min-mapq,
          --exclude-flags and --read-group. --by-id takes the names in --ids
          from the alignment, or from the --source FASTQs when given.

        With --format json the command prints CLIEvent lines on standard
        output and its text on standard error.
        """
    )

    // MARK: - Strategy Flags (mutually exclusive)

    @Flag(name: .customLong("by-id"), help: "Extract reads by read ID from FASTQ files")
    var byId: Bool = false

    @Flag(name: .customLong("by-region"), help: "Extract reads by genomic region from a BAM file")
    var byRegion: Bool = false

    @Flag(name: .customLong("by-db"), help: "Extract reads from an NAO-MGS SQLite database")
    var byDb: Bool = false

    @Flag(name: .customLong("by-classifier"), help: "Extract reads by selection from a classifier result (esviritu, taxtriage, kraken2, naomgs, nvd)")
    var byClassifier: Bool = false

    // MARK: - By-ID Options

    @Option(name: .customLong("ids"), help: "Path to read ID file (one ID per line, for --by-id)")
    var idsFile: String?

    @Option(name: .customLong("source"), help: "Source FASTQ file(s). Repeat for paired-end. Mutually exclusive with --bam. (for --by-id)")
    var sourceFiles: [String] = []

    @Flag(name: .customLong("keep-read-pairs"), help: "Include both mates when either matches (for --by-id --source; automatic in --by-id --bam mode)")
    var keepReadPairs: Bool = false

    @Flag(name: .customLong("no-keep-read-pairs"), help: "Extract only exact read IDs without pairing (for --by-id --source only; a validation error in --by-id --bam mode, where pairing by QNAME is automatic and cannot be disabled)")
    var noKeepReadPairs: Bool = false

    @Flag(name: .customLong("include-secondary"), help: "Include secondary/supplementary alignments, name-disambiguated with /sup or /sec (for --by-id --bam only)")
    var includeSecondaryFlag: Bool = false

    @Flag(name: .customLong("exclude-duplicates"), help: "Exclude PCR/optical duplicate-flagged reads -F 0x400 (for --by-id --bam only; duplicates are INCLUDED by default)")
    var excludeDuplicatesFlag: Bool = false

    // MARK: - By-Region Options

    @Option(name: .customLong("bam"), help: "BAM file path (for --by-region)")
    var bamFile: String?

    @Option(name: .customLong("region"), help: "Genomic region to extract (repeatable, for --by-region)")
    var regions: [String] = []

    // MARK: - By-DB Options

    @Option(name: .customLong("database"), help: "SQLite database path (for --by-db)")
    var databaseFile: String?

    @Option(name: .customLong("db-sample"), help: "Sample ID (for --by-db)")
    var sample: String?

    @Option(name: .customLong("db-taxid"), help: "Taxonomy ID (repeatable, for --by-db)")
    var taxIds: [String] = []

    @Option(name: .customLong("db-accession"), help: "Accession filter (repeatable, for --by-db)")
    var accessions: [String] = []

    @Option(name: .customLong("max-reads"), help: "Maximum reads to extract (for --by-db)")
    var maxReads: Int?

    // MARK: - By-Classifier Options

    @Option(name: .customLong("tool"), help: "Classifier tool: esviritu|taxtriage|kraken2|naomgs|nvd (for --by-classifier)")
    var classifierTool: String?

    @Option(name: .customLong("result"), help: "Path to the classifier result file or directory (for --by-classifier)")
    var classifierResult: String?

    // MARK: - Classifier selection flags (sample-grouped)
    //
    // These three arrays are populated in parse order. The sample/accession/taxon
    // grouping is reconstructed by `buildClassifierSelectors(rawArgs:)` walking
    // the raw argument list. This dance exists because ArgumentParser does not
    // preserve cross-option ordering for independently-declared repeated options.
    //
    // NOTE: `classifierSamples` exists purely for ArgumentParser parse-side
    // acceptance — without it, `--sample` on the CLI would raise "unknown
    // option". It is never read directly; the grouping is reconstructed by
    // `buildClassifierSelectors(rawArgs:)` from the raw argv.

    @Option(name: .customLong("sample"), help: "Sample ID (repeatable; scopes subsequent --accession/--taxon flags, for --by-classifier)")
    var classifierSamples: [String] = []

    @Option(name: .customLong("accession"), help: "Reference accession / contig name (repeatable, for --by-classifier)")
    var classifierAccessionsRaw: [String] = []

    @Option(name: .customLong("taxon"), help: "Taxonomy ID (repeatable, for --by-classifier --tool kraken2)")
    var classifierTaxonsRaw: [String] = []

    @Option(name: .customLong("taxon-scope"), help: "Which reads of each --taxon to take, children for the taxon and its descendants (the default) or exact for reads classified to the taxon itself (for --tool kraken2)")
    var classifierTaxonScope: String?

    // NOTE: Cannot use bare `--format` here — `GlobalOptions.outputFormat`
    // already declares `--format` for the report-output format (text/json/tsv).
    // The classifier strategy uses `--read-format` for the FASTQ vs FASTA
    // distinction on the extracted read file itself.
    @Option(name: .customLong("read-format"), help: "Output read format: fastq or fasta (for --by-classifier)")
    var classifierFormat: String = "fastq"

    @Flag(name: .customLong("include-unmapped-mates"), help: "Include unmapped mates of mapped pairs (for --by-classifier, non-kraken2)")
    var includeUnmappedMates: Bool = false

    // MARK: - By-Region Extension

    @Flag(name: .customLong("exclude-unmapped"), help: "Exclude unmapped reads (samtools -F 0x404 instead of -F 0x400) for --by-region")
    var excludeUnmapped: Bool = false

    // MARK: - Alignment Evidence (Phase 2.10 A51, ExtractReadsCommand+Evidence.swift)

    @Option(name: .customLong("index"), help: "The alignment's index (.bai, .csi or .crai). With it --by-region, or --by-id with --bam, publishes a .lungfishfastq bundle with its record at --output")
    var indexFile: String?

    @Option(name: .customLong("decoding-reference"), help: "FASTA that decodes a CRAM (with --index)")
    var decodingReferenceFile: String?

    @Option(name: .customLong("min-mapq"), help: "Lowest mapping quality of a read kept (--by-region with --index)")
    var minimumMapQ: Int?

    @Option(name: .customLong("exclude-flags"), help: "SAM flag bits of the records left out (--by-region with --index)")
    var excludedFlags: Int?

    @Option(name: .customLong("read-group"), help: "Read group to keep. Repeat for more. All when none is given (--by-region with --index)")
    var readGroups: [String] = []

    @Option(name: .customLong("records-without-sequence"), help: "How many of the selected alignment records held no sequence, kept in the record (--by-id with --index)")
    var recordsWithoutSequence: Int = 0

    // MARK: - Common Options

    @Option(name: .shortAndLong, help: "Output FASTQ file path")
    var output: String

    @Flag(name: .customLong("bundle"), help: "Wrap output in a .lungfishfastq bundle")
    var createBundle: Bool = false

    @Option(name: .customLong("bundle-name"), help: "Custom bundle display name (implies --bundle)")
    var bundleName: String?

    @OptionGroup var timeLimit: TimeLimitOptions
    @OptionGroup var globalOptions: GlobalOptions
    // MARK: - Test hooks

    #if DEBUG
    /// Test-only override for the raw arg list used by
    /// `buildClassifierSelectors`. Defaults to `CommandLine.arguments` in
    /// production runs.
    ///
    /// NOTE: this field is `#if DEBUG`-gated, so any test that assigns to
    /// `cmd.testingRawArgs` depends on the xctest target being built in Debug
    /// configuration (which is the SPM default). A Release build of the tests
    /// would fail to compile.
    var testingRawArgs: [String]? = nil
    #endif

    // MARK: - Validation

    func validate() throws {
        // Exactly one strategy must be selected
        let strategyCount = [byId, byRegion, byDb, byClassifier].filter { $0 }.count
        guard strategyCount == 1 else {
            throw CLIError.validationFailed(errors: [
                "Exactly one of --by-id, --by-region, --by-db, or --by-classifier must be specified"
            ])
        }
        if indexFile != nil { return try validateEvidenceRun() }
        guard !evidenceOptionGiven else {
            throw CLIError.validationFailed(errors: [
                "--decoding-reference, --min-mapq, --exclude-flags, --read-group and --records-without-sequence need --index"
            ])
        }

        if byId {
            guard idsFile != nil else {
                throw CLIError.validationFailed(errors: ["--ids is required with --by-id"])
            }

            let hasSource = !sourceFiles.isEmpty
            let hasBam = bamFile != nil
            guard hasSource || hasBam else {
                throw CLIError.validationFailed(errors: [
                    "--by-id requires either at least one --source file or --bam"
                ])
            }
            guard !(hasSource && hasBam) else {
                throw CLIError.validationFailed(errors: [
                    "--source and --bam are mutually exclusive with --by-id — choose a FASTQ source (--source) or a BAM source (--bam), not both"
                ])
            }

            if keepReadPairs && noKeepReadPairs {
                throw CLIError.validationFailed(errors: ["--keep-read-pairs and --no-keep-read-pairs are mutually exclusive"])
            }

            if hasBam {
                // Pairing by QNAME is automatic in BAM mode (samtools view -N
                // matches mates regardless); there is no way to opt out of
                // it, so --no-keep-read-pairs is a validation error here
                // rather than being silently reinterpreted/ignored.
                if noKeepReadPairs {
                    throw CLIError.validationFailed(errors: [
                        "--no-keep-read-pairs is not supported with --by-id --bam — mate pairing by QNAME is automatic and cannot be disabled in BAM mode"
                    ])
                }
            } else {
                if includeSecondaryFlag {
                    throw CLIError.validationFailed(errors: [
                        "--include-secondary requires --bam (for --by-id --source, secondary/supplementary filtering is not applicable)"
                    ])
                }
                if excludeDuplicatesFlag {
                    throw CLIError.validationFailed(errors: [
                        "--exclude-duplicates requires --bam (for --by-id --source, duplicate filtering is not applicable)"
                    ])
                }
            }

            guard classifierFormat == "fastq" || classifierFormat == "fasta" else {
                throw CLIError.validationFailed(errors: ["--read-format must be 'fastq' or 'fasta' (got '\(classifierFormat)')"])
            }
        }

        if byRegion {
            guard bamFile != nil else {
                throw CLIError.validationFailed(errors: ["--bam is required with --by-region"])
            }
            guard !regions.isEmpty else {
                throw CLIError.validationFailed(errors: ["At least one --region is required with --by-region"])
            }
        }

        if byDb {
            guard databaseFile != nil else {
                throw CLIError.validationFailed(errors: ["--database is required with --by-db"])
            }
            guard !taxIds.isEmpty || !accessions.isEmpty else {
                throw CLIError.validationFailed(errors: ["At least one --db-taxid or --db-accession is required with --by-db"])
            }
        }

        if byClassifier {
            guard let toolRaw = classifierTool else {
                throw CLIError.validationFailed(errors: ["--tool is required with --by-classifier"])
            }
            guard let tool = ClassifierTool(rawValue: toolRaw) else {
                throw CLIError.validationFailed(errors: [
                    "Invalid --tool value '\(toolRaw)'. Must be one of: \(ClassifierTool.allCases.map(\.rawValue).joined(separator: ", "))"
                ])
            }
            guard classifierResult != nil else {
                throw CLIError.validationFailed(errors: ["--result is required with --by-classifier"])
            }

            // Use the flat parsed arrays for the "at least one selection
            // exists" check. We deliberately do NOT call
            // buildClassifierSelectors here — that helper reads
            // CommandLine.arguments by default, which holds xctest's argv
            // during test runs and would produce false negatives.
            let hasAccessions = !classifierAccessionsRaw.isEmpty
            let hasTaxons = !classifierTaxonsRaw.isEmpty

            switch tool {
            case .esviritu, .taxtriage, .naomgs, .nvd:
                guard hasAccessions else {
                    throw CLIError.validationFailed(errors: ["--tool \(toolRaw) requires at least one --accession"])
                }
            case .kraken2:
                guard hasTaxons else {
                    throw CLIError.validationFailed(errors: ["--tool kraken2 requires at least one --taxon"])
                }
                if includeUnmappedMates {
                    throw CLIError.validationFailed(errors: ["--include-unmapped-mates is not supported with --tool kraken2"])
                }
            }
            if let classifierTaxonScope {
                guard tool == .kraken2 else {
                    throw CLIError.validationFailed(errors: ["--taxon-scope is only supported with --tool kraken2"])
                }
                guard TaxonScope(rawValue: classifierTaxonScope) != nil else {
                    throw CLIError.validationFailed(errors: ["--taxon-scope must be 'children' or 'exact' (got '\(classifierTaxonScope)')"])
                }
            }

            guard classifierFormat == "fastq" || classifierFormat == "fasta" else {
                throw CLIError.validationFailed(errors: ["--read-format must be 'fastq' or 'fasta' (got '\(classifierFormat)')"])
            }
        }
    }

    // MARK: - Execution

    /// The run's work, which `run()` scopes in a SIGTERM cancel (ExtractReadsCommand+Events.swift).
    func extract() async throws -> ExtractReadsOutcome {
        if indexFile != nil { return try await extractEvidence() }
        let runClock = ProvenanceRunClock()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let fm = FileManager.default
        let service = ReadExtractionService()

        let outputURL = URL(fileURLWithPath: output)
        let outputDir = outputURL.deletingLastPathComponent()
        let outputBase = outputURL.deletingPathExtension().lastPathComponent

        // Create output directory if needed
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let alignmentIndexURL = byRegion
            ? bamFile.flatMap { companionAlignmentIndex(for: URL(fileURLWithPath: $0)) }
            : nil
        let result: ReadExtractionResult
        // The read roles of a classifier extraction that mixes pairs with
        // single reads, which the wrapped bundle records as the app's does.
        var outputRoles: ReadClassification?

        if byId {
            result = try await runByReadID(
                service: service,
                formatter: formatter,
                outputDir: outputDir,
                outputBase: outputBase
            )
        } else if byRegion {
            result = try await runByBAMRegion(
                service: service,
                formatter: formatter,
                outputDir: outputDir,
                outputBase: outputBase,
                indexURL: alignmentIndexURL
            )
        } else if byDb {
            result = try await runByDatabase(
                service: service,
                formatter: formatter,
                outputDir: outputDir,
                outputBase: outputBase
            )
        } else {
            // byClassifier
            let extraction = try await runByClassifier(
                formatter: formatter,
                outputURL: outputURL
            )
            result = extraction.result
            outputRoles = extraction.roles
        }

        // Bundle wrapping
        var bundleURL: URL?
        if createBundle || bundleName != nil {
            let metadata = ExtractionMetadata(
                sourceDescription: bundleName ?? outputBase,
                toolName: strategyLabel,
                parameters: strategyParameters
            )

            let createdBundleURL = try await service.createBundle(
                from: result,
                sourceName: bundleName ?? outputBase,
                selectionDescription: "extract",
                metadata: metadata,
                in: outputDir, runClock: runClock
            )
            bundleURL = createdBundleURL
            if let outputRoles, let payload = result.fastqURLs.first {
                FASTQMixedLayoutHint.write(outputRoles, beside: createdBundleURL.appendingPathComponent(payload.lastPathComponent))
            }

            say("")
            say(formatter.success("Created bundle: \(createdBundleURL.lastPathComponent)"))
        }

        try await recordProvenance(
            result: result,
            outputURL: outputURL,
            bundleURL: bundleURL,
            runClock: runClock,
            alignmentIndexURL: alignmentIndexURL
        )

        // Print summary
        say("")
        say(formatter.header("Extraction Summary"))
        say(formatter.keyValueTable([
            ("Strategy", strategyLabel),
            ("Reads extracted", "\(result.readCount)"),
            ("Paired-end", result.pairedEnd ? "yes" : "no"),
            ("Output files", result.fastqURLs.map { $0.lastPathComponent }.joined(separator: ", ")),
        ]))
        for url in result.fastqURLs {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            say("  \(formatter.path(url.path)) (\(formatReadsBytes(size)))")
        }
        say("")
        say(formatter.success("Extraction complete"))
        return ExtractReadsOutcome(
            outputs: bundleURL.map { [$0.path] } ?? result.fastqURLs.map(\.path),
            readCount: result.readCount
        )
    }

    private func recordProvenance(
        result: ReadExtractionResult,
        outputURL: URL,
        bundleURL: URL?,
        runClock: ProvenanceRunClock,
        alignmentIndexURL: URL?
    ) async throws {
        var parameters = AnalysisTimeLimit.recording(strategyParameterValues(alignmentIndexURL: alignmentIndexURL))
        parameters["output"] = .file(outputURL)
        parameters["createBundle"] = .boolean(createBundle || bundleName != nil)
        parameters["bundleName"] = bundleName.map(ParameterValue.string) ?? .null
        parameters["readCount"] = .integer(result.readCount)
        parameters["pairedEnd"] = .boolean(result.pairedEnd)
        if let bundleURL {
            parameters["outputBundle"] = .file(bundleURL)
        }

        let outputRecords = outputFileRecords(for: result, bundleURL: bundleURL)

        var defaults: [String: ParameterValue] = [
            "createBundle": .boolean(false),
            "keepReadPairs": .boolean(true),
            "excludeUnmapped": .boolean(false),
            "readFormat": .string("fastq"),
            "includeUnmappedMates": .boolean(false)
        ]
        if byRegion {
            defaults["alignmentIndex"] = .null
        }

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish extract reads",
            parameters: parameters,
            defaults: defaults,
            resolved: parameters,
            toolName: "lungfish extract reads",
            toolVersion: WorkflowRun.currentAppVersion,
            command: provenanceCommand(outputURL: outputURL),
            inputs: provenanceInputRecords(alignmentIndexURL: alignmentIndexURL),
            outputs: outputRecords,
            exitCode: 0,
            wallTime: runClock.elapsed,
            stderr: nil,
            status: .completed,
            outputDirectory: bundleURL ?? outputURL.deletingLastPathComponent()
        )
    }

    private func outputFileRecords(
        for result: ReadExtractionResult,
        bundleURL: URL?
    ) -> [FileRecord] {
        if let bundleURL {
            return result.fastqURLs
                .map { bundleURL.appendingPathComponent($0.lastPathComponent) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { ProvenanceRecorder.fileRecord(url: $0, role: .output) }
        }

        return result.fastqURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ProvenanceRecorder.fileRecord(url: $0, role: .output) }
    }

    // MARK: - Strategy Implementations

    private func runByReadID(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        // Read the IDs file
        let idsURL = URL(fileURLWithPath: idsFile!)
        guard fm.fileExists(atPath: idsURL.path) else {
            throw ExtractReadsRefusal("Read ID file not found: \(idsFile!)")
        }
        let idsContent = try String(contentsOf: idsURL, encoding: .utf8)
        let readIDs = Set(
            idsContent
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        guard !readIDs.isEmpty else {
            throw ExtractReadsRefusal("Read ID file is empty")
        }

        if bamFile != nil {
            return try await runByReadIDFromBAM(
                service: service,
                formatter: formatter,
                outputDir: outputDir,
                outputBase: outputBase,
                readIDs: readIDs
            )
        }

        // Validate source files
        let sourceURLs = sourceFiles.map { URL(fileURLWithPath: $0) }
        for url in sourceURLs {
            guard fm.fileExists(atPath: url.path) else {
                throw ExtractReadsRefusal("Source file not found: \(url.path)")
            }
        }

        let shouldKeepPairs = keepReadPairs || (!noKeepReadPairs && sourceURLs.count > 1)

        let config = ReadIDExtractionConfig(
            sourceFASTQs: sourceURLs,
            readIDs: readIDs,
            keepReadPairs: shouldKeepPairs,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        say(formatter.header("Read ID Extraction"))
        say("")
        say(formatter.keyValueTable([
            ("Source files", sourceURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Read IDs", "\(readIDs.count)"),
            ("Keep read pairs", shouldKeepPairs ? "yes" : "no"),
        ]))
        say("")

        return try await service.extractByReadIDs(config: config) { _, message in
            if !globalOptions.quiet {
                progressLine(formatter.info(message))
            }
        }
    }

    /// BAM-source branch of `--by-id`: `samtools view -N <names.txt>` against
    /// the given BAM, per the bio gate (`-F 0x900` default, dedup off by
    /// default, singleton routing, `--include-secondary` name disambiguation).
    /// Adapts `ReadIDBAMExtractionResult` into the common `ReadExtractionResult`
    /// shape so the shared bundle-wrapping/summary-print code in `run()` works
    /// unmodified across all four strategies.
    private func runByReadIDFromBAM(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String,
        readIDs: Set<String>
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        let bamURL = URL(fileURLWithPath: bamFile!)
        guard fm.fileExists(atPath: bamURL.path) else {
            throw ExtractReadsRefusal("BAM file not found: \(bamFile!)")
        }

        let format: ReadIDBAMExtractionFormat = (classifierFormat == "fasta") ? .fasta : .fastq
        let config = ReadIDBAMExtractionConfig(
            bamURL: bamURL,
            readIDs: readIDs,
            includeSecondary: includeSecondaryFlag,
            excludeDuplicates: excludeDuplicatesFlag,
            format: format,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        say(formatter.header("Read ID Extraction (BAM source)"))
        say("")
        say(formatter.keyValueTable([
            ("BAM file", bamURL.lastPathComponent),
            ("Read IDs", "\(readIDs.count)"),
            ("Include secondary/supplementary", includeSecondaryFlag ? "yes" : "no"),
            ("Exclude duplicates", excludeDuplicatesFlag ? "yes" : "no"),
            ("Format", format.rawValue),
        ]))
        say("")

        let bamResult = try await service.extractByReadIDsFromBAM(config: config) { _, message in
            if !globalOptions.quiet {
                progressLine(formatter.info(message))
            }
        }

        // Track the singleton sidecar as an output too — both for the
        // provenance record (a run whose ENTIRE result set is singletons
        // must still record at least one output) and so it isn't silently
        // invisible to callers that only look at `fastqURLs`.
        var outputURLs = bamResult.outputURLs
        if let singletonsURL = bamResult.singletonsURL {
            say("")
            say(formatter.info("Singleton reads routed separately: \(singletonsURL.lastPathComponent)"))
            outputURLs.append(singletonsURL)
        }

        return ReadExtractionResult(
            fastqURLs: outputURLs,
            readCount: bamResult.readCount,
            pairedEnd: false
        )
    }

    private func runByBAMRegion(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String,
        indexURL: URL?
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        let bamURL = URL(fileURLWithPath: bamFile!)
        guard fm.fileExists(atPath: bamURL.path) else {
            throw ExtractReadsRefusal("BAM file not found: \(bamFile!)")
        }
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            indexURL: indexURL,
            regions: regions,
            fallbackToAll: false,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        say(formatter.header("BAM Region Extraction"))
        say("")
        say(formatter.keyValueTable([
            ("BAM file", bamURL.lastPathComponent),
            ("Regions", regions.joined(separator: ", ")),
        ]))
        say("")

        return try await service.extractByBAMRegion(
            config: config,
            flagFilter: excludeUnmapped ? 0x404 : 0x400
        ) { _, message in
            if !globalOptions.quiet {
                progressLine(formatter.info(message))
            }
        }
    }

    private func companionAlignmentIndex(for alignmentURL: URL) -> URL? {
        let candidates: [URL]
        switch alignmentURL.pathExtension.lowercased() {
        case "cram":
            candidates = [
                URL(fileURLWithPath: "\(alignmentURL.path).crai"),
                alignmentURL.deletingPathExtension().appendingPathExtension("crai")
            ]
        default:
            candidates = [
                URL(fileURLWithPath: "\(alignmentURL.path).bai"),
                alignmentURL.deletingPathExtension().appendingPathExtension("bai"),
                URL(fileURLWithPath: "\(alignmentURL.path).csi")
            ]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.standardizedFileURL
    }

    private func alignmentFileFormat(for alignmentURL: URL) -> FileFormat {
        alignmentURL.pathExtension.lowercased() == "cram" ? .cram : .bam
    }

    private func runByDatabase(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        let dbURL = URL(fileURLWithPath: databaseFile!)
        guard fm.fileExists(atPath: dbURL.path) else {
            throw ExtractReadsRefusal("Database file not found: \(databaseFile!)")
        }

        // Parse tax IDs
        let parsedTaxIds: Set<Int> = Set(taxIds.flatMap { arg in
            arg.split(separator: ",").compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
        })

        let config = DatabaseExtractionConfig(
            databaseURL: dbURL,
            sampleId: sample,
            taxIds: parsedTaxIds,
            accessions: Set(accessions),
            maxReads: maxReads,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        say(formatter.header("Database Extraction"))
        say("")
        var tableRows: [(String, String)] = [
            ("Database", dbURL.lastPathComponent),
        ]
        if let s = sample { tableRows.append(("Sample", s)) }
        if !parsedTaxIds.isEmpty {
            tableRows.append(("Tax IDs", parsedTaxIds.sorted().map(String.init).joined(separator: ", ")))
        }
        if !accessions.isEmpty {
            tableRows.append(("Accessions", accessions.joined(separator: ", ")))
        }
        if let max = maxReads {
            tableRows.append(("Max reads", "\(max)"))
        }
        say(formatter.keyValueTable(tableRows))
        say("")

        return try await service.extractFromDatabase(config: config) { _, message in
            if !globalOptions.quiet {
                progressLine(formatter.info(message))
            }
        }
    }

    // MARK: - Helpers

    private var strategyLabel: String {
        if byId { return "Read ID" }
        if byRegion { return "BAM Region" }
        if byDb { return "Database" }
        return "Classifier"
    }

    private var strategyParameters: [String: String] {
        var params: [String: String] = ["strategy": strategyLabel]
        if byId {
            params["idsFile"] = idsFile
            if bamFile != nil {
                params["bamFile"] = bamFile
                params["includeSecondary"] = includeSecondaryFlag ? "yes" : "no"
                params["excludeDuplicates"] = excludeDuplicatesFlag ? "yes" : "no"
                params["readFormat"] = classifierFormat
            } else {
                params["sources"] = sourceFiles.joined(separator: ", ")
            }
        } else if byRegion {
            params["bamFile"] = bamFile
            params["regions"] = regions.joined(separator: ", ")
            params["excludeUnmapped"] = excludeUnmapped ? "yes" : "no"
        } else if byDb {
            params["database"] = databaseFile
            if let s = sample { params["sample"] = s }
            if !taxIds.isEmpty { params["taxIds"] = taxIds.joined(separator: ", ") }
            if !accessions.isEmpty { params["accessions"] = accessions.joined(separator: ", ") }
        } else {
            params["tool"] = classifierTool
            params["result"] = classifierResult
            // Bundle-metadata key is named after the CLI flag (`--read-format`)
            // for consistency with other strategy parameters and to make the
            // key → flag mapping obvious to anyone inspecting the bundle JSON.
            params["readFormat"] = classifierFormat
            params["includeUnmappedMates"] = includeUnmappedMates ? "yes" : "no"
        }
        return params
    }

    func strategyParameterValues(alignmentIndexURL: URL?) -> [String: ParameterValue] {
        var values = strategyParameters.mapValues(ParameterValue.string)
        if byRegion, let bamFile {
            let alignmentURL = URL(fileURLWithPath: bamFile).standardizedFileURL
            values["alignmentFormat"] = .string(alignmentFileFormat(for: alignmentURL).rawValue)
            values["alignmentIndex"] = alignmentIndexURL.map(ParameterValue.file) ?? .null
        }
        if byClassifier {
            let rawArgs = effectiveClassifierRawArguments()
            values["selectionArgv"] = .array(
                classifierSelectionReplayArguments(rawArgs: rawArgs).map { .string($0) }
            )
            values["selections"] = .array(
                buildClassifierSelectors(rawArgs: rawArgs).map(parameterValue(for:))
            )
            values.merge(classifierTaxonParameters(rawArgs: rawArgs)) { _, taxa in taxa }
        }
        return values
    }

    private func parameterValue(for selector: ClassifierRowSelector) -> ParameterValue {
        .dictionary([
            "sample": selector.sampleId.map(ParameterValue.string) ?? .null,
            "accessions": .array(selector.accessions.map { .string($0) }),
            "taxIds": .array(selector.taxIds.map { .integer($0) })
        ])
    }

    private func provenanceInputRecords(alignmentIndexURL: URL?) -> [FileRecord] {
        if byId {
            let idRecords = idsFile
                .map { provenanceRecords(for: URL(fileURLWithPath: $0), format: .text, role: .input) }
                ?? []
            if let bamFile {
                let bamRecords = provenanceRecords(for: URL(fileURLWithPath: bamFile), format: .bam, role: .input)
                return bamRecords + idRecords
            }
            let sourceRecords = sourceFiles
                .map { URL(fileURLWithPath: $0) }
                .flatMap { provenanceRecords(for: $0, role: .input) }
            return sourceRecords + idRecords
        }

        if byRegion {
            guard let bamFile else { return [] }
            let alignmentURL = URL(fileURLWithPath: bamFile).standardizedFileURL
            var records = provenanceRecords(
                for: alignmentURL,
                format: alignmentFileFormat(for: alignmentURL),
                role: .input
            )
            if let indexURL = alignmentIndexURL {
                records += provenanceRecords(for: indexURL, role: .index)
            }
            return records
        }

        if byDb {
            guard let databaseFile else { return [] }
            return provenanceRecords(for: URL(fileURLWithPath: databaseFile), role: .input)
        }

        guard let classifierResult else { return [] }
        let resultURL = URL(fileURLWithPath: classifierResult)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resultURL.path, isDirectory: &isDirectory) {
            return provenanceRecords(for: resultURL, role: .input)
        }

        let parentURL = resultURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parentURL.path) {
            return provenanceRecords(for: parentURL, role: .input)
        }

        return provenanceRecords(for: resultURL, role: .input)
    }
}

// MARK: - Formatting Helper

/// Formats a byte count as a human-readable string.
///
/// Module-level free function so `@Sendable` closures can format byte counts
/// without capturing actor-isolated formatter state.
private func formatReadsBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
    return "\(bytes) B"
}
