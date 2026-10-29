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
            // The manifest of a bundle made before the read counts were fixed holds the idxstats sums, so print the
            // same reads the text form prints, and say beside the manifest what each count counts.
            let shown = manifest.alignments.isEmpty
                ? manifest
                : manifest.displayingAlignments(BundleAlignmentTrackListing.withReads(manifest.alignments, in: bundleURL))
            handler.writeData(
                BundleInfoJSON(
                    output: BundleInfoOutput(manifest: shown, path: bundlePath),
                    alignmentCountBases: BundleAlignmentTrackListing.countBases(manifest.alignments, in: bundleURL)
                ),
                label: nil
            )

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
                    rows: BundleAlignmentTrackListing.tableRows(manifest.alignments, bundleURL: bundleURL, formatter: formatter)
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

/// What `bundle info --format json` prints. The `manifest` and `path` keys are `BundleInfoOutput`'s, unchanged. The
/// `mapped_read_count_basis` key sits beside them, keyed by track id, and says what each track's `mapped_read_count` counts.
/// `reads` is flagstat's primary lines, `alignments` is a database without them, and `manifest` is the manifest's own copy,
/// whose unit the manifest does not record. A bundle with no alignment track prints no such key.
struct BundleInfoJSON: Encodable {
    let output: BundleInfoOutput
    let alignmentCountBases: [String: String]

    private enum CodingKeys: String, CodingKey {
        case manifest
        case path
        case alignmentCountBases = "mapped_read_count_basis"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(output.manifest, forKey: .manifest)
        try container.encode(output.path, forKey: .path)
        if !alignmentCountBases.isEmpty {
            try container.encode(alignmentCountBases, forKey: .alignmentCountBases)
        }
    }
}
