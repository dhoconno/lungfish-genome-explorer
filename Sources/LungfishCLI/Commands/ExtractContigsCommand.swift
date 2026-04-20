// ExtractContigsCommand.swift - Extract selected assembly contigs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct ExtractContigsSubcommand: AsyncParsableCommand {
    enum SelectionInput: Equatable {
        case contig(String)
        case contigFile(String)
    }

    static let configuration = CommandConfiguration(
        commandName: "contigs",
        abstract: "Extract selected contigs from an assembly FASTA or managed assembly result"
    )

    @Option(name: .customLong("assembly"), help: "Managed assembly output directory containing assembly-result.json")
    var assemblyPath: String?

    @Option(name: .customLong("contigs"), help: "Contigs FASTA path")
    var contigsPath: String?

    @Option(name: .customLong("contig"), parsing: .upToNextOption, help: "Contig name to extract (repeatable)")
    var contigs: [String] = []

    @Option(name: .customLong("contig-file"), help: "Text file with one contig name per line (repeatable)")
    var contigFiles: [String] = []

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output FASTA path")
    var output: String?

    @Flag(name: .customLong("bundle"), help: "Create a derived .lungfishref bundle in the project")
    var bundle: Bool = false

    @Option(name: .customLong("bundle-name"), help: "Bundle display name for --bundle mode")
    var bundleName: String?

    @Option(name: .customLong("project-root"), help: "Project root directory for --bundle mode")
    var projectRoot: String?

    @Option(name: .customLong("line-width"), help: "FASTA line width (default: 60)")
    var lineWidth: Int = 60

    @OptionGroup var globalOptions: GlobalOptions

    var rawSelectionArguments: [String]?

    func validate() throws {
        let sourceCount = [assemblyPath, contigsPath].compactMap { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError("Specify exactly one of --assembly or --contigs")
        }

        guard lineWidth >= 0 else {
            throw ValidationError("--line-width must be >= 0")
        }

        let selectedContigs = try requestedContigs()
        guard !selectedContigs.isEmpty else {
            throw ValidationError("Specify at least one --contig or provide --contig-file")
        }

        if bundle {
            guard projectRoot != nil else {
                throw ValidationError("--project-root is required with --bundle")
            }
        }
    }

    func run() async throws {
        let source = try await loadSource()
        let selectedContigs = try requestedContigs()
        _ = try await source.catalog.selectionSummary(for: selectedContigs)

        if bundle {
            let projectRootURL = URL(fileURLWithPath: projectRoot ?? "")
            let bundleURL = try await buildBundle(
                source: source,
                selectedContigs: selectedContigs,
                projectRootURL: projectRootURL
            )
            FileHandle.standardOutput.write(Data("\(bundleURL.path)\n".utf8))
            if !globalOptions.quiet {
                let formatter = TerminalFormatter(useColors: globalOptions.useColors)
                FileHandle.standardError.write(
                    Data("\(formatter.success("Created bundle \(bundleURL.lastPathComponent)"))\n".utf8)
                )
            }
            return
        }

        let fasta = try await selectedContigsFASTA(selectedContigs, from: source.catalog)
        if let output {
            let outputURL = URL(fileURLWithPath: output)
            try fasta.write(to: outputURL, atomically: true, encoding: .utf8)
        } else {
            FileHandle.standardOutput.write(Data(fasta.utf8))
        }
    }

    private func requestedContigs() throws -> [String] {
        let selectionInputs = resolvedSelectionInputs()
        if !selectionInputs.isEmpty {
            return try materializeContigs(from: selectionInputs)
        }

        return try materializeContigs(
            from: contigs.map(SelectionInput.contig) + contigFiles.map(SelectionInput.contigFile)
        )
    }

    private func resolvedSelectionInputs() -> [SelectionInput] {
        let rawArguments = rawSelectionArguments ?? ProcessInfo.processInfo.arguments
        return Self.selectionInputs(from: rawArguments)
    }

    private func materializeContigs(from selectionInputs: [SelectionInput]) throws -> [String] {
        var requested: [String] = []

        for selectionInput in selectionInputs {
            switch selectionInput {
            case .contig(let contig):
                let trimmed = contig.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    requested.append(trimmed)
                }
            case .contigFile(let contigFile):
                let fileURL = URL(fileURLWithPath: contigFile)
                let fileContents = try String(contentsOf: fileURL, encoding: .utf8)
                requested.append(
                    contentsOf: fileContents
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            }
        }

        return requested
    }

    static func selectionInputs(from rawArguments: [String]) -> [SelectionInput] {
        let relevantArguments = relevantSelectionArguments(from: rawArguments)
        let contigPrefix = "--contig="
        let contigFilePrefix = "--contig-file="
        var selectionInputs: [SelectionInput] = []
        var index = relevantArguments.startIndex

        while index < relevantArguments.endIndex {
            let argument = relevantArguments[index]

            if argument == "--contig" {
                let valueIndex = relevantArguments.index(after: index)
                if valueIndex < relevantArguments.endIndex {
                    selectionInputs.append(.contig(relevantArguments[valueIndex]))
                    index = relevantArguments.index(after: valueIndex)
                    continue
                }
            } else if argument.hasPrefix(contigPrefix) {
                selectionInputs.append(.contig(String(argument.dropFirst(contigPrefix.count))))
            } else if argument == "--contig-file" {
                let valueIndex = relevantArguments.index(after: index)
                if valueIndex < relevantArguments.endIndex {
                    selectionInputs.append(.contigFile(relevantArguments[valueIndex]))
                    index = relevantArguments.index(after: valueIndex)
                    continue
                }
            } else if argument.hasPrefix(contigFilePrefix) {
                selectionInputs.append(.contigFile(String(argument.dropFirst(contigFilePrefix.count))))
            }

            index = relevantArguments.index(after: index)
        }

        return selectionInputs
    }

    private static func relevantSelectionArguments(from rawArguments: [String]) -> ArraySlice<String> {
        guard !rawArguments.isEmpty else {
            return []
        }

        if let contigsIndex = rawArguments.lastIndex(of: "contigs"),
           contigsIndex < rawArguments.index(before: rawArguments.endIndex) {
            return rawArguments[rawArguments.index(after: contigsIndex)...]
        }

        if let extractIndex = rawArguments.lastIndex(of: "extract"),
           extractIndex < rawArguments.index(before: rawArguments.endIndex) {
            return rawArguments[rawArguments.index(after: extractIndex)...]
        }

        return ArraySlice(rawArguments)
    }

    private func writeSelectedContigs(
        _ selectedContigs: [String],
        from catalog: AssemblyContigCatalog,
        to outputURL: URL
    ) async throws {
        let fasta = try await selectedContigsFASTA(selectedContigs, from: catalog)
        try fasta.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func selectedContigsFASTA(
        _ selectedContigs: [String],
        from catalog: AssemblyContigCatalog
    ) async throws -> String {
        let fastas = try await catalog.sequenceFASTAs(for: selectedContigs, lineWidth: lineWidth)
        return fastas.joined()
    }

    private func buildBundle(
        source: SourceAssembly,
        selectedContigs: [String],
        projectRootURL: URL
    ) async throws -> URL {
        let refsDirectory = try ReferenceSequenceFolder.ensureFolder(in: projectRootURL)
        let tempDirectory = try ProjectTempDirectory.create(prefix: "extract-contigs-", in: projectRootURL)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let subsetFASTAURL = tempDirectory.appendingPathComponent("subset.fa")
        try await writeSelectedContigs(selectedContigs, from: source.catalog, to: subsetFASTAURL)

        let summary = try await source.catalog.selectionSummary(for: selectedContigs)
        let baseName = resolvedBundleName(from: source)
        let finalBundleName = makeUniqueBundleName(base: baseName, in: refsDirectory)
        let assembler = source.result.map(assemblerDisplayName(for:)) ?? "Unknown"
        let metadata = AssemblySubsetBundleMetadata.makeGroups(
            assembler: assembler,
            sourceAssemblyName: source.sourceName,
            selectedContigs: selectedContigs,
            selectionSummary: summary
        )

        let configuration = BuildConfiguration(
            name: finalBundleName,
            identifier: "org.lungfish.cli.extract-contigs.\(UUID().uuidString.lowercased())",
            fastaURL: subsetFASTAURL,
            outputDirectory: refsDirectory,
            source: SourceInfo(
                organism: finalBundleName,
                assembly: finalBundleName,
                database: "Derived Contig Subset",
                sourceURL: source.sourceURL,
                downloadDate: Date(),
                notes: "Derived from \(source.sourceName)"
            ),
            compressFASTA: true,
            metadata: metadata
        )

        return try await ReferenceBundleBuilder().build(configuration: configuration)
    }

    private func resolvedBundleName(from source: SourceAssembly) -> String {
        if let bundleName {
            let trimmed = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "\(source.sourceName)-subset"
    }

    private func makeUniqueBundleName(base: String, in directory: URL) -> String {
        let fm = FileManager.default
        var candidate = base
        var index = 2

        while fm.fileExists(atPath: bundleURL(for: candidate, in: directory).path) {
            candidate = "\(base) \(index)"
            index += 1
        }

        return candidate
    }

    private func bundleURL(for bundleName: String, in directory: URL) -> URL {
        let safeName = bundleName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent("\(safeName).lungfishref", isDirectory: true)
    }

    private func assemblerDisplayName(for result: AssemblyResult) -> String {
        if let version = result.assemblerVersion, !version.isEmpty {
            return "\(result.tool.displayName) \(version)"
        }
        return result.tool.displayName
    }

    private func loadSource() async throws -> SourceAssembly {
        if let assemblyPath {
            let assemblyURL = URL(fileURLWithPath: assemblyPath)
            let result = try AssemblyResult.load(from: assemblyURL)
            let catalog = try await AssemblyContigCatalog(result: result)
            return SourceAssembly(
                result: result,
                catalog: catalog,
                sourceURL: assemblyURL,
                sourceName: assemblyURL.lastPathComponent
            )
        }

        let contigsURL = URL(fileURLWithPath: contigsPath ?? "")
        if !FileManager.default.fileExists(atPath: contigsURL.appendingPathExtension("fai").path) {
            try FASTAIndexBuilder.buildAndWrite(for: contigsURL)
        }
        let statistics = try AssemblyStatisticsCalculator.compute(from: contigsURL)
        let result = AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: nil,
            commandLine: "extract contigs",
            outputDirectory: contigsURL.deletingLastPathComponent(),
            statistics: statistics,
            wallTimeSeconds: 0
        )
        let catalog = try await AssemblyContigCatalog(result: result)
        return SourceAssembly(
            result: nil,
            catalog: catalog,
            sourceURL: contigsURL,
            sourceName: contigsURL.deletingPathExtension().lastPathComponent
        )
    }
}

private struct SourceAssembly {
    let result: AssemblyResult?
    let catalog: AssemblyContigCatalog
    let sourceURL: URL
    let sourceName: String
}
