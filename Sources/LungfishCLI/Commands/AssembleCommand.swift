// AssembleCommand.swift - CLI command for managed de novo assembly
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct AssembleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assemble",
        abstract: "Run de novo genome assembly with the managed assembly pack",
        discussion: """
            Assemble FASTQ reads with a managed assembler from the Genome Assembly pack.
            The CLI uses the same tool/read-type compatibility model as the app.
            """
    )

    @Argument(help: "Input FASTQ file(s). Provide two files with --paired for paired-end Illumina reads.")
    var fastqFiles: [String]

    @Option(name: .customLong("assembler"), help: "Assembler to run: spades, megahit, skesa, flye, hifiasm")
    var assembler: String = "spades"

    @Option(name: .customLong("read-type"), help: "Read class: illumina-short-reads, ont-reads, pacbio-hifi")
    var readType: String?

    @Option(name: [.customLong("output"), .customLong("output-dir"), .customShort("o")], help: "Output directory")
    var outputDir: String?

    @Option(name: [.customLong("project-name"), .customLong("name")], help: "Project name for the assembly")
    var projectName: String?

    @Flag(name: .customLong("paired"), help: "Treat the two input FASTQ files as paired-end mates")
    var pairedEnd: Bool = false

    @Option(name: [.customLong("memory-gb"), .customLong("memory")], help: "Memory budget in GB when the selected assembler supports it")
    var memoryGB: Int?

    @Option(name: .customLong("min-contig-length"), help: "Minimum contig length when the selected assembler supports it")
    var minContigLength: Int?

    @Option(name: .customLong("profile"), help: "Curated assembler profile, such as meta-sensitive or nano-hq")
    var profile: String?

    @Option(name: .customLong("extra-arg"), parsing: .unconditionalSingleValue, help: "Additional assembler argument (repeatable)")
    var extraArg: [String] = []

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        guard let tool = AssemblyTool(rawValue: assembler.lowercased()) else {
            print(formatter.error("Unknown assembler: \(assembler)"))
            throw ExitCode.failure
        }

        let inputURLs = fastqFiles.map { URL(fileURLWithPath: $0) }
        for inputURL in inputURLs where !FileManager.default.fileExists(atPath: inputURL.path) {
            print(formatter.error("Input file not found: \(inputURL.path)"))
            throw ExitCode.failure
        }

        if pairedEnd && inputURLs.count != 2 {
            print(formatter.error("Paired-end assembly requires exactly two FASTQ inputs."))
            throw ExitCode.failure
        }

        let readType = try resolveReadType(for: tool, inputURLs: inputURLs, formatter: formatter)
        guard AssemblyCompatibility.isSupported(tool: tool, for: readType) else {
            print(formatter.error("\(tool.displayName) is not available for \(readType.displayName) in v1."))
            throw ExitCode.failure
        }

        let projectName = resolvedProjectName(from: inputURLs)
        let outputDirectory = resolvedOutputDirectory(projectName: projectName)
        let request = AssemblyRunRequest(
            tool: tool,
            readType: readType,
            inputURLs: inputURLs,
            projectName: projectName,
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: globalOptions.effectiveThreads,
            memoryGB: memoryGB,
            minContigLength: minContigLength,
            selectedProfileID: profile,
            extraArguments: extraArg
        )

        print(formatter.header("Managed Assembly"))
        print("")
        print(formatter.keyValueTable([
            ("Assembler", tool.displayName),
            ("Read type", readType.displayName),
            ("Inputs", inputURLs.map(\.lastPathComponent).joined(separator: ", ")),
            ("Paired-end", pairedEnd ? "yes" : "no"),
            ("Threads", "\(request.threads)"),
            ("Memory", memoryGB.map { "\($0) GB" } ?? "default"),
            ("Profile", profile ?? "default"),
            ("Output", outputDirectory.path),
        ]))
        print("")

        let result = try await ManagedAssemblyPipeline().run(request: request) { _, message in
            if !globalOptions.quiet {
                print("\r\(formatter.info(message))", terminator: "")
            }
        }

        if !globalOptions.quiet {
            print("")
            print("")
        }

        let stats = result.statistics
        print(formatter.header("Assembly Results"))
        print("")
        print(formatter.keyValueTable([
            ("Contigs", "\(stats.contigCount)"),
            ("Total length", "\(stats.totalLengthBP) bp"),
            ("N50", "\(stats.n50) bp"),
            ("Largest contig", "\(stats.largestContigBP) bp"),
            ("GC content", String(format: "%.1f%%", stats.gcPercent)),
        ]))
        print("")
        print("Contigs: \(formatter.path(result.contigsPath.path))")
        if let graphPath = result.graphPath {
            print("Graph:   \(formatter.path(graphPath.path))")
        }
        if let logPath = result.logPath {
            print("Log:     \(formatter.path(logPath.path))")
        }
        print("")
        print(formatter.success("Assembly completed in \(String(format: "%.1f", result.wallTimeSeconds))s"))
    }

    private func resolveReadType(
        for tool: AssemblyTool,
        inputURLs: [URL],
        formatter: TerminalFormatter
    ) throws -> AssemblyReadType {
        if let readType {
            guard let parsedReadType = AssemblyReadType(cliArgument: readType) else {
                print(formatter.error("Unknown read type: \(readType)"))
                throw ExitCode.failure
            }
            return parsedReadType
        }

        let detectedReadTypes = inputURLs.compactMap(AssemblyReadType.detect(fromFASTQ:))
        let evaluation = AssemblyCompatibility.evaluate(detectedReadTypes: detectedReadTypes)
        let hasKnownAndUnknownMix = !detectedReadTypes.isEmpty && detectedReadTypes.count < inputURLs.count

        if let blockingMessage = evaluation.blockingMessage {
            print(formatter.error(blockingMessage))
            throw ExitCode.failure
        }

        if hasKnownAndUnknownMix {
            print(formatter.error("Selected FASTQ inputs mix detected and unclassified read classes. Select one read class per run."))
            throw ExitCode.failure
        }

        if let resolvedReadType = evaluation.resolvedReadType {
            return resolvedReadType
        }

        switch tool {
        case .spades, .megahit, .skesa:
            return .illuminaShortReads
        case .flye:
            return .ontReads
        case .hifiasm:
            return .pacBioHiFi
        }
    }

    private func resolvedProjectName(from inputURLs: [URL]) -> String {
        if let projectName, !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return projectName
        }

        guard let firstURL = inputURLs.first else {
            return "assembly"
        }

        var detectURL = firstURL
        if detectURL.pathExtension.lowercased() == "gz" {
            detectURL = detectURL.deletingPathExtension()
        }

        return detectURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_R1", with: "")
            .replacingOccurrences(of: "_R2", with: "")
            .replacingOccurrences(of: "_1", with: "")
            .replacingOccurrences(of: "_2", with: "")
    }

    private func resolvedOutputDirectory(projectName: String) -> URL {
        if let outputDir {
            return URL(fileURLWithPath: outputDir)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assembly-\(projectName)")
    }
}
