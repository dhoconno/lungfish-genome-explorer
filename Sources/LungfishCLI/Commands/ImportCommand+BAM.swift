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
            // `--format json` makes the attach to a bundle print the events the app's row shows (Phase 2.11
            // lane A63). An output folder that is a plain directory keeps its text output.
            let eventsOn = globalOptions.outputFormat == .json && attachesToBundle
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

            print(formatter.header("BAM/CRAM Import"))
            print("")
            print(formatter.keyValueTable([
                ("Input", inputURL.lastPathComponent),
                ("Format", ext.uppercased()),
                ("Output", outputDirectory.path),
            ]))
            print("")

            // Create output directory.
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            let alignmentFormat = alignmentFileFormat(forExtension: ext)
            var createdArtifacts: [URL] = []
            do {
                // Copy alignment file.
                let destURL = outputDirectory.appendingPathComponent(inputURL.lastPathComponent)
                if try copyImportArtifactIfNeeded(from: inputURL, to: destURL) {
                    createdArtifacts.append(destURL)
                    if !globalOptions.quiet {
                        print(formatter.info("Copied alignment file"))
                    }
                }

                // Check for companion index file and copy if present.
                var indexArtifact = try copyCompanionIndex(
                    for: inputURL,
                    to: outputDirectory,
                    formatter: formatter,
                    createdArtifacts: &createdArtifacts
                )

                // Attempt to collect statistics via samtools.
                var totalReads: Int64 = 0
                var mappedReads: Int64 = 0
                var unmappedReads: Int64 = 0
                var refContigs = 0
                var statsCollected = false
                var provenanceMessages: [String] = []
                var provenanceSteps: [ProvenanceStep] = []
                let samtoolsVersion = await detectNativeToolVersion(.samtools)

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
                        let lines = idxstatsResult.stdout.split(separator: "\n")
                        for line in lines {
                            let cols = line.split(separator: "\t")
                            guard cols.count >= 4 else { continue }
                            let refName = String(cols[0])
                            let mapped = Int64(cols[2]) ?? 0
                            let unmapped = Int64(cols[3]) ?? 0
                            mappedReads += mapped
                            unmappedReads += unmapped
                            if refName != "*" {
                                refContigs += 1
                            }
                        }
                        totalReads = mappedReads + unmappedReads
                        statsCollected = true
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
                        print(formatter.warning("samtools not available; skipping statistics collection"))
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
                        if !globalOptions.quiet {
                            print(formatter.info("Creating index..."))
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
                                print(formatter.success("Index created"))
                            }
                        } else {
                            provenanceMessages.append(
                                "samtools index exited \(indexResult.exitCode): \(indexResult.stderr)"
                            )
                            print(formatter.warning(
                                "Failed to create index. The file may need sorting first."
                            ))
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
                        print(formatter.warning("samtools not available; could not create index"))
                    }
                }

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
                        statsCollected: statsCollected,
                        totalReads: totalReads,
                        mappedReads: mappedReads,
                        unmappedReads: unmappedReads,
                        refContigs: refContigs
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

                print("")
                print(formatter.header("Summary"))
                print("")

                if statsCollected {
                    let mappedPct = totalReads > 0
                        ? String(format: "%.2f%%", Double(mappedReads) / Double(totalReads) * 100)
                        : "N/A"
                    print(formatter.keyValueTable([
                        ("Total reads", formatNumber(totalReads)),
                        ("Mapped reads", "\(formatNumber(mappedReads)) (\(mappedPct))"),
                        ("Unmapped reads", formatNumber(unmappedReads)),
                        ("Reference contigs", String(refContigs)),
                    ]))
                } else {
                    print(formatter.keyValueTable([
                        ("File", destURL.lastPathComponent),
                        ("Index", indexArtifact == nil ? "not found" : "found"),
                    ]))
                }

                print("")
                print(formatter.success("BAM import complete: \(destURL.lastPathComponent)"))
            } catch {
                removeCreatedImportArtifacts(createdArtifacts)
                throw error
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
                            print(formatter.info("Copied index: \(indexURL.lastPathComponent)"))
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
            statsCollected: Bool,
            totalReads: Int64,
            mappedReads: Int64,
            unmappedReads: Int64,
            refContigs: Int
        ) -> [String: ParameterValue] {
            [
                "outputFile": .string(outputURL.path),
                "outputDirectory": .string(outputURL.deletingLastPathComponent().path),
                "format": .string(format),
                "indexFile": indexArtifact.map { .string($0.destinationURL.path) } ?? .null,
                "indexSource": indexArtifact?.sourceURL.map { .string($0.path) } ?? .null,
                "statsCollected": .boolean(statsCollected),
                "totalReads": .integer(Int(totalReads)),
                "mappedReads": .integer(Int(mappedReads)),
                "unmappedReads": .integer(Int(unmappedReads)),
                "referenceContigs": .integer(refContigs)
            ]
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
