// MapCommand.swift - CLI command for shared read mapping
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum MapInputResolutionError: LocalizedError {
    case unreadableSequenceInput(String)
    case derivedBundleRequiresMaterialization(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSequenceInput(let path):
            return "Sequence input does not contain a readable FASTQ or FASTA payload: \(path)"
        case .derivedBundleRequiresMaterialization(let path):
            return "Sequence input stores its reads as a recipe over another dataset and must be materialized first: \(path)"
        }
    }
}

/// Map sequence inputs to a reference genome with a managed mapper.
struct MapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "map",
        abstract: "Map sequence inputs to a reference genome with minimap2, BWA-MEM2, Bowtie2, or BBMap",
        discussion: """
        Map sequencing reads or sequences to a reference genome using one of the managed read mappers.
        Produces a coordinate-sorted, indexed BAM file. Install the tools through the
        read-mapping plugin pack (`lungfish-cli conda install read-mapping`). BBMap is exposed
        from the required BBTools environment and is available once the managed toolchain
        is provisioned.

        Multiple inputs are treated as one sample's reads (--paired binds exactly two
        files as R1/R2 of that sample); invoke once per sample for per-sample results.
        """
    )

    @Argument(help: "Input sequence file(s). Provide two files for paired-end mapping.")
    var fastqFiles: [String]

    @Option(name: .customLong("reference"), help: "Reference FASTA file to align against")
    var reference: String

    @Option(name: .customLong("mapper"), help: "Mapper: minimap2, bwa-mem2, bowtie2, bbmap")
    var mapper: String = MappingTool.minimap2.rawValue

    @Option(
        name: .customLong("preset"),
        help: "Mode/preset. minimap2: sr, asm5, splice, map-ont, map-hifi, map-pb. bbmap: bbmap-standard, bbmap-pacbio. (default: follows the input read class)"
    )
    var preset: String?

    @Option(
        name: [.customLong("output-dir"), .customShort("o")],
        help: "Output directory (default: Analyses/<mapper>-<timestamp>/ inside --project, else mapping-<id> next to input)"
    )
    var outputDir: String?

    @Option(
        name: .customLong("project"),
        help: ArgumentHelp(
            "The .lungfish project the run belongs to: without --output-dir the result lands in its Analyses/<mapper>-<timestamp>/ folder, exactly where the Map Reads window puts it",
            discussion: "The run's scratch space and the project-relative paths in the result sidecars are bound to this project."
        )
    )
    var project: String?

    @Option(
        name: .customLong("sample-name"),
        help: "Sample name for BAM read groups and output naming"
    )
    var sampleName: String?

    @Option(
        name: .customLong("track-name"),
        help: "Name of the alignment track the BAM is attached as in the result's reference bundle copy (default: \"<Mapper> Mapping\")"
    )
    var trackName: String?

    @Flag(
        name: .customLong("no-viewer-bundle"),
        help: "Leave only the BAM and sidecars: skip the reference bundle copy with the BAM attached that the Map Reads window produces"
    )
    var noViewerBundle: Bool = false

    @Option(name: .customLong("rg-id"), help: "BAM read-group ID (default: sample name)")
    var readGroupID: String?

    @Option(name: .customLong("rg-sm"), help: "BAM read-group sample/SM (default: sample name)")
    var readGroupSampleName: String?

    @Option(name: .customLong("rg-lb"), help: "BAM read-group library/LB (default: sample name)")
    var readGroupLibrary: String?

    @Option(name: .customLong("rg-pl"), help: "BAM read-group platform/PL (default: mapper preset platform)")
    var readGroupPlatform: String?

    @Option(name: .customLong("rg-pu"), help: "BAM read-group platform unit/PU (default: sample name)")
    var readGroupPlatformUnit: String?

    @Flag(name: .customLong("paired"), help: "Input files are paired-end reads")
    var pairedEnd: Bool = false

    @Option(
        name: .customLong("read-layout"),
        help: ArgumentHelp(
            "How the records of a single input file relate: auto, single-end, interleaved (every record is followed by its mate), or mixed (merged reads and interleaved pairs in one file) (default: auto)",
            discussion: "auto reads the enclosing .lungfishfastq bundle's metadata, then scans read names (identical names, /1 /2, and Casava descriptions all count as mates). Each mapper then applies its declared handling: bwa-mem2 and minimap2 pair mates in interleaved and mixed files; bowtie2 and BBMap pair mates only in a strictly interleaved file and map a mixed file as single reads."
        )
    )
    var readLayout: MapReadLayoutArgument = .auto

    @Flag(name: .customLong("secondary"), help: "Keep secondary alignments in the normalized BAM")
    var secondary: Bool = false

    @Flag(name: .customLong("no-supplementary"), help: "Exclude supplementary alignments from the normalized BAM")
    var noSupplementary: Bool = false

    @Option(name: .customLong("min-mapq"), help: "Minimum mapping quality to retain in the normalized BAM")
    var minMapQ: Int = 0

    @Option(
        name: .customLong("extra-args"),
        parsing: .unconditional,
        help: "Additional mapper options, written exactly as they should be passed to the underlying tool"
    )
    var extraArgs: String = ""

    @Option(
        name: .customLong("advanced-options"),
        parsing: .unconditional,
        help: .hidden
    )
    var advancedOptions: String = ""

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let threadCount = globalOptions.effectiveThreads
        warnIfDeprecatedAdvancedOptionsUsed()

        let inputURLs = fastqFiles.map { URL(fileURLWithPath: $0) }
        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError.inputFileNotFound(path: url.path)
            }
        }

        if pairedEnd && inputURLs.count != 2 {
            print(formatter.error("Paired-end mode requires exactly 2 input files, got \(inputURLs.count)."))
            throw CLIExitCode.inputError.exitCode
        }
        if readLayout != .auto, pairedEnd || inputURLs.count != 1 {
            print(formatter.error("--read-layout describes one input file; use --paired for two R1/R2 files."))
            throw CLIExitCode.inputError.exitCode
        }
        if minMapQ < 0 {
            print(formatter.error("--min-mapq must be greater than or equal to 0."))
            throw CLIExitCode.inputError.exitCode
        }

        let referenceInputURL = URL(fileURLWithPath: reference)
        guard FileManager.default.fileExists(atPath: referenceInputURL.path) else {
            throw CLIError.inputFileNotFound(path: referenceInputURL.path)
        }
        guard let referenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: referenceInputURL),
              SequenceInputResolver.inputSequenceFormat(for: referenceInputURL) == .fasta else {
            throw CLIError.formatDetectionFailed(path: referenceInputURL.path)
        }

        guard let selectedTool = MappingTool(rawValue: mapper) else {
            let valid = MappingTool.allCases.map(\.rawValue).joined(separator: ", ")
            print(formatter.error("Invalid mapper '\(mapper)'. Valid mappers: \(valid)"))
            throw CLIExitCode.inputError.exitCode
        }

        let projectURL: URL?
        if let project {
            let url = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError.inputFileNotFound(path: url.path)
            }
            projectURL = url
        } else {
            projectURL = nil
        }

        let outputDirectory: URL
        // The Analyses/ folder this command created. A run that throws
        // removes it again, so a failed mapping never leaves a folder that
        // holds only analysis-metadata.json and looks like a result.
        var createdAnalysisDirectory: URL?
        defer {
            if let createdAnalysisDirectory {
                AnalysesFolder.discardFailedAnalysisDirectory(createdAnalysisDirectory)
            }
        }
        // A chosen --output-dir inside a project is claimed with a run
        // record, so the result stays out of the sidebar until this run
        // completes. A failed run keeps the record (hidden, listed for
        // review as Interrupted) and is never deleted, since the folder was
        // the user's choice.
        var outputDirectoryClaim: AnalysisRunRecord.RunClaim?
        var outputDirectoryCompleted = false
        defer {
            if !outputDirectoryCompleted, outputDirectoryClaim == .owned, let outputDir {
                AnalysisRunRecord.recordOutcome(
                    Task.isCancelled ? .cancelled : .failed,
                    in: URL(fileURLWithPath: outputDir)
                )
            }
        }
        if let outputDir {
            outputDirectory = URL(fileURLWithPath: outputDir)
            do {
                outputDirectoryClaim = try AnalysesFolder.beginRunInOutputDirectory(
                    outputDirectory,
                    projectURL: projectURL,
                    record: AnalysisRunRecord(
                        analysisName: "\(selectedTool.displayName) mapping",
                        command: CommandLine.arguments.map(shellEscape).joined(separator: " ")
                    )
                )
            } catch {
                throw CLIError.outputWriteFailed(path: outputDirectory.path, reason: error.localizedDescription)
            }
        } else if let projectURL {
            // The same Analyses/<mapper>-<timestamp>/ folder the window creates.
            do {
                outputDirectory = try MappingResultLayoutService.createAnalysisDirectory(
                    tool: selectedTool,
                    in: projectURL
                )
                createdAnalysisDirectory = outputDirectory
            } catch {
                throw CLIError.outputWriteFailed(
                    path: projectURL.appendingPathComponent("Analyses").path,
                    reason: error.localizedDescription
                )
            }
        } else {
            let runToken = String(UUID().uuidString.prefix(8))
            outputDirectory = inputURLs.first!.deletingLastPathComponent()
                .appendingPathComponent("mapping-\(runToken)")
        }

        let selectedMode: MappingMode
        do {
            let presetDefault = preset == nil ? Self.defaultPreset(tool: selectedTool, inputURLs: inputURLs) : nil
            selectedMode = try presetDefault?.mode ?? resolveMode(tool: selectedTool, preset: preset)
            if let note = presetDefault?.note, !globalOptions.quiet {
                FileHandle.standardError.write(Data("note: \(note)\n".utf8))
            }
        } catch {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }

        let effectiveSampleName = sampleName ?? deriveSampleName(from: inputURLs.first!, pairedEnd: pairedEnd)
        let resolvedReadGroup = MappingReadGroup.resolved(
            sampleName: effectiveSampleName,
            id: readGroupID,
            readGroupSampleName: readGroupSampleName,
            library: readGroupLibrary,
            platform: readGroupPlatform,
            platformUnit: readGroupPlatformUnit,
            defaultPlatform: MappingReadGroup.defaultPlatform(forModeID: selectedMode.id)
        )
        let advancedArguments: [String]
        do {
            advancedArguments = try Self.parseExtraArgs(extraArgs, deprecatedAdvancedOptions: advancedOptions)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        }

        // The window and this command resolve the inputs through one call,
        // so a recorded command pairs, splits and interleaves a sample
        // exactly as the window did (READ-PAIRING.md).
        let resolution: MappingResolvedInputs
        do {
            resolution = try await MappingInputResolver.resolve(
                request: MappingRunRequest(
                    tool: selectedTool,
                    modeID: selectedMode.id,
                    inputFASTQURLs: inputURLs,
                    referenceFASTAURL: referenceURL,
                    projectURL: projectURL,
                    outputDirectory: outputDirectory,
                    sampleName: effectiveSampleName,
                    readGroup: resolvedReadGroup,
                    pairedEnd: pairedEnd,
                    threads: threadCount,
                    includeSecondary: secondary,
                    includeSupplementary: !noSupplementary,
                    minimumMappingQuality: minMapQ,
                    advancedArguments: advancedArguments,
                    outputTrackName: trackName
                ),
                explicitLayout: readLayout.explicitLayout,
                materializer: FASTQCLIMaterializer(runner: NativeToolRunner.shared),
                progress: { message in
                    if !globalOptions.quiet {
                        print(formatter.info(message))
                    }
                }
            )
        } catch let error as CLISequenceInputMaterializationError {
            switch error {
            case .unreadableSequenceInput(let path):
                throw CLIError.formatDetectionFailed(path: path)
            case .unsupportedSequenceInput(let message):
                throw CLIError.workflowFailed(reason: message)
            }
        } catch let error as MappingInputResolverError {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.inputError.exitCode
        } catch {
            throw CLIError.wrapping(error)
        }
        let resolvedInputs = resolution.sequenceInputs
        let executionInputURLs = resolvedInputs.executionInputURLs
        let originalInputURLs = resolvedInputs.originalInputURLs
        // One raw argument per execution file, so the replay command can
        // swap each bundle argument for the file that was made from it.
        let originalInputArguments = resolvedInputs.inputs.enumerated().flatMap { index, input in
            input.executionURLs.map { _ in fastqFiles[index] }
        }
        if resolvedInputs.didMaterialize {
            let materializationStartedAt = resolvedInputs.materializationStartedAt ?? Date()
            let materializationEndedAt = resolvedInputs.materializationEndedAt ?? materializationStartedAt
            do {
                _ = try CLISequenceInputMaterialization.writeMaterializationProvenanceOrCleanup(
                    workflowName: "lungfish.map.input-materialization",
                    workflowVersion: LungfishCLI.configuration.version,
                    parentArgv: CommandLine.arguments,
                    parentDurableReplayArgv: CLISequenceInputMaterialization.durableReplayArgv(
                        argv: CommandLine.arguments,
                        originalInputArguments: originalInputArguments,
                        originalInputURLs: originalInputURLs,
                        executionInputURLs: executionInputURLs
                    ),
                    originalInputURLs: originalInputURLs,
                    executionInputURLs: executionInputURLs,
                    outputDirectory: outputDirectory,
                    operationName: "mapping",
                    startedAt: materializationStartedAt,
                    endedAt: materializationEndedAt
                )
            } catch {
                throw CLIError.outputWriteFailed(
                    path: outputDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename).path,
                    reason: error.localizedDescription
                )
            }
        }

        let request = resolution.request
        let layoutResolution = resolution.layoutResolution
        let effectivePairedEnd = request.pairedEnd
        let readLayoutPlan = request.readLayoutPlan
        Self.printCompatibilityWarnings(for: request)
        // `--format json` prints one JSON document at the end; the text
        // header, tables and carriage-return progress lines would corrupt it.
        let printsText = globalOptions.outputFormat != .json
        let showsProgress = !globalOptions.quiet && printsText

        if printsText {
        print(formatter.header("Read Mapping"))
        print("")
        print(formatter.keyValueTable([
            ("Mapper", selectedTool.displayName),
            ("Mode", selectedMode.displayName),
            ("Input files", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Paired-end", effectivePairedEnd ? "yes" : "no"),
            ("Read layout", "\(readLayoutPlan.layout.displayName) (\(layoutResolution.source.rawValue))"),
            ("Layout handling", readLayoutPlan.handling.displayName),
            ("Reference", referenceURL.lastPathComponent),
            ("Threads", String(threadCount)),
            ("Secondary", secondary ? "yes" : "no"),
            ("Supplementary", noSupplementary ? "no" : "yes"),
            ("Min MAPQ", String(minMapQ)),
            ("Sample name", effectiveSampleName),
            ("Read group ID", resolvedReadGroup.id),
            ("Read group SM", resolvedReadGroup.sampleName),
            ("Read group LB", resolvedReadGroup.library),
            ("Read group PL", resolvedReadGroup.platform),
            ("Read group PU", resolvedReadGroup.platformUnit),
            ("Extra arguments", advancedArguments.isEmpty ? "none" : AdvancedCommandLineOptions.join(advancedArguments)),
            ("Project", projectURL?.path ?? "none"),
            ("Output", outputDirectory.path),
            ("Track name", noViewerBundle ? "none (no viewer bundle)" : MappingResultLayoutService.trackName(for: request)),
        ]))
        print("")
        }

        let pipeline = ManagedMappingPipeline()
        let pipelineResult: MappingResult
        do {
            pipelineResult = try await pipeline.run(
                request: request,
                inputLayoutReason: layoutResolution.reason,
                readSetPlan: resolution.readSetPlan
            ) { _, message in
                if showsProgress {
                    print(MapProgressLine.render(formatter.info(message), isTerminal: isatty(STDOUT_FILENO) == 1), terminator: "")
                    fflush(stdout)
                }
            }
        } catch {
            throw CLIError.wrapping(error)
        }

        // The same layout the Map Reads window leaves behind: a copy of the
        // reference bundle in the result directory with the BAM attached as
        // a track, the sidecars rewritten to point at it, and the run
        // recorded in the source bundle's analysis history.
        let published = try await Self.publishLayout(
            result: pipelineResult,
            request: request,
            originalInputURLs: inputURLs,
            skipViewerBundle: noViewerBundle,
            progress: { _, message in
                if showsProgress {
                    print(MapProgressLine.render(formatter.info(message), isTerminal: isatty(STDOUT_FILENO) == 1), terminator: "")
                    fflush(stdout)
                }
            }
        )
        // Published: the folder now holds the result and stays. Marking it
        // complete is the last step, which makes it appear in the sidebar.
        if let createdAnalysisDirectory {
            AnalysesFolder.markAnalysisComplete(createdAnalysisDirectory)
        }
        createdAnalysisDirectory = nil
        if let outputDirectoryClaim {
            AnalysisRunRecord.completeRun(outputDirectoryClaim, in: outputDirectory)
        }
        outputDirectoryCompleted = true
        let report = Report(published: published, request: request)

        guard printsText else {
            JSONOutputHandler().writeData(report, label: nil)
            return
        }

        print("")
        print("")
        print(formatter.header("Results"))
        print("")
        print(formatter.keyValueTable(report.textRows))
        print("")
    }

    /// What ``publishLayout(result:request:originalInputURLs:skipViewerBundle:progress:)``
    /// left behind: the result the sidecars describe and, when a viewer
    /// bundle was published, the alignment track the BAM was attached as.
    struct PublishedLayout: Sendable, Equatable {
        let result: MappingResult
        let trackInfo: AlignmentTrackInfo?
    }

    /// The `map` command's report, printed as a table or, with
    /// `--format json`, as one JSON document. `alignmentTrack` is the
    /// track id and name a follow-up command (`variants call
    /// --alignment-track`) takes; it is `nil` when no viewer bundle was
    /// published.
    struct Report: Codable, Equatable {
        struct AlignmentTrack: Codable, Equatable {
            let id: String
            let name: String
            /// Bundle-relative path of the attached BAM.
            let sourcePath: String
        }

        let mapper: String
        let mode: String
        let sampleName: String
        let inputFiles: [String]
        let reference: String
        let project: String?
        /// The `Analyses/<mapper>-<timestamp>/` folder (or `--output-dir`).
        let outputDirectory: String
        let sortedBAM: String
        let bamIndex: String
        let totalReads: Int
        let mappedReads: Int
        let unmappedReads: Int
        /// Mapped reads over total reads, or `nil` for an empty input.
        let mappingRate: Double?
        let runtimeSeconds: Double
        let viewerBundle: String?
        let sourceReferenceBundle: String?
        let alignmentTrack: AlignmentTrack?

        init(published: PublishedLayout, request: MappingRunRequest) {
            let result = published.result
            mapper = result.mapper.rawValue
            mode = result.modeID
            sampleName = request.sampleName
            // The inputs as given, once each: a bundle that resolved to
            // several files is listed once.
            var seen = Set<String>()
            inputFiles = (request.originalInputFASTQURLs ?? request.inputFASTQURLs).map(\.path).filter { seen.insert($0).inserted }
            reference = request.referenceFASTAURL.path
            project = request.projectURL?.path
            outputDirectory = request.outputDirectory.path
            sortedBAM = result.bamURL.path
            bamIndex = result.baiURL.path
            totalReads = result.totalReads
            mappedReads = result.mappedReads
            unmappedReads = result.unmappedReads
            mappingRate = result.totalReads > 0 ? Double(result.mappedReads) / Double(result.totalReads) : nil
            runtimeSeconds = result.wallClockSeconds
            viewerBundle = result.viewerBundleURL?.path
            sourceReferenceBundle = result.sourceReferenceBundleURL?.path
            alignmentTrack = published.trackInfo.map {
                AlignmentTrack(id: $0.id, name: $0.name, sourcePath: $0.sourcePath)
            }
        }

        /// The rows of the text report's Results table.
        var textRows: [(String, String)] {
            let mappingPct = mappingRate.map { String(format: "%.2f%%", $0 * 100) } ?? "N/A"
            var rows: [(String, String)] = [
                ("Total reads", String(totalReads)),
                ("Mapped reads", "\(mappedReads) (\(mappingPct))"),
                ("Unmapped reads", String(unmappedReads)),
                ("Runtime", String(format: "%.1fs", runtimeSeconds)),
                ("Analysis folder", outputDirectory),
                ("Sorted BAM", sortedBAM),
                ("BAI", bamIndex),
            ]
            if let viewerBundle {
                rows.append(("Viewer bundle", viewerBundle))
            }
            if let alignmentTrack {
                rows.append(("Track name", alignmentTrack.name))
                rows.append(("Track ID", alignmentTrack.id))
            }
            return rows
        }
    }

    /// Runs the shared post-mapping layout: viewer bundle publication (unless
    /// skipped or the reference is not inside a `.lungfishref` bundle) and
    /// the analysis-history record. Returns the result the sidecars now
    /// describe and the alignment track that was attached.
    static func publishLayout(
        result: MappingResult,
        request: MappingRunRequest,
        originalInputURLs: [URL],
        skipViewerBundle: Bool,
        progress: MappingResultLayoutService.ProgressHandler? = nil
    ) async throws -> PublishedLayout {
        var finalResult = result
        var trackInfo: AlignmentTrackInfo?
        if !skipViewerBundle {
            do {
                if let publication = try await MappingResultLayoutService.publishViewerBundle(
                    result: result,
                    request: request,
                    progress: progress
                ) {
                    finalResult = publication.result
                    trackInfo = publication.trackInfo
                }
            } catch {
                throw CLIError.workflowFailed(
                    reason: "Mapping finished, but the reference viewer bundle could not be published: \(error.localizedDescription)"
                )
            }
        }
        do {
            try MappingResultLayoutService.recordAnalysisManifest(
                originalInputURLs: originalInputURLs,
                resolvedRequest: request,
                result: finalResult,
                projectURL: request.projectURL
            )
        } catch {
            FileHandle.standardError.write(
                Data("warning: could not record the run in the source bundle's analysis history: \(error.localizedDescription)\n".utf8)
            )
        }
        return PublishedLayout(result: finalResult, trackInfo: trackInfo)
    }

    /// The `--read-layout` values, mirroring `FASTQInputLayout` for one file.
    enum MapReadLayoutArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
        case auto
        case singleEnd = "single-end"
        case interleaved
        case mixed

        /// The layout the caller stated, or `nil` for auto detection.
        var explicitLayout: FASTQInputLayout? {
            switch self {
            case .auto: return nil
            case .singleEnd: return .singleEnd
            case .interleaved: return .strictlyInterleaved
            case .mixed: return .mixedMergedAndPairs
            }
        }
    }

    static func parseExtraArgs(_ extraArgs: String, deprecatedAdvancedOptions: String) throws -> [String] {
        try AdvancedCommandLineOptions.parse(extraArgs) + AdvancedCommandLineOptions.parse(deprecatedAdvancedOptions)
    }

    private func warnIfDeprecatedAdvancedOptionsUsed() {
        guard !advancedOptions.isEmpty else { return }
        FileHandle.standardError.write(Data("warning: --advanced-options is deprecated, use --extra-args\n".utf8))
    }

    /// Synchronous resolution for inputs that need no materialization. A
    /// virtual derived bundle is refused: its resolver file is the root's
    /// original reads. `resolveExecutionInputs` materializes such bundles.
    static func resolveExecutionInputURLs(for inputURLs: [URL]) throws -> [URL] {
        try inputURLs.map { inputURL in
            if SequenceInputResolver.unmaterializedDerivedBundleURL(for: inputURL) != nil {
                throw MapInputResolutionError.derivedBundleRequiresMaterialization(inputURL.standardizedFileURL.path)
            }
            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
                throw MapInputResolutionError.unreadableSequenceInput(inputURL.standardizedFileURL.path)
            }
            return resolvedURL.standardizedFileURL
        }
    }

    /// The file resolution ``MappingInputResolver`` runs for any input that
    /// is not one bundle of pairs and single reads (``ResolvedSequenceInputs``):
    /// every file of a bundle, a virtual bundle materialized and the unpaired
    /// files of one bundle concatenated into `tempDirectory`. It decides no
    /// pairing. `run()` resolves through ``MappingInputResolver``, the call
    /// the Map Reads window makes. A loose file that is not a readable
    /// sequence file and a container-only demux group are refused before
    /// anything is written.
    static func resolveExecutionInputs(
        for inputURLs: [URL],
        tempDirectory: URL,
        materializer: any CLISequenceInputMaterializing & Sendable,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ResolvedSequenceInputs {
        for inputURL in inputURLs {
            if let message = CLISequenceInputMaterialization.unsupportedSequenceInputMessage(for: inputURL, operationName: "mapping") {
                throw CLISequenceInputMaterializationError.unsupportedSequenceInput(message)
            }
            if SequenceInputResolver.enclosingFASTQBundleURL(for: inputURL) == nil,
               SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) == nil {
                throw CLISequenceInputMaterializationError.unreadableSequenceInput(inputURL.standardizedFileURL.path)
            }
        }
        return try await ResolvedSequenceInputs.resolve(
            inputURLs: inputURLs,
            materializationDirectory: tempDirectory,
            materializer: materializer,
            concatenateUnpairedFiles: true,
            progress: progress
        )
    }

    private func resolveMode(tool: MappingTool, preset: String?) throws -> MappingMode {
        switch tool {
        case .minimap2:
            let rawValue = normalizedMinimap2Preset(preset)
            guard let mode = MappingMode(rawValue: rawValue), mode.isValid(for: tool) else {
                throw ValidationError("Invalid minimap2 preset '\(rawValue)'. Use sr, asm5, splice, map-ont, map-hifi, or map-pb.")
            }
            return mode
        case .bwaMem2, .bowtie2:
            guard preset == nil || preset == "sr" || preset == MappingMode.defaultShortRead.rawValue else {
                throw ValidationError("\(tool.displayName) only supports short-read mode in v1.")
            }
            return .defaultShortRead
        case .bbmap:
            let normalized = (preset ?? MappingMode.bbmapStandard.rawValue).lowercased()
            switch normalized {
            case "standard", MappingMode.bbmapStandard.rawValue:
                return .bbmapStandard
            case "pacbio", MappingMode.bbmapPacBio.rawValue:
                return .bbmapPacBio
            default:
                throw ValidationError("Invalid BBMap preset '\(normalized)'. Use bbmap-standard or bbmap-pacbio.")
            }
        }
    }

    private func normalizedMinimap2Preset(_ preset: String?) -> String {
        switch preset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case nil, "", "sr":
            return MappingMode.defaultShortRead.rawValue
        case "asm5":
            return MappingMode.minimap2Asm5.rawValue
        case "splice":
            return MappingMode.minimap2Splice.rawValue
        case let value?:
            return value
        }
    }

    private func deriveSampleName(from inputURL: URL, pairedEnd: Bool) -> String {
        var name = inputURL.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".gz") {
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        if name.lowercased().hasSuffix(".fastq") || name.lowercased().hasSuffix(".fq") {
            name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        }
        if pairedEnd {
            for suffix in ["_R1", "_1", "_R1_001", ".R1"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

}

/// One progress line of `lungfish-cli map`.
///
/// On a terminal each update overwrites the previous one (carriage return, no
/// newline). Redirected to a file or a pipe there is nothing to overwrite, so
/// updates ran together on one line; there each update is its own line.
enum MapProgressLine {
    static func render(_ text: String, isTerminal: Bool) -> String {
        isTerminal ? "\r\(text)" : "\(text)\n"
    }
}
