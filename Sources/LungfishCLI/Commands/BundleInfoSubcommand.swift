// BundleInfoSubcommand.swift - Display bundle information
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Info Subcommand

/// Display bundle information
struct BundleInfoSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Display bundle information",
        discussion: """
            Shows detailed information about a reference bundle including:
            - Name, identifier, and description
            - Source organism and assembly
            - Genome size and chromosome count
            - Annotation, variant, and signal tracks

            Examples:
              lungfish-cli bundle info MyGenome.lungfishref
              lungfish-cli bundle info MyGenome.lungfishref --format json
            """
    )

    @Argument(help: "Path to the .lungfishref bundle")
    var bundlePath: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Validate path
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }

        // Load manifest
        let manifest: BundleManifest
        do {
            manifest = try BundleManifest.load(from: bundleURL)
        } catch {
            throw CLIError.conversionFailed(reason: "Failed to load bundle manifest: \(error.localizedDescription)")
        }

        // Output based on format
        switch globalOptions.outputFormat {
        case .json:
            let handler = JSONOutputHandler()
            handler.writeData(BundleInfoOutput(manifest: manifest, path: bundlePath), label: nil)

        case .tsv:
            print("name\tidentifier\torganism\tassembly\ttotal_length\tchromosomes\tannotations\tvariants\ttracks")
            print("\(manifest.name)\t\(manifest.identifier)\t\(manifest.source.organism)\t\(manifest.source.assembly)\t\(manifest.genome?.totalLength ?? 0)\t\(manifest.genome?.chromosomes.count ?? 0)\t\(manifest.annotations.count)\t\(manifest.variants.count)\t\(manifest.tracks.count)")

        case .text:
            print(formatter.header("Bundle Information"))
            print(formatter.keyValueTable([
                ("Name", manifest.name),
                ("Identifier", manifest.identifier),
                ("Description", manifest.description ?? "(none)"),
                ("Format Version", manifest.formatVersion),
                ("Created", manifest.createdDate.formatted()),
            ]))

            print("\n" + formatter.header("Source"))
            print(formatter.keyValueTable([
                ("Organism", manifest.source.organism),
                ("Common Name", manifest.source.commonName ?? "(none)"),
                ("Assembly", manifest.source.assembly),
                ("Database", manifest.source.database ?? "(none)"),
                ("Source URL", manifest.source.sourceURL?.absoluteString ?? "(none)"),
            ]))

            print("\n" + formatter.header("Genome"))
            if let genome = manifest.genome {
                print(formatter.keyValueTable([
                    ("Total Length", "\(formatter.number(Int(genome.totalLength))) bp"),
                    ("Chromosomes", formatter.number(genome.chromosomes.count)),
                    ("Sequence File", genome.path),
                    ("Index File", genome.indexPath),
                ]))
            } else {
                print("  (variant-only bundle — no reference genome)")
            }

            if let chromosomes = manifest.genome?.chromosomes, !chromosomes.isEmpty {
                print("\n" + formatter.header("Chromosomes"))
                let chromHeaders = ["Name", "Length (bp)", "Primary", "Mitochondrial"]
                let chromRows = chromosomes.map { chrom -> [String] in
                    [
                        chrom.name,
                        formatter.number(Int(chrom.length)),
                        chrom.isPrimary ? "Yes" : "No",
                        chrom.isMitochondrial ? "Yes" : "No"
                    ]
                }
                print(formatter.table(headers: chromHeaders, rows: chromRows))
            }

            if !manifest.alignments.isEmpty {
                print("\n" + formatter.header("Alignment Tracks"))
                print(formatter.table(
                    headers: BundleAlignmentTrackListing.tableHeaders,
                    rows: BundleAlignmentTrackListing.tableRows(manifest.alignments, formatter: formatter)
                ))
            }

            if !manifest.annotations.isEmpty {
                print("\n" + formatter.header("Annotation Tracks"))
                let annoHeaders = ["ID", "Name", "Type", "Features", "Path"]
                let annoRows = manifest.annotations.map { track -> [String] in
                    [
                        track.id,
                        track.name,
                        track.annotationType.rawValue,
                        track.featureCount.map { formatter.number($0) } ?? "-",
                        track.path
                    ]
                }
                print(formatter.table(headers: annoHeaders, rows: annoRows))
            }

            if !manifest.variants.isEmpty {
                print("\n" + formatter.header("Variant Tracks"))
                let varHeaders = ["ID", "Name", "Type", "Variants", "Path"]
                let varRows = manifest.variants.map { track -> [String] in
                    [
                        track.id,
                        track.name,
                        track.variantType.rawValue,
                        track.variantCount.map { formatter.number($0) } ?? "-",
                        track.path
                    ]
                }
                print(formatter.table(headers: varHeaders, rows: varRows))
            }

            if !manifest.tracks.isEmpty {
                print("\n" + formatter.header("Signal Tracks"))
                let sigHeaders = ["ID", "Name", "Type", "Path"]
                let sigRows = manifest.tracks.map { track -> [String] in
                    [
                        track.id,
                        track.name,
                        track.signalType.rawValue,
                        track.path
                    ]
                }
                print(formatter.table(headers: sigHeaders, rows: sigRows))
            }
        }
    }
}
