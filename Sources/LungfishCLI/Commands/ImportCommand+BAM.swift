// ImportCommand+BAM.swift - The import bam leaf, moved out of ImportCommand.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// `import bam` lives here, moved out of ImportCommand.swift, which is at its
/// size baseline.
extension ImportCommand {

    /// Import a BAM/CRAM alignment file into a Lungfish project.
    ///
    /// Validates that the alignment file exists, copies it to the output
    /// directory, creates an index if needed, and prints alignment statistics.
    struct BAMSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bam",
            abstract: "Import a BAM or CRAM alignment file"
        )

        @Argument(help: "Path to the BAM or CRAM file")
        var inputFile: String

        @Option(
            name: [.customLong("output-dir"), .customShort("o")],
            help: "Output project directory (default: current directory)"
        )
        var outputDir: String?

        @Option(
            name: .customLong("name"),
            help: "Display name for the alignment track (default: filename)"
        )
        var name: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let runClock = ProvenanceRunClock()
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)
            let outputDirectory = resolveOutputDirectory(outputDir)
            let attachesToBundle = outputDirectory.pathExtension.lowercased() == "lungfishref"
            // `--format json` prints the events the app's row shows, for the attach to a bundle since Phase 2.11
            // lane A63 and for a plain output folder since 2.12 lane 12.06 (A63 review note 4).
            let eventsOn = globalOptions.outputFormat == .json
            let emitter = ImportCLIEventEmitter(enabled: eventsOn, quiet: globalOptions.quiet)
            emitter.emitStart(kind: "alignment")

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                reportFailure("Input file not found: \(inputFile)", formatter: formatter, emitter: emitter, eventsOn: eventsOn)
                throw CLIExitCode.inputError.exitCode
            }

            // Validate format from extension.
            var formatURL = inputURL
            if formatURL.pathExtension.lowercased() == "gz" {
                formatURL = formatURL.deletingPathExtension()
            }
            let ext = formatURL.pathExtension.lowercased()
            guard ["bam", "cram", "sam"].contains(ext) else {
                reportFailure(
                    "Unsupported alignment format: .\(ext). Expected .bam, .cram, or .sam",
                    formatter: formatter, emitter: emitter, eventsOn: eventsOn
                )
                throw CLIExitCode.formatError.exitCode
            }

            // `-o` historically meant "a plain directory to drop
            // loose alignment files into", which silently produced a BAM/BAI
            // pair with no manifest entry when someone pointed it at an
            // existing `.lungfishref` bundle, so the sidebar and viewer never
            // saw the alignment because `manifest.alignments` stayed empty.
            // Detect that case and attach the alignment as a real track through
            // BAMImportService, the import the GUI Import Center runs.
            if attachesToBundle {
                guard FileManager.default.fileExists(
                    atPath: outputDirectory.appendingPathComponent(BundleManifest.filename).path
                ) else {
                    reportFailure(
                        "\(outputDir ?? outputDirectory.path) looks like a .lungfishref bundle path, but no bundle exists there yet. "
                            + "`lungfish-cli import bam` writes loose files into a plain directory; to attach an alignment to an existing "
                            + "reference bundle, create the bundle first and use `lungfish-cli bam adopt-mapping --bundle <bundle> --mapping-result <dir> --name <name>`.",
                        formatter: formatter, emitter: emitter, eventsOn: eventsOn
                    )
                    throw CLIExitCode.inputError.exitCode
                }
                try await runAttachToExistingBundle(
                    inputURL: inputURL,
                    ext: ext,
                    bundleURL: outputDirectory,
                    formatter: formatter,
                    emitter: emitter,
                    eventsOn: eventsOn
                )
                return
            }

            printHumanLine(formatter.header("BAM/CRAM Import"), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(formatter.keyValueTable([
                ("Input", inputURL.lastPathComponent),
                ("Format", ext.uppercased()),
                ("Output", outputDirectory.path),
            ]), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)

            // Create output directory.
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            } catch {
                guard eventsOn else { throw error }
                emitter.emitFailed(CLIFailureWords.describe(error))
                throw CLIExitCode.failure.exitCode
            }

            let alignmentFormat = alignmentFileFormat(forExtension: ext)
            var createdArtifacts: [URL] = []
            do {
                // Copy alignment file.
                emitter.emitProgress(0.1, message: "Copying \(inputURL.lastPathComponent)...")
                let destURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
                if try copyImportArtifactIfNeeded(from: inputURL, to: destURL) {
                    createdArtifacts.append(destURL)
                    if !globalOptions.quiet {
                        printHumanLine(formatter.info("Copied alignment file"), eventsOn: eventsOn)
                    }
                }

                // Check for companion index file and copy if present.
                var indexArtifact = try copyCompanionIndex(
                    for: inputURL,
                    to: outputDirectory,
                    formatter: formatter,
                    eventsOn: eventsOn,
                    createdArtifacts: &createdArtifacts
                )

                // Attempt to collect statistics via samtools.
                var statistics: BAMImportStatistics?
                var provenanceMessages: [String] = []
                var provenanceSteps: [ProvenanceStep] = []
                let samtoolsVersion = await detectNativeToolVersion(.samtools)

                emitter.emitProgress(0.3, message: "Collecting alignment statistics...")
                do {
                    let runner = NativeToolRunner.shared
                    let idxstatsClock = ProvenanceRunClock()
                    let idxstatsResult = try await runner.run(
                        .samtools,
                        arguments: ["idxstats", destURL.path],
                        timeout: 120
                    )
                    let idxstatsCompletedAt = idxstatsClock.now
                    provenanceSteps.append(try nativeToolProvenanceStep(
                        toolName: "samtools",
                        toolVersion: samtoolsVersion,
                        result: idxstatsResult,
                        fallbackArgv: ["samtools", "idxstats", destURL.path],
                        inputs: [
                            ProvenanceFileDescriptor.file(url: destURL, format: alignmentFormat, role: .input)
                        ],
                        outputs: [],
                        startedAt: idxstatsClock.startedAt,
                        completedAt: idxstatsCompletedAt
                    ))
                    if idxstatsResult.isSuccess {
                        // idxstats counts alignment records, so the reads come from flagstat's primary lines.
                        let flagstat = await collectFlagstat(
                            of: destURL, version: samtoolsVersion, format: alignmentFormat,
                            steps: &provenanceSteps, messages: &provenanceMessages
                        )
                        statistics = BAMImportStatistics(idxstats: idxstatsResult.stdout, flagstat: flagstat)
                    } else {
                        provenanceMessages.append(
                            "samtools idxstats exited \(idxstatsResult.exitCode): \(idxstatsResult.stderr)"
                        )
                    }
                    if !idxstatsResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        provenanceMessages.append("samtools idxstats stderr: \(idxstatsResult.stderr)")
                    }
                } catch {
                    // samtools not available - skip stats.
                    provenanceMessages.append("samtools idxstats unavailable: \(error.localizedDescription)")
                    if !globalOptions.quiet {
                        warn("samtools not available; skipping statistics collection", formatter: formatter, emitter: emitter, eventsOn: eventsOn)
                    }
                }

                // If no source index was copied and a destination index is already present,
                // do not claim that stale index as an output of this import.
                if indexArtifact == nil, let existingIndexURL = existingAlignmentIndex(for: destURL) {
                    throw ImportArtifactConflictError(sourceURL: inputURL, destinationURL: existingIndexURL)
                }

                // If no index was copied and samtools is available, try creating one.
                if indexArtifact == nil {
                    do {
                        let runner = NativeToolRunner.shared
                        emitter.emitProgress(0.6, message: "Creating index...")
                        if !globalOptions.quiet {
                            printHumanLine(formatter.info("Creating index..."), eventsOn: eventsOn)
                        }
                        let indexClock = ProvenanceRunClock()
                        let indexResult = try await runner.run(
                            .samtools,
                            arguments: ["index", destURL.path],
                            timeout: 3600
                        )
                        let indexCompletedAt = indexClock.now
                        var indexStepOutputs: [ProvenanceFileDescriptor] = []
                        if indexResult.isSuccess {
                            if let generatedIndexURL = existingAlignmentIndex(for: destURL) {
                                indexArtifact = (sourceURL: nil, destinationURL: generatedIndexURL)
                                createdArtifacts.append(generatedIndexURL)
                                indexStepOutputs = [
                                    try ProvenanceFileDescriptor.file(
                                        url: generatedIndexURL,
                                        format: .unknown,
                                        role: .index
                                    )
                                ]
                            }
                            if !globalOptions.quiet {
                                printHumanLine(formatter.success("Index created"), eventsOn: eventsOn)
                            }
                        } else {
                            provenanceMessages.append(
                                "samtools index exited \(indexResult.exitCode): \(indexResult.stderr)"
                            )
                            warn("Failed to create index. The file may need sorting first.", formatter: formatter, emitter: emitter, eventsOn: eventsOn)
                        }
                        provenanceSteps.append(try nativeToolProvenanceStep(
                            toolName: "samtools",
                            toolVersion: samtoolsVersion,
                            result: indexResult,
                            fallbackArgv: ["samtools", "index", destURL.path],
                            inputs: [
                                ProvenanceFileDescriptor.file(url: destURL, format: alignmentFormat, role: .input)
                            ],
                            outputs: indexStepOutputs,
                            startedAt: indexClock.startedAt,
                            completedAt: indexCompletedAt
                        ))
                        if !indexResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            provenanceMessages.append("samtools index stderr: \(indexResult.stderr)")
                        }
                    } catch {
                        provenanceMessages.append("samtools index unavailable: \(error.localizedDescription)")
                        warn("samtools not available; could not create index", formatter: formatter, emitter: emitter, eventsOn: eventsOn)
                    }
                }

                emitter.emitProgress(0.9, message: "Writing provenance...")
                let inputRecords = bamInputRecords(inputURL: inputURL, format: alignmentFormat, indexArtifact: indexArtifact)
                let outputRecords = bamOutputRecords(destURL: destURL, format: alignmentFormat, indexArtifact: indexArtifact)
                try await CLIProvenanceSupport.recordSingleStepRun(
                    name: "lungfish import bam",
                    parameters: bamProvenanceParameters(inputURL: inputURL),
                    defaults: bamProvenanceDefaults(),
                    resolved: bamProvenanceResolved(
                        outputURL: destURL,
                        format: ext,
                        indexArtifact: indexArtifact,
                        statistics: statistics
                    ),
                    toolName: "lungfish import bam",
                    toolVersion: LungfishCLI.configuration.version,
                    command: bamProvenanceCommand(inputURL: inputURL, outputDirectory: outputDirectory),
                    extraSteps: provenanceSteps,
                    inputs: inputRecords,
                    outputs: outputRecords,
                    exitCode: 0,
                    wallTime: runClock.elapsed,
                    stderr: provenanceMessages.isEmpty ? nil : provenanceMessages.joined(separator: "\n"),
                    status: .completed,
                    outputDirectory: outputDirectory
                )

                printHumanLine("", eventsOn: eventsOn)
                printHumanLine(formatter.header("Summary"), eventsOn: eventsOn)
                printHumanLine("", eventsOn: eventsOn)

                if let statistics {
                    printHumanLine(formatter.keyValueTable(statistics.summaryRows(formatNumber: formatNumber)), eventsOn: eventsOn)
                    if let note = statistics.alignmentCountsNote, !globalOptions.quiet {
                        warn(note, formatter: formatter, emitter: emitter, eventsOn: eventsOn)
                    }
                } else {
                    printHumanLine(formatter.keyValueTable([
                        ("File", destURL.lastPathComponent),
                        ("Index", indexArtifact == nil ? "not found" : "found"),
                    ]), eventsOn: eventsOn)
                }

                printHumanLine("", eventsOn: eventsOn)
                printHumanLine(formatter.success("BAM import complete: \(destURL.lastPathComponent)"), eventsOn: eventsOn)
                // The copy is what a plain folder import makes, so the completion names it in `outputs`.
                emitter.emitComplete(attachedTo: destURL, message: "BAM import complete: \(destURL.lastPathComponent)")
            } catch {
                removeCreatedImportArtifacts(createdArtifacts)
                // With events on, the row reads the failure from the `failed` event and the exit is 1, as for the attach.
                guard eventsOn else { throw error }
                emitter.emitFailed(CLIFailureWords.describe(error))
                throw CLIExitCode.failure.exitCode
            }
        }

        /// Attaches `inputURL` to an existing `.lungfishref` bundle as a manifest alignment track through
        /// `BAMImportService.importBAM`, the import the Import Center's BAM row runs (Phase 2.11 lane A63).
        /// The service sorts and indexes the copy it makes in the bundle, so an unsorted BAM, a SAM file and
        /// a CRAM file import as they did when the app ran the service in a helper process, and the record it
        /// writes in the bundle names this command. With `--format json` the run prints the row's events.
        /// SIGTERM, the app's Cancel, cancels the import, removes what the run added to the bundle's
        /// alignments folder, records the run as cancelled in the project and exits 125 (decision S7).
        private func runAttachToExistingBundle(
            inputURL: URL,
            ext: String,
            bundleURL: URL,
            formatter: TerminalFormatter,
            emitter: ImportCLIEventEmitter,
            eventsOn: Bool
        ) async throws {
            let startedAt = Date()
            let trackName = name ?? inputURL.deletingPathExtension().lastPathComponent
            let command = [CLICommandIdentity.executableName, "import", "bam", inputURL.path, "--output-dir", bundleURL.path]
                + (name.map { ["--name", $0] } ?? [])

            printHumanLine(formatter.header("BAM/CRAM Import"), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)
            printHumanLine(formatter.keyValueTable([
                ("Input", inputURL.lastPathComponent),
                ("Format", ext.uppercased()),
                ("Bundle", bundleURL.path),
            ]), eventsOn: eventsOn)
            printHumanLine("", eventsOn: eventsOn)

            let alignmentsFolder = bundleURL.appendingPathComponent("alignments", isDirectory: true)
            let entriesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: alignmentsFolder.path)) ?? [])
            let outcome = await ImportCancellation.run { () async throws -> BAMImportService.ImportResult in
                try await BAMImportService.importBAM(
                    bamURL: inputURL,
                    bundleURL: bundleURL,
                    name: trackName,
                    progressHandler: { progress, message in
                        emitter.emitProgress(max(0.0, min(1.0, progress)), message: message)
                    },
                    provenanceCommand: command
                )
            }

            switch outcome {
            case .success(let imported):
                emitter.emitComplete(
                    attachedTo: bundleURL,
                    message: "\(imported.mappedReads + imported.unmappedReads) reads imported"
                )
                if !globalOptions.quiet {
                    printHumanLine("", eventsOn: eventsOn)
                    printHumanLine(formatter.header("Summary"), eventsOn: eventsOn)
                    printHumanLine("", eventsOn: eventsOn)
                    printHumanLine(formatter.keyValueTable([
                        ("Track ID", imported.trackInfo.id),
                        ("Track name", imported.trackInfo.name),
                        ("Mapped reads", formatNumber(imported.mappedReads)),
                        ("Unmapped reads", formatNumber(imported.unmappedReads)),
                    ]), eventsOn: eventsOn)
                    printHumanLine("", eventsOn: eventsOn)
                    printHumanLine(
                        formatter.success("BAM import complete: attached '\(imported.trackInfo.name)' to \(bundleURL.lastPathComponent)"),
                        eventsOn: eventsOn
                    )
                }
            case .failure(let error) where error is CancellationError:
                removeNewEntries(in: alignmentsFolder, notIn: entriesBefore)
                throw await ImportCancellation.finish(
                    emitter: emitter,
                    command: "import bam",
                    parameters: ["input": .file(inputURL), "bundle": .file(bundleURL)],
                    recordDirectory: ProjectTempDirectory.findProjectRoot(bundleURL) ?? bundleURL.deletingLastPathComponent(),
                    startedAt: startedAt
                )
            case .failure(let error):
                reportFailure(error.localizedDescription, formatter: formatter, emitter: emitter, eventsOn: eventsOn)
                throw CLIExitCode.failure.exitCode
            }
        }

        /// Tells the person, or the app's row, why the import stopped.
        private func reportFailure(
            _ message: String,
            formatter: TerminalFormatter,
            emitter: ImportCLIEventEmitter,
            eventsOn: Bool
        ) {
            if eventsOn {
                emitter.emitFailed(message)
            } else {
                print(formatter.error(message))
            }
        }

        /// Tells the person a warning as the text output always did, or the app's row as a `log` event.
        private func warn(_ message: String, formatter: TerminalFormatter, emitter: ImportCLIEventEmitter, eventsOn: Bool) {
            if eventsOn {
                emitter.emitWarning(message)
            } else {
                print(formatter.warning(message))
            }
        }

        /// Removes what a cancelled run added to `folder`, the entries it did not hold before the run.
        private func removeNewEntries(in folder: URL, notIn before: Set<String>) {
            let now = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for entry in now where !before.contains(entry) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry))
            }
        }

        /// Copies a companion index file (.bai, .csi, .crai) if one exists next to the input.
        private func copyCompanionIndex(
            for inputURL: URL,
            to outputDirectory: URL,
            formatter: TerminalFormatter,
            eventsOn: Bool,
            createdArtifacts: inout [URL]
        ) throws -> (sourceURL: URL?, destinationURL: URL)? {
            let fm = FileManager.default
            let basePath = inputURL.path

            // Common index file patterns.
            let candidates = [
                basePath + ".bai",
                basePath + ".csi",
                basePath + ".crai",
                inputURL.deletingPathExtension().path + ".bai",
            ]

            for candidatePath in candidates {
                if fm.fileExists(atPath: candidatePath) {
                    let indexURL = URL(fileURLWithPath: candidatePath)
                    let destIndex = outputDirectory.appendingPathComponent(indexURL.lastPathComponent)
                    if try copyImportArtifactIfNeeded(from: indexURL, to: destIndex) {
                        createdArtifacts.append(destIndex)
                        if !globalOptions.quiet {
                            printHumanLine(formatter.info("Copied index: \(indexURL.lastPathComponent)"), eventsOn: eventsOn)
                        }
                    }
                    return (sourceURL: indexURL, destinationURL: destIndex)
                }
            }
            return nil
        }

        private func existingAlignmentIndex(for alignmentURL: URL) -> URL? {
            let candidates = [
                alignmentURL.path + ".bai",
                alignmentURL.path + ".csi",
                alignmentURL.path + ".crai",
                alignmentURL.deletingPathExtension().path + ".bai",
            ]
            return candidates
                .map(URL.init(fileURLWithPath:))
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        private func bamInputRecords(
            inputURL: URL,
            format: FileFormat,
            indexArtifact: (sourceURL: URL?, destinationURL: URL)?
        ) -> [FileRecord] {
            var records = [
                ProvenanceRecorder.fileRecord(url: inputURL, format: format, role: .input)
            ]
            if let sourceURL = indexArtifact?.sourceURL {
                records.append(ProvenanceRecorder.fileRecord(url: sourceURL, format: .unknown, role: .index))
            }
            return records
        }

        private func bamOutputRecords(
            destURL: URL,
            format: FileFormat,
            indexArtifact: (sourceURL: URL?, destinationURL: URL)?
        ) -> [FileRecord] {
            var records = [
                ProvenanceRecorder.fileRecord(url: destURL, format: format, role: .output)
            ]
            if let indexURL = indexArtifact?.destinationURL {
                records.append(ProvenanceRecorder.fileRecord(url: indexURL, format: .unknown, role: .index))
            }
            return records
        }

        private func bamProvenanceCommand(inputURL: URL, outputDirectory: URL) -> [String] {
            var command = [CLICommandIdentity.executableName, "import", "bam", inputURL.path, "--output-dir", outputDirectory.path]
            if let name {
                command += ["--name", name]
            }
            if globalOptions.quiet {
                command.append("--quiet")
            }
            if globalOptions.noColor {
                command.append("--no-color")
            }
            return command
        }

        private func bamProvenanceParameters(
            inputURL: URL
        ) -> [String: ParameterValue] {
            [
                "inputFile": .string(inputURL.path),
                "outputDir": outputDir.map(ParameterValue.string) ?? .null,
                "name": name.map(ParameterValue.string) ?? .null,
                "quiet": .boolean(globalOptions.quiet),
                "noColor": .boolean(globalOptions.noColor)
            ]
        }

        private func bamProvenanceDefaults() -> [String: ParameterValue] {
            [
                "outputDir": .string(FileManager.default.currentDirectoryPath),
                "name": .null,
                "quiet": .boolean(false),
                "noColor": .boolean(false)
            ]
        }

        private func bamProvenanceResolved(
            outputURL: URL,
            format: String,
            indexArtifact: (sourceURL: URL?, destinationURL: URL)?,
            statistics: BAMImportStatistics?
        ) -> [String: ParameterValue] {
            var resolved: [String: ParameterValue] = [
                "outputFile": .string(outputURL.path),
                "outputDirectory": .string(outputURL.deletingLastPathComponent().path),
                "format": .string(format),
                "indexFile": indexArtifact.map { .string($0.destinationURL.path) } ?? .null,
                "indexSource": indexArtifact?.sourceURL.map { .string($0.path) } ?? .null,
                "statsCollected": .boolean(statistics != nil),
                // A run that collected no statistics keeps the zeros it always recorded.
                "totalReads": .integer(0),
                "mappedReads": .integer(0),
                "unmappedReads": .integer(0),
                "referenceContigs": .integer(0)
            ]
            if let statistics {
                resolved.merge(statistics.provenanceValues()) { _, collected in collected }
            }
            return resolved
        }

        /// Runs `samtools flagstat` on the copied file and returns its text, or `nil` when samtools failed or is missing. The
        /// reads come from its primary lines (`BAMImportStatistics`), and without them the Summary says it counts alignments.
        private func collectFlagstat(
            of destURL: URL,
            version: String,
            format: FileFormat,
            steps: inout [ProvenanceStep],
            messages: inout [String]
        ) async -> String? {
            let clock = ProvenanceRunClock()
            do {
                let result = try await NativeToolRunner.shared.run(.samtools, arguments: ["flagstat", destURL.path], timeout: 3600)
                let completedAt = clock.now
                steps.append(try nativeToolProvenanceStep(
                    toolName: "samtools",
                    toolVersion: version,
                    result: result,
                    fallbackArgv: ["samtools", "flagstat", destURL.path],
                    inputs: [
                        ProvenanceFileDescriptor.file(url: destURL, format: format, role: .input)
                    ],
                    outputs: [],
                    startedAt: clock.startedAt,
                    completedAt: completedAt
                ))
                guard result.isSuccess else {
                    messages.append("samtools flagstat exited \(result.exitCode): \(result.stderr)")
                    return nil
                }
                return result.stdout
            } catch {
                messages.append("samtools flagstat unavailable: \(error.localizedDescription)")
                return nil
            }
        }

        private func alignmentFileFormat(forExtension ext: String) -> FileFormat {
            switch ext {
            case "bam": return .bam
            case "cram": return .cram
            case "sam": return .sam
            default: return .unknown
            }
        }
    }
}

/// The counts the plain route of `import bam` prints and records. Flagstat's `primary` and `primary mapped` lines give reads.
/// The idxstats sums count alignment records, with each secondary and supplementary record once more and the `*` row of the
/// unmapped records that have no reference, so they are no read counts. Without the primary lines (a samtools before 1.9, a
/// flagstat that failed, or text that did not parse) the counts shown are the alignment records, and the Summary and the
/// record say so. The `totalReads`, `mappedReads` and `unmappedReads` keys of the record hold reads or null, never records.
struct BAMImportStatistics: Equatable {
    struct Counts: Equatable {
        var mapped: Int64
        var unmapped: Int64
        var total: Int64 { mapped + unmapped }
    }

    enum Unit: String {
        case reads
        case alignments
    }

    /// Reads, from flagstat's primary lines, or `nil` when it gave none.
    let reads: Counts?
    /// The idxstats sums, one count for each alignment record.
    let alignments: Counts
    /// The reference sequences idxstats listed, its `*` row left out.
    let referenceContigs: Int

    init(idxstats: String, flagstat: String?) {
        var mapped: Int64 = 0
        var unmapped: Int64 = 0
        var contigs = 0
        for line in idxstats.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 4 else { continue }
            mapped += Int64(cols[2]) ?? 0
            unmapped += Int64(cols[3]) ?? 0
            if cols[0] != "*" { contigs += 1 }
        }
        alignments = Counts(mapped: mapped, unmapped: unmapped)
        referenceContigs = contigs
        reads = flagstat.flatMap(Self.primaryReads(in:))
    }

    /// `primary mapped` and `primary` less that, as `AlignmentMetadataDatabase.primaryReadCounts()` reads them. `nil` when
    /// either line is missing or `primary` is below `primary mapped`.
    private static func primaryReads(in flagstat: String) -> Counts? {
        let parsed = (try? AlignmentMetadataDatabase.parseFlagstat(json: flagstat))
            ?? (try? AlignmentMetadataDatabase.parseFlagstat(flagstat))
        guard let categories = parsed?.categories,
              let mapped = categories["primary mapped"], let primary = categories["primary"] else { return nil }
        let mappedReads = mapped.qcPass + mapped.qcFail
        let primaryReads = primary.qcPass + primary.qcFail
        guard mappedReads >= 0, primaryReads >= mappedReads else { return nil }
        return Counts(mapped: mappedReads, unmapped: primaryReads - mappedReads)
    }

    var unit: Unit { reads == nil ? .alignments : .reads }

    /// The counts the Summary prints and the read keys of the record hold: the reads when flagstat gave them.
    var shown: Counts { reads ?? alignments }

    /// The Summary rows. The unit is in every label, so a person never reads alignment records as reads.
    func summaryRows(formatNumber: (Int64) -> String) -> [(String, String)] {
        let counts = shown
        let noun = unit.rawValue
        let percent = counts.total > 0 ? String(format: "%.2f%%", Double(counts.mapped) / Double(counts.total) * 100) : "N/A"
        return [
            ("Total \(noun)", formatNumber(counts.total)),
            ("Mapped \(noun)", "\(formatNumber(counts.mapped)) (\(percent))"),
            ("Unmapped \(noun)", formatNumber(counts.unmapped)),
            ("Reference contigs", String(referenceContigs)),
        ]
    }

    /// Words after the Summary when its counts are alignment records, `nil` for reads.
    var alignmentCountsNote: String? {
        guard reads == nil else { return nil }
        return "These counts are alignments, so a read that aligns in more than one place counts once for each place. "
            + "Samtools flagstat gave no read counts for this file. "
            + "Run the import again, and if this note returns, check that the installed samtools is version 1.9 or later."
    }

    /// The count keys of the run's record. `countUnit` says which pair the Summary printed, and the alignment records are
    /// under their own keys, so no key changes its meaning.
    func provenanceValues() -> [String: ParameterValue] {
        func integer(_ value: Int64?) -> ParameterValue { value.map { .integer(Int($0)) } ?? .null }
        return [
            "countUnit": .string(unit.rawValue),
            "totalReads": integer(reads?.total),
            "mappedReads": integer(reads?.mapped),
            "unmappedReads": integer(reads?.unmapped),
            "totalAlignments": integer(alignments.total),
            "mappedAlignments": integer(alignments.mapped),
            "unmappedAlignments": integer(alignments.unmapped),
            "referenceContigs": .integer(referenceContigs),
        ]
    }
}
