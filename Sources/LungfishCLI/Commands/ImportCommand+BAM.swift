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

        @OptionGroup(visibility: .hidden) var globalOptions: GlobalOptions

        func run() async throws {
            let runClock = ProvenanceRunClock()
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let inputURL = URL(fileURLWithPath: inputFile)

            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                print(formatter.error("Input file not found: \(inputFile)"))
                throw CLIExitCode.inputError.exitCode
            }

            // Validate format from extension.
            var formatURL = inputURL
            if formatURL.pathExtension.lowercased() == "gz" {
                formatURL = formatURL.deletingPathExtension()
            }
            let ext = formatURL.pathExtension.lowercased()
            guard ["bam", "cram", "sam"].contains(ext) else {
                print(formatter.error("Unsupported alignment format: .\(ext). Expected .bam, .cram, or .sam"))
                throw CLIExitCode.formatError.exitCode
            }

            let outputDirectory = resolveOutputDirectory(outputDir)

            // `-o` historically meant "a plain directory to drop
            // loose alignment files into", which silently produced a BAM/BAI
            // pair with no manifest entry when someone pointed it at an
            // existing `.lungfishref` bundle — the sidebar and viewer never
            // see the alignment because `manifest.alignments` stays empty.
            // Detect that case and attach the alignment as a real track via
            // the same PreparedAlignmentAttachmentService the GUI Import
            // Center uses, instead of silently mis-importing.
            if outputDirectory.pathExtension.lowercased() == "lungfishref" {
                guard FileManager.default.fileExists(
                    atPath: outputDirectory.appendingPathComponent(BundleManifest.filename).path
                ) else {
                    print(formatter.error(
                        "\(outputDir ?? outputDirectory.path) looks like a .lungfishref bundle path, but no bundle exists there yet. "
                            + "`lungfish-cli import bam` writes loose files into a plain directory; to attach an alignment to an existing "
                            + "reference bundle, create the bundle first and use `lungfish-cli bam adopt-mapping --bundle <bundle> --mapping-result <dir> --name <name>`."
                    ))
                    throw CLIExitCode.inputError.exitCode
                }
                try await runAttachToExistingBundle(
                    inputURL: inputURL,
                    ext: ext,
                    bundleURL: outputDirectory,
                    formatter: formatter,
                    runClock: runClock
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

        /// Attaches `inputURL` to an existing `.lungfishref` bundle as a
        /// real manifest alignment track, using the same
        /// `PreparedAlignmentAttachmentService` primitive the GUI Import
        /// Center's `--bam-import-helper` path uses (`BAMImportHelper.swift`
        /// -> `BAMImportService.importBAM` -> the same attachment core).
        /// Requires a coordinate-sorted input, matching this command's
        /// pre-existing assumption (it has never sorted; it only indexes).
        private func runAttachToExistingBundle(
            inputURL: URL,
            ext: String,
            bundleURL: URL,
            formatter: TerminalFormatter,
            runClock: ProvenanceRunClock
        ) async throws {
            guard ext != "sam" else {
                print(formatter.error("Cannot attach a .sam alignment to a bundle. Convert to sorted, indexed BAM first (see project convention: never store SAM)."))
                throw CLIExitCode.formatError.exitCode
            }
            let format: AlignmentFormat = ext == "cram" ? .cram : .bam

            print(formatter.header("BAM/CRAM Import"))
            print("")
            print(formatter.keyValueTable([
                ("Input", inputURL.lastPathComponent),
                ("Format", ext.uppercased()),
                ("Bundle", bundleURL.path),
            ]))
            print("")

            let tempDirectory = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-cli-bam-attach-",
                contextURL: bundleURL
            )
            defer { try? FileManager.default.removeItem(at: tempDirectory) }

            let stagedBAMURL = tempDirectory.appendingPathComponent(inputURL.lastPathComponent)
            try FileManager.default.copyItem(at: inputURL, to: stagedBAMURL)

            var stagedIndexURL: URL?
            if let sourceIndexURL = existingAlignmentIndex(for: inputURL) {
                let destination = tempDirectory.appendingPathComponent(sourceIndexURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceIndexURL, to: destination)
                stagedIndexURL = destination
            } else {
                if !globalOptions.quiet {
                    print(formatter.info("Creating index..."))
                }
                let runner = NativeToolRunner.shared
                let indexResult = try await runner.run(.samtools, arguments: ["index", stagedBAMURL.path], timeout: 3600)
                guard indexResult.isSuccess else {
                    print(formatter.error("Failed to index alignment. The file may need coordinate sorting first."))
                    throw CLIExitCode.failure.exitCode
                }
                stagedIndexURL = URL(fileURLWithPath: stagedBAMURL.path + ".bai")
            }
            guard let resolvedStagedIndexURL = stagedIndexURL,
                  FileManager.default.fileExists(atPath: resolvedStagedIndexURL.path) else {
                print(formatter.error("Could not produce an index for the alignment."))
                throw CLIExitCode.failure.exitCode
            }

            let outputTrackID = "aln_\(UUID().uuidString.prefix(8))"
            let trackName = name ?? inputURL.deletingPathExtension().lastPathComponent
            let service = PreparedAlignmentAttachmentService()
            let request = PreparedAlignmentAttachmentRequest(
                bundleURL: bundleURL,
                stagedBAMURL: stagedBAMURL,
                stagedIndexURL: resolvedStagedIndexURL,
                outputTrackID: outputTrackID,
                outputTrackName: trackName,
                relativeDirectory: "alignments/imported",
                format: format
            )
            let attachment = try await service.attach(request: request)

            try await CLIProvenanceSupport.recordSingleStepRun(
                name: "lungfish import bam",
                parameters: bamProvenanceParameters(inputURL: inputURL),
                defaults: bamProvenanceDefaults(),
                resolved: [
                    "bundle": .string(bundleURL.path),
                    "trackId": .string(outputTrackID),
                    "trackName": .string(trackName),
                    "mappedReads": .integer(Int(attachment.mappedReads)),
                    "unmappedReads": .integer(Int(attachment.unmappedReads))
                ],
                toolName: "lungfish import bam",
                toolVersion: LungfishCLI.configuration.version,
                command: [CLICommandIdentity.executableName, "import", "bam", inputURL.path, "--output-dir", bundleURL.path]
                    + (name.map { ["--name", $0] } ?? []),
                inputs: [ProvenanceRecorder.fileRecord(url: inputURL, format: alignmentFileFormat(forExtension: ext), role: .input)],
                outputs: [
                    ProvenanceRecorder.fileRecord(url: attachment.bamURL, format: alignmentFileFormat(forExtension: ext), role: .output),
                    ProvenanceRecorder.fileRecord(url: attachment.indexURL, format: .unknown, role: .index)
                ],
                exitCode: 0,
                wallTime: runClock.elapsed,
                stderr: nil,
                status: .completed,
                outputDirectory: bundleURL
            )

            print("")
            print(formatter.header("Summary"))
            print("")
            print(formatter.keyValueTable([
                ("Track ID", outputTrackID),
                ("Track name", trackName),
                ("Mapped reads", formatNumber(attachment.mappedReads)),
                ("Unmapped reads", formatNumber(attachment.unmappedReads)),
            ]))
            print("")
            print(formatter.success("BAM import complete: attached '\(trackName)' to \(bundleURL.lastPathComponent)"))
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
