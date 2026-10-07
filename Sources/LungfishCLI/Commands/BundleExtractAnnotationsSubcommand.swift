// BundleExtractAnnotationsSubcommand.swift - Extract annotation feature sequences into a new .lungfishref bundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Extract Annotation Sequences Subcommand

struct BundleExtractAnnotationsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract-annotations",
        abstract: "Extract annotation feature sequences into a new .lungfishref bundle"
    )

    @Option(name: .customLong("bundle"), help: "Source .lungfishref bundle containing sequence and annotations")
    var bundlePath: String

    @Option(name: .customLong("track"), help: "Annotation track id or name to extract from")
    var trackID: String

    @Option(name: .customLong("output-bundle"), help: "Output .lungfishref bundle path")
    var outputBundlePath: String

    @Option(name: .customLong("feature-type"), help: "Feature type to extract (default: gene)")
    var featureType: String = "gene"

    @Option(name: .customLong("name-prefix"), help: "Only extract features whose name or gene name starts with this prefix")
    var namePrefix: String?

    @Flag(name: .customLong("replace"), help: "Replace an existing output bundle")
    var replace: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let sourceBundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        let typedOutputURL = URL(fileURLWithPath: outputBundlePath).standardizedFileURL
        let outputDirectory = typedOutputURL.deletingLastPathComponent()
        let outputName = typedOutputURL.deletingPathExtension().lastPathComponent
        // The bundle the build writes, the only path `--replace` may replace.
        let outputBundleURL = OutputReplacementCheck.publishedReferenceBundleURL(
            outputDirectory: outputDirectory,
            name: outputName
        )

        // Every refusal runs before the earlier output is touched.
        do {
            try OutputReplacementCheck.refuseInputs([sourceBundleURL], inside: outputBundleURL)
        } catch {
            print(formatter.error(error.localizedDescription))
            throw CLIExitCode.outputError.exitCode
        }
        if FileManager.default.fileExists(atPath: outputBundleURL.path), !replace {
            print(formatter.error("Output bundle already exists: \(outputBundleURL.path)"))
            throw CLIExitCode.outputError.exitCode
        }

        let referenceBundle = try await ReferenceBundle(url: sourceBundleURL)
        let manifest = referenceBundle.manifest
        guard let track = manifest.annotations.first(where: { $0.id == trackID || $0.name == trackID }) else {
            print(formatter.error("Annotation track not found: \(trackID)"))
            throw CLIExitCode.inputError.exitCode
        }

        let databasePath = track.databasePath ?? track.path
        let database = try AnnotationDatabase(url: sourceBundleURL.appendingPathComponent(databasePath))
        let prefix = namePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = database.allChromosomes()
            .flatMap { database.queryByRegion(chromosome: $0, start: 0, end: Int.max, limit: Int.max) }
            .filter { $0.type == featureType }
            .filter { record in
                guard let prefix, !prefix.isEmpty else { return true }
                return record.name.hasPrefix(prefix) || (record.geneName?.hasPrefix(prefix) ?? false)
            }

        guard !records.isEmpty else {
            print(formatter.error("No \(featureType) features matched the requested filters."))
            throw CLIExitCode.inputError.exitCode
        }

        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "lungfish-cli-annotation-sequences-",
            contextURL: outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fastaURL = tempDirectory.appendingPathComponent("annotation-sequences.fa")
        try await writeAnnotationFASTA(records: records, bundle: referenceBundle, to: fastaURL)

        let sourceInfo = SourceInfo(
            organism: manifest.source.organism,
            assembly: outputName,
            database: "Annotation feature sequences",
            sourceURL: sourceBundleURL,
            downloadDate: Date(),
            notes: "Extracted \(featureType) sequences from \(manifest.name) track \(track.name)"
        )
        let configuration = BuildConfiguration(
            name: outputName,
            identifier: "org.lungfish.cli.annotation-sequences.\(UUID().uuidString.lowercased())",
            fastaURL: fastaURL,
            annotationFiles: [],
            outputDirectory: outputDirectory,
            source: sourceInfo,
            compressFASTA: true,
            provenanceWorkflowName: "lungfish bundle extract-annotations",
            provenanceCommand: provenanceCommand(),
            provenanceInputFiles: provenanceInputURLs(
                sourceBundleURL: sourceBundleURL,
                manifest: manifest,
                track: track
            )
        )
        // `--replace` moves the earlier bundle aside and deletes it only once
        // the new one is built, so a failed build leaves it in place.
        let earlierOutput = replace ? try SetAsideOutput.setAside(outputBundleURL) : nil
        let createdURL: URL
        do {
            createdURL = try await NativeBundleBuilder().build(configuration: configuration)
        } catch {
            if let earlierOutput {
                do {
                    try earlierOutput.restore()
                } catch let restoreError {
                    print(formatter.error(
                        "The earlier bundle could not be moved back (\(restoreError.localizedDescription)) and is kept at \(earlierOutput.asideURL.path)."
                    ))
                }
            }
            throw error
        }
        earlierOutput?.discard()

        print(formatter.header("Annotation Sequence Extraction"))
        print("")
        print(formatter.keyValueTable([
            ("Source bundle", sourceBundleURL.lastPathComponent),
            ("Source track", track.name),
            ("Feature type", featureType),
            ("Extracted features", String(records.count)),
            ("Output bundle", createdURL.path),
        ]))
    }

    private func provenanceCommand() -> [String] {
        var command = [
            CLICommandIdentity.executableName,
            "bundle",
            "extract-annotations",
            "--bundle", bundlePath,
            "--track", trackID,
            "--output-bundle", outputBundlePath,
            "--feature-type", featureType,
        ]
        if let namePrefix {
            command.append(contentsOf: ["--name-prefix", namePrefix])
        }
        if replace {
            command.append("--replace")
        }
        return command
    }

    private func provenanceInputURLs(
        sourceBundleURL: URL,
        manifest: BundleManifest,
        track: AnnotationTrackInfo
    ) -> [URL] {
        var urls = [sourceBundleURL.appendingPathComponent("manifest.json")]

        if let genome = manifest.genome {
            urls.append(sourceBundleURL.appendingPathComponent(genome.path))
            urls.append(sourceBundleURL.appendingPathComponent(genome.indexPath))
            if let gzipIndexPath = genome.gzipIndexPath {
                urls.append(sourceBundleURL.appendingPathComponent(gzipIndexPath))
            }
        }

        let databasePath = track.databasePath ?? track.path
        urls.append(sourceBundleURL.appendingPathComponent(databasePath))
        if track.path != databasePath {
            urls.append(sourceBundleURL.appendingPathComponent(track.path))
        }

        return urls
    }

    private func writeAnnotationFASTA(records: [AnnotationDatabaseRecord], bundle: ReferenceBundle, to url: URL) async throws {
        var output = ""
        for record in records {
            let region = GenomicRegion(chromosome: record.chromosome, start: record.start, end: record.end)
            var sequence = try await bundle.fetchSequence(region: region)
            if record.strand == "-" {
                sequence = reverseComplement(sequence)
            }
            let name = record.geneName ?? record.name
            output += ">\(name) source=\(record.chromosome):\(record.start + 1)-\(record.end) strand=\(record.strand)\n"
            output += wrap(sequence, width: 70)
            output += "\n"
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    private func wrap(_ sequence: String, width: Int) -> String {
        guard width > 0 else { return sequence }
        var lines: [String] = []
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: width, limitedBy: sequence.endIndex) ?? sequence.endIndex
            lines.append(String(sequence[index..<end]))
            index = end
        }
        return lines.joined(separator: "\n")
    }

    private func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T", "U": return "A"
            case "a": return "t"
            case "c": return "g"
            case "g": return "c"
            case "t", "u": return "a"
            default: return "N"
            }
        })
    }
}
