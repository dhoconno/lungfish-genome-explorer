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

    var errorDescription: String? {
        switch self {
        case .unreadableSequenceInput(let path):
            return "Sequence input does not contain a readable FASTQ or FASTA payload: \(path)"
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
        read-mapping plugin pack (`lungfish conda install read-mapping`). BBMap is exposed
        from the required BBTools environment and is available once the managed toolchain
        is provisioned.
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
        help: "Mode/preset. minimap2: sr, map-ont, map-hifi, map-pb. bbmap: bbmap-standard, bbmap-pacbio."
    )
    var preset: String?

    @Option(
        name: [.customLong("output-dir"), .customShort("o")],
        help: "Output directory (default: mapping-<id> next to input)"
    )
    var outputDir: String?

    @Option(
        name: .customLong("sample-name"),
        help: "Sample name for BAM read groups and output naming"
    )
    var sampleName: String?

    @Flag(name: .customLong("paired"), help: "Input files are paired-end reads")
    var pairedEnd: Bool = false

    @Flag(name: .customLong("secondary"), help: "Keep secondary alignments in the normalized BAM")
    var secondary: Bool = false

    @Flag(name: .customLong("no-supplementary"), help: "Exclude supplementary alignments from the normalized BAM")
    var noSupplementary: Bool = false

    @Option(name: .customLong("min-mapq"), help: "Minimum mapping quality to retain in the normalized BAM")
    var minMapQ: Int = 0

    @Option(
        name: .customLong("advanced-options"),
        parsing: .unconditional,
        help: "Additional mapper options, written exactly as they should be passed to the underlying tool"
    )
    var advancedOptions: String = ""

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let threadCount = globalOptions.effectiveThreads

        let inputURLs = fastqFiles.map { URL(fileURLWithPath: $0) }
        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                print(formatter.error("Input file not found: \(url.path)"))
                throw ExitCode.failure
            }
        }
        let executionInputURLs: [URL]
        do {
            executionInputURLs = try Self.resolveExecutionInputURLs(for: inputURLs)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }

        if pairedEnd && inputURLs.count != 2 {
            print(formatter.error("Paired-end mode requires exactly 2 input files, got \(inputURLs.count)"))
            throw ExitCode.failure
        }

        let referenceInputURL = URL(fileURLWithPath: reference)
        guard FileManager.default.fileExists(atPath: referenceInputURL.path) else {
            print(formatter.error("Reference file not found: \(referenceInputURL.path)"))
            throw ExitCode.failure
        }
        guard let referenceURL = SequenceInputResolver.resolvePrimarySequenceURL(for: referenceInputURL),
              SequenceInputResolver.inputSequenceFormat(for: referenceInputURL) == .fasta else {
            print(formatter.error(MapInputResolutionError.unreadableSequenceInput(referenceInputURL.path).localizedDescription))
            throw ExitCode.failure
        }

        guard let selectedTool = MappingTool(rawValue: mapper) else {
            let valid = MappingTool.allCases.map(\.rawValue).joined(separator: ", ")
            print(formatter.error("Invalid mapper '\(mapper)'. Valid mappers: \(valid)"))
            throw ExitCode.failure
        }

        let selectedMode: MappingMode
        do {
            selectedMode = try resolveMode(tool: selectedTool, preset: preset)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }

        let outputDirectory: URL
        if let outputDir {
            outputDirectory = URL(fileURLWithPath: outputDir)
        } else {
            let runToken = String(UUID().uuidString.prefix(8))
            outputDirectory = inputURLs.first!.deletingLastPathComponent()
                .appendingPathComponent("mapping-\(runToken)")
        }

        let effectiveSampleName = sampleName ?? deriveSampleName(from: inputURLs.first!, pairedEnd: pairedEnd)
        let advancedArguments: [String]
        do {
            advancedArguments = try AdvancedCommandLineOptions.parse(advancedOptions)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw ExitCode.failure
        }

        let request = MappingRunRequest(
            tool: selectedTool,
            modeID: selectedMode.id,
            inputFASTQURLs: executionInputURLs,
            referenceFASTAURL: referenceURL,
            outputDirectory: outputDirectory,
            sampleName: effectiveSampleName,
            pairedEnd: pairedEnd,
            threads: threadCount,
            includeSecondary: secondary,
            includeSupplementary: !noSupplementary,
            minimumMappingQuality: minMapQ,
            advancedArguments: advancedArguments
        )

        print(formatter.header("Read Mapping"))
        print("")
        print(formatter.keyValueTable([
            ("Mapper", selectedTool.displayName),
            ("Mode", selectedMode.displayName),
            ("Input files", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Paired-end", pairedEnd ? "yes" : "no"),
            ("Reference", referenceURL.lastPathComponent),
            ("Threads", String(threadCount)),
            ("Secondary", secondary ? "yes" : "no"),
            ("Supplementary", noSupplementary ? "no" : "yes"),
            ("Min MAPQ", String(minMapQ)),
            ("Sample name", effectiveSampleName),
            ("Advanced options", advancedArguments.isEmpty ? "none" : AdvancedCommandLineOptions.join(advancedArguments)),
            ("Output", outputDirectory.path),
        ]))
        print("")

        let pipeline = ManagedMappingPipeline()
        let result = try await pipeline.run(request: request) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
                fflush(stdout)
            }
        }

        print("")
        print("")

        let mappingPct = result.totalReads > 0
            ? String(format: "%.2f%%", Double(result.mappedReads) / Double(result.totalReads) * 100)
            : "N/A"

        print(formatter.header("Results"))
        print("")
        print(formatter.keyValueTable([
            ("Total reads", String(result.totalReads)),
            ("Mapped reads", "\(result.mappedReads) (\(mappingPct))"),
            ("Unmapped reads", String(result.unmappedReads)),
            ("Runtime", String(format: "%.1fs", result.wallClockSeconds)),
            ("Sorted BAM", result.bamURL.path),
            ("BAI", result.baiURL.path),
        ]))
        print("")
    }

    static func resolveExecutionInputURLs(for inputURLs: [URL]) throws -> [URL] {
        try inputURLs.map { inputURL in
            guard let resolvedURL = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL) else {
                throw MapInputResolutionError.unreadableSequenceInput(inputURL.standardizedFileURL.path)
            }
            return resolvedURL.standardizedFileURL
        }
    }

    private func resolveMode(tool: MappingTool, preset: String?) throws -> MappingMode {
        switch tool {
        case .minimap2:
            let rawValue = preset ?? MappingMode.defaultShortRead.rawValue
            guard let mode = MappingMode(rawValue: rawValue), mode.isValid(for: tool) else {
                throw ValidationError("Invalid minimap2 preset '\(rawValue)'. Use sr, map-ont, map-hifi, or map-pb.")
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
