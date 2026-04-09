// ExtractReadsCommand.swift - CLI command for universal read extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow
import LungfishIO
import LungfishCore

/// Resolves the `ExtractionResult` ambiguity between LungfishWorkflow and LungfishCore.
private typealias ReadExtractionResult = LungfishWorkflow.ExtractionResult

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

    @Option(name: .customLong("source"), help: "Source FASTQ file(s). Repeat for paired-end. (for --by-id)")
    var sourceFiles: [String] = []

    @Flag(name: .customLong("keep-read-pairs"), help: "Include both mates when either matches (for --by-id)")
    var keepReadPairs: Bool = false

    @Flag(name: .customLong("no-keep-read-pairs"), help: "Extract only exact read IDs without pairing (for --by-id)")
    var noKeepReadPairs: Bool = false

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

    // NOTE: Cannot use bare `--format` here — `GlobalOptions.outputFormat`
    // already declares `--format` for the report-output format (text/json/tsv).
    // The classifier strategy uses `--read-format` for the FASTQ vs FASTA
    // distinction on the extracted read file itself.
    @Option(name: .customLong("read-format"), help: "Output read format: fastq or fasta (for --by-classifier; default fastq)")
    var classifierFormat: String = "fastq"

    @Flag(name: .customLong("include-unmapped-mates"), help: "Include unmapped mates of mapped pairs (for --by-classifier, non-kraken2)")
    var includeUnmappedMates: Bool = false

    // MARK: - By-Region Extension

    @Flag(name: .customLong("exclude-unmapped"), help: "Exclude unmapped reads (samtools -F 0x404 instead of -F 0x400) for --by-region")
    var excludeUnmapped: Bool = false

    // MARK: - Common Options

    @Option(name: .shortAndLong, help: "Output FASTQ file path")
    var output: String

    @Flag(name: .customLong("bundle"), help: "Wrap output in a .lungfishfastq bundle")
    var createBundle: Bool = false

    @Option(name: .customLong("bundle-name"), help: "Custom bundle display name (implies --bundle)")
    var bundleName: String?

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
            throw ValidationError("Exactly one of --by-id, --by-region, --by-db, or --by-classifier must be specified")
        }

        if byId {
            guard idsFile != nil else {
                throw ValidationError("--ids is required with --by-id")
            }
            guard !sourceFiles.isEmpty else {
                throw ValidationError("At least one --source file is required with --by-id")
            }
            if keepReadPairs && noKeepReadPairs {
                throw ValidationError("--keep-read-pairs and --no-keep-read-pairs are mutually exclusive")
            }
        }

        if byRegion {
            guard bamFile != nil else {
                throw ValidationError("--bam is required with --by-region")
            }
            guard !regions.isEmpty else {
                throw ValidationError("At least one --region is required with --by-region")
            }
        }

        if byDb {
            guard databaseFile != nil else {
                throw ValidationError("--database is required with --by-db")
            }
            guard !taxIds.isEmpty || !accessions.isEmpty else {
                throw ValidationError("At least one --db-taxid or --db-accession is required with --by-db")
            }
        }

        if byClassifier {
            guard let toolRaw = classifierTool else {
                throw ValidationError("--tool is required with --by-classifier")
            }
            guard let tool = ClassifierTool(rawValue: toolRaw) else {
                throw ValidationError("Invalid --tool value '\(toolRaw)'. Must be one of: \(ClassifierTool.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard classifierResult != nil else {
                throw ValidationError("--result is required with --by-classifier")
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
                    throw ValidationError("--tool \(toolRaw) requires at least one --accession")
                }
            case .kraken2:
                guard hasTaxons else {
                    throw ValidationError("--tool kraken2 requires at least one --taxon")
                }
                if includeUnmappedMates {
                    throw ValidationError("--include-unmapped-mates is not supported with --tool kraken2")
                }
            }

            guard classifierFormat == "fastq" || classifierFormat == "fasta" else {
                throw ValidationError("--read-format must be 'fastq' or 'fasta' (got '\(classifierFormat)')")
            }
        }
    }

    // MARK: - Execution

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let fm = FileManager.default
        let service = ReadExtractionService()

        let outputURL = URL(fileURLWithPath: output)
        let outputDir = outputURL.deletingLastPathComponent()
        let outputBase = outputURL.deletingPathExtension().lastPathComponent

        // Create output directory if needed
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let result: ReadExtractionResult

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
                outputBase: outputBase
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
            result = try await runByClassifier(
                formatter: formatter,
                outputURL: outputURL
            )
        }

        // Bundle wrapping
        if createBundle || bundleName != nil {
            let metadata = ExtractionMetadata(
                sourceDescription: bundleName ?? outputBase,
                toolName: strategyLabel,
                parameters: strategyParameters
            )

            let bundleURL = try await service.createBundle(
                from: result,
                sourceName: bundleName ?? outputBase,
                selectionDescription: "extract",
                metadata: metadata,
                in: outputDir
            )

            print("")
            print(formatter.success("Created bundle: \(bundleURL.lastPathComponent)"))
        }

        // Print summary
        print("")
        print(formatter.header("Extraction Summary"))
        print(formatter.keyValueTable([
            ("Strategy", strategyLabel),
            ("Reads extracted", "\(result.readCount)"),
            ("Paired-end", result.pairedEnd ? "yes" : "no"),
            ("Output files", result.fastqURLs.map { $0.lastPathComponent }.joined(separator: ", ")),
        ]))
        for url in result.fastqURLs {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            print("  \(formatter.path(url.path)) (\(formatReadsBytes(size)))")
        }
        print("")
        print(formatter.success("Extraction complete"))
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
            print(formatter.error("Read ID file not found: \(idsFile!)"))
            throw ExitCode.failure
        }
        let idsContent = try String(contentsOf: idsURL, encoding: .utf8)
        let readIDs = Set(
            idsContent
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        guard !readIDs.isEmpty else {
            print(formatter.error("Read ID file is empty"))
            throw ExitCode.failure
        }

        // Validate source files
        let sourceURLs = sourceFiles.map { URL(fileURLWithPath: $0) }
        for url in sourceURLs {
            guard fm.fileExists(atPath: url.path) else {
                print(formatter.error("Source file not found: \(url.path)"))
                throw ExitCode.failure
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

        print(formatter.header("Read ID Extraction"))
        print("")
        print(formatter.keyValueTable([
            ("Source files", sourceURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Read IDs", "\(readIDs.count)"),
            ("Keep read pairs", shouldKeepPairs ? "yes" : "no"),
        ]))
        print("")

        return try await service.extractByReadIDs(config: config) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
    }

    private func runByBAMRegion(
        service: ReadExtractionService,
        formatter: TerminalFormatter,
        outputDir: URL,
        outputBase: String
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        let bamURL = URL(fileURLWithPath: bamFile!)
        guard fm.fileExists(atPath: bamURL.path) else {
            print(formatter.error("BAM file not found: \(bamFile!)"))
            throw ExitCode.failure
        }

        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            regions: regions,
            fallbackToAll: false,
            outputDirectory: outputDir,
            outputBaseName: outputBase
        )

        print(formatter.header("BAM Region Extraction"))
        print("")
        print(formatter.keyValueTable([
            ("BAM file", bamURL.lastPathComponent),
            ("Regions", regions.joined(separator: ", ")),
        ]))
        print("")

        return try await service.extractByBAMRegion(
            config: config,
            flagFilter: excludeUnmapped ? 0x404 : 0x400
        ) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
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
            print(formatter.error("Database file not found: \(databaseFile!)"))
            throw ExitCode.failure
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

        print(formatter.header("Database Extraction"))
        print("")
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
        print(formatter.keyValueTable(tableRows))
        print("")

        return try await service.extractFromDatabase(config: config) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }
    }

    // MARK: - Classifier strategy

    private func runByClassifier(
        formatter: TerminalFormatter,
        outputURL: URL
    ) async throws -> ReadExtractionResult {
        let fm = FileManager.default

        guard let toolRaw = classifierTool, let tool = ClassifierTool(rawValue: toolRaw) else {
            throw ExitCode.failure
        }
        guard let resultPathStr = classifierResult else {
            throw ExitCode.failure
        }
        // Pre-flight existence check, matching the pattern in runByReadID /
        // runByBAMRegion / runByDatabase. The semantics are slightly relaxed
        // vs the other strategies because `ClassifierReadResolver.resolveBAMURL`
        // interprets the path in one of three ways depending on the tool:
        //
        //   1. A file that exists (e.g. esviritu's results.sqlite next to
        //      the sorted BAM) — check `fileExists(atPath:)`.
        //   2. A directory that exists (e.g. nvd's result dir containing
        //      {sample}.bam files) — same `fileExists(atPath:)` call
        //      returns true for directories too.
        //   3. A sentinel file path whose PARENT directory contains the BAMs
        //      (e.g. a fake `fake-nvd.sqlite` path used by the nvd scan-the-
        //      parent-dir flow). In this case the sentinel file itself does
        //      not need to exist; the resolver strips it to the parent dir.
        //
        // So we accept the path if EITHER the path itself exists OR its parent
        // directory does. If neither is true, the user almost certainly typo'd
        // the --result argument and we should bail with a readable message.
        let resultPath = URL(fileURLWithPath: resultPathStr)
        let parentExists = fm.fileExists(atPath: resultPath.deletingLastPathComponent().path)
        guard fm.fileExists(atPath: resultPathStr) || parentExists else {
            print(formatter.error("Classifier result not found: \(resultPathStr)"))
            throw ExitCode.failure
        }

        // In DEBUG builds, allow tests to inject the simulated argv via the
        // testingRawArgs hook so per-sample grouping reflects the test args
        // rather than xctest's CommandLine.arguments. In RELEASE builds, the
        // helper falls back to CommandLine.arguments.
        #if DEBUG
        let effectiveArgs = testingRawArgs
        #else
        let effectiveArgs: [String]? = nil
        #endif
        let selectors = buildClassifierSelectors(rawArgs: effectiveArgs)
        let options = makeExtractionOptions()

        print(formatter.header("Classifier Extraction (\(tool.displayName))"))
        print("")
        print(formatter.keyValueTable([
            ("Tool", tool.displayName),
            ("Result path", resultPath.lastPathComponent),
            ("Samples", selectors.compactMap { $0.sampleId }.joined(separator: ", ")),
            ("Accessions", selectors.flatMap { $0.accessions }.joined(separator: ", ")),
            ("Taxons", selectors.flatMap { $0.taxIds.map(String.init) }.joined(separator: ", ")),
            ("Format", options.format.rawValue),
            ("Include unmapped mates", options.includeUnmappedMates ? "yes" : "no"),
        ]))
        print("")

        let resolver = ClassifierReadResolver()
        let quiet = globalOptions.quiet
        let outcome = try await resolver.resolveAndExtract(
            tool: tool,
            resultPath: resultPath,
            selections: selectors,
            options: options,
            destination: .file(outputURL),
            progress: { _, message in
                if !quiet {
                    print("\r\(formatter.info(message))", terminator: "")
                }
            }
        )

        // Translate the outcome back into a ReadExtractionResult so the common
        // bundle-wrapping + summary print at the bottom of `run()` works
        // unmodified.
        let fastqURL: URL
        switch outcome {
        case .file(let u, _):
            fastqURL = u
        case .bundle(let u, _):
            fastqURL = u
        case .clipboard, .share:
            // Defensive dead code: the CLI always passes `.file(outputURL)` as
            // the destination above, so the resolver never returns a
            // clipboard/share outcome here. Keep the branch rather than
            // `fatalError` so a future refactor that adds a CLI-side destination
            // doesn't silently crash end users.
            print("")
            print(formatter.error("Clipboard / share destinations are not supported from the CLI"))
            throw ExitCode.failure
        }
        return ReadExtractionResult(
            fastqURLs: [fastqURL],
            readCount: outcome.readCount,
            pairedEnd: false
        )
    }

    // MARK: - Classifier option construction

    /// Builds the `ExtractionOptions` that `runByClassifier` passes to
    /// `ClassifierReadResolver`. Exposed (non-private) so tests can assert that
    /// CLI flags like `--read-format` and `--include-unmapped-mates` flow
    /// through to the resolver-facing struct, without having to actually
    /// execute the extraction pipeline.
    func makeExtractionOptions() -> ExtractionOptions {
        let format: CopyFormat = (classifierFormat == "fasta") ? .fasta : .fastq
        return ExtractionOptions(
            format: format,
            includeUnmappedMates: includeUnmappedMates
        )
    }

    // MARK: - Classifier selection reconstruction

    /// Reconstructs per-sample `ClassifierRowSelector` groups from the parsed
    /// flags, using the raw argument order to bind `--accession` and `--taxon`
    /// flags to their preceding `--sample` scope.
    ///
    /// Handles both ArgumentParser-accepted forms for each flag:
    /// - space-separated (`--sample A`), which consumes two argv tokens
    /// - equals-joined (`--sample=A`), which is a single argv token
    ///
    /// Both forms may appear in the same argv.
    ///
    /// - Parameter rawArgs: The full argument list as it was passed to
    ///   `ExtractReadsSubcommand.parse(...)`. Defaults to `CommandLine.arguments`
    ///   minus the executable name. Tests supply the list explicitly.
    func buildClassifierSelectors(rawArgs: [String]? = nil) -> [ClassifierRowSelector] {
        // The argument list we walk. In tests this is supplied; in production
        // it is the current process's arguments.
        let argv: [String] = rawArgs ?? Array(CommandLine.arguments.dropFirst())

        var selectors: [ClassifierRowSelector] = []
        var current: ClassifierRowSelector?

        /// Splits a token like `--sample=A` into ("--sample", "A"), or
        /// `--sample` into ("--sample", nil).
        func split(_ token: String) -> (key: String, inlineValue: String?) {
            if let eq = token.firstIndex(of: "=") {
                return (String(token[..<eq]), String(token[token.index(after: eq)...]))
            }
            return (token, nil)
        }

        var i = 0
        while i < argv.count {
            let (key, inlineValue) = split(argv[i])

            // Resolve the flag's value: inline (`--sample=A`) takes precedence,
            // otherwise read the next argv token (`--sample A`). If neither is
            // present we let the outer `i += 1` skip the dangling flag —
            // ArgumentParser rejects dangling-option invocations at parse time
            // anyway, so this path is defensive.
            let value: String?
            let consumed: Int
            if let inlineValue {
                value = inlineValue
                consumed = 1
            } else if i + 1 < argv.count {
                value = argv[i + 1]
                consumed = 2
            } else {
                value = nil
                consumed = 1
            }

            switch key {
            case "--sample":
                if let value {
                    if let c = current { selectors.append(c) }
                    current = ClassifierRowSelector(sampleId: value, accessions: [], taxIds: [])
                    i += consumed
                    continue
                }
            case "--accession":
                if let value {
                    if current == nil {
                        current = ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [])
                    }
                    current?.accessions.append(value)
                    i += consumed
                    continue
                }
            case "--taxon":
                if let value {
                    if current == nil {
                        current = ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [])
                    }
                    if let n = Int(value) {
                        current?.taxIds.append(n)
                    }
                    i += consumed
                    continue
                }
            default:
                break
            }
            i += 1
        }
        if let c = current { selectors.append(c) }
        return selectors
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
            params["sources"] = sourceFiles.joined(separator: ", ")
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
}

// MARK: - Formatting Helper

/// Formats a byte count as a human-readable string.
///
/// Module-level free function to avoid `@MainActor` isolation issues in
/// `@Sendable` closures per the project convention in MEMORY.md.
private func formatReadsBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
    if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
    return "\(bytes) B"
}
