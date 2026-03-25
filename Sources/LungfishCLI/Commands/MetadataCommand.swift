// MetadataCommand.swift - CLI commands for FASTQ sample metadata management
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO

/// Manage FASTQ sample metadata
struct MetadataCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "Manage FASTQ sample metadata",
        discussion: """
            View, edit, import, and export PHA4GE-aligned metadata for FASTQ
            dataset bundles (.lungfishfastq) and folders containing them.

            Per-bundle metadata is stored in `metadata.csv` inside each bundle.
            Folder-level metadata is stored in `samples.csv` at the folder root.

            Examples:
              lungfish metadata get SampleA.lungfishfastq
              lungfish metadata set SampleA.lungfishfastq --field sample_type --value "Nasopharyngeal swab"
              lungfish metadata import ./RunFolder samples.csv
              lungfish metadata export ./RunFolder
            """,
        subcommands: [
            MetadataGetSubcommand.self,
            MetadataSetSubcommand.self,
            MetadataImportSubcommand.self,
            MetadataExportSubcommand.self,
            MetadataExportBioSampleSubcommand.self,
        ],
        defaultSubcommand: MetadataGetSubcommand.self
    )
}

// MARK: - Get Subcommand

/// Display all metadata for a FASTQ bundle
struct MetadataGetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Display metadata for a FASTQ bundle",
        discussion: """
            Shows all metadata fields for a .lungfishfastq bundle, read from
            the bundle's metadata.csv file.

            Examples:
              lungfish metadata get SampleA.lungfishfastq
              lungfish metadata get SampleA.lungfishfastq --format json
            """
    )

    @Argument(help: "Path to the .lungfishfastq bundle")
    var bundlePath: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }

        // Load metadata
        guard let csvMeta = FASTQBundleCSVMetadata.load(from: bundleURL) else {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            if globalOptions.outputFormat == .text {
                print(formatter.info("No metadata found in \(bundleURL.lastPathComponent)"))
            } else if globalOptions.outputFormat == .json {
                let handler = JSONOutputHandler()
                handler.writeData(["bundle": bundlePath, "metadata": nil as String?], label: nil)
            }
            return
        }

        let sampleName = bundleURL.deletingPathExtension().lastPathComponent
        let meta = FASTQSampleMetadata(from: csvMeta, fallbackName: sampleName)

        switch globalOptions.outputFormat {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(meta)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }

        case .tsv:
            // Print header then values
            let headers = FASTQSampleMetadata.canonicalHeaders
            let values = headers.map { meta.value(forCSVHeader: $0) ?? "" }
            print(headers.joined(separator: "\t"))
            print(values.joined(separator: "\t"))

            // Custom fields
            if !meta.customFields.isEmpty {
                for (key, value) in meta.customFields.sorted(by: { $0.key < $1.key }) {
                    print("\(key)\t\(value)")
                }
            }

        case .text:
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            print(formatter.header("Sample Metadata: \(meta.sampleName)"))

            var pairs: [(String, String)] = []
            pairs.append(("Sample Name", meta.sampleName))
            pairs.append(("Sample Role", meta.sampleRole.displayLabel))

            if let v = meta.sampleType { pairs.append(("Sample Type", v)) }
            if let v = meta.collectionDate { pairs.append(("Collection Date", v)) }
            if let v = meta.geoLocName { pairs.append(("Geographic Location", v)) }
            if let v = meta.host { pairs.append(("Host", v)) }
            if let v = meta.hostDisease { pairs.append(("Host Disease", v)) }
            if let v = meta.purposeOfSequencing { pairs.append(("Purpose", v)) }
            if let v = meta.sequencingInstrument { pairs.append(("Instrument", v)) }
            if let v = meta.libraryStrategy { pairs.append(("Library Strategy", v)) }
            if let v = meta.sampleCollectedBy { pairs.append(("Collected By", v)) }
            if let v = meta.organism { pairs.append(("Organism", v)) }
            if let v = meta.patientId { pairs.append(("Patient ID", v)) }
            if let v = meta.runId { pairs.append(("Run ID", v)) }
            if let v = meta.batchId { pairs.append(("Batch ID", v)) }
            if let v = meta.platePosition { pairs.append(("Plate Position", v)) }

            print(formatter.keyValueTable(pairs))

            if !meta.customFields.isEmpty {
                print("\n" + formatter.header("Custom Fields"))
                let customPairs = meta.customFields.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
                print(formatter.keyValueTable(customPairs))
            }
        }
    }
}

// MARK: - Set Subcommand

/// Set a metadata field on a FASTQ bundle
struct MetadataSetSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a metadata field on a FASTQ bundle",
        discussion: """
            Sets or updates a single metadata field in a .lungfishfastq bundle's
            metadata.csv file. Creates the file if it doesn't exist.

            Field names use PHA4GE/NCBI BioSample conventions (snake_case).
            Common fields: sample_name, sample_type, collection_date, geo_loc_name,
            host, sample_role, patient_id, run_id, batch_id.

            Examples:
              lungfish metadata set Sample.lungfishfastq --field sample_type --value "Blood"
              lungfish metadata set Sample.lungfishfastq --field sample_role --value negative_control
              lungfish metadata set Sample.lungfishfastq --field custom_notes --value "Re-extracted"
            """
    )

    @Argument(help: "Path to the .lungfishfastq bundle")
    var bundlePath: String

    @Option(name: .long, help: "Metadata field name (e.g., sample_type, collection_date)")
    var field: String

    @Option(name: .long, help: "Value to set for the field")
    var value: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }

        // Load existing metadata or create new
        let sampleName = bundleURL.deletingPathExtension().lastPathComponent
        var meta: FASTQSampleMetadata
        if let existing = FASTQBundleCSVMetadata.load(from: bundleURL) {
            meta = FASTQSampleMetadata(from: existing, fallbackName: sampleName)
        } else {
            meta = FASTQSampleMetadata(sampleName: sampleName)
        }

        // Set the field
        meta.setValue(value, forCSVHeader: field)

        // Save back
        let legacyCSV = meta.toLegacyCSV()
        try FASTQBundleCSVMetadata.save(legacyCSV, to: bundleURL)

        if globalOptions.outputFormat == .text && !globalOptions.quiet {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            print(formatter.success("Set \(field) = \(value) on \(bundleURL.lastPathComponent)"))
        } else if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData([
                "bundle": bundlePath,
                "field": field,
                "value": value,
                "status": "ok",
            ], label: nil)
        }
    }
}

// MARK: - Import Subcommand

/// Import folder-level metadata from a CSV file
struct MetadataImportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import folder-level metadata from a CSV file",
        discussion: """
            Reads a CSV file and writes it as samples.csv into the specified folder.
            Also syncs metadata to per-bundle metadata.csv files for bundles whose
            sample_name matches a bundle directory name.

            The CSV must have a header row. The `sample_name` column is used to
            match rows to .lungfishfastq bundles in the folder.

            Examples:
              lungfish metadata import ./RunFolder samplesheet.csv
              lungfish metadata import ./RunFolder samplesheet.csv --sync-bundles
            """
    )

    @Argument(help: "Path to the folder containing .lungfishfastq bundles")
    var folderPath: String

    @Argument(help: "Path to the CSV file to import")
    var csvPath: String

    @Flag(name: .customLong("sync-bundles"), help: "Also write per-bundle metadata.csv files")
    var syncBundles: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let folderURL = URL(fileURLWithPath: folderPath)
        let csvURL = URL(fileURLWithPath: csvPath)

        guard FileManager.default.fileExists(atPath: folderPath) else {
            throw CLIError.inputFileNotFound(path: folderPath)
        }
        guard FileManager.default.fileExists(atPath: csvPath) else {
            throw CLIError.inputFileNotFound(path: csvPath)
        }

        // Parse the CSV
        let csvContent = try String(contentsOf: csvURL, encoding: .utf8)
        guard let folderMeta = FASTQFolderMetadata.parse(csv: csvContent) else {
            throw CLIError.conversionFailed(reason: "Failed to parse CSV file: \(csvPath)")
        }

        // Save
        if syncBundles {
            try FASTQFolderMetadata.saveWithPerBundleSync(folderMeta, to: folderURL)
        } else {
            try FASTQFolderMetadata.save(folderMeta, to: folderURL)
        }

        if globalOptions.outputFormat == .text && !globalOptions.quiet {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            print(formatter.success("Imported metadata for \(folderMeta.samples.count) samples to \(folderURL.lastPathComponent)/samples.csv"))
            if syncBundles {
                print(formatter.info("Per-bundle metadata.csv files synced."))
            }
        } else if globalOptions.outputFormat == .json {
            let handler = JSONOutputHandler()
            handler.writeData([
                "folder": folderPath,
                "samplesImported": "\(folderMeta.samples.count)",
                "syncedBundles": "\(syncBundles)",
                "status": "ok",
            ], label: nil)
        }
    }
}

// MARK: - Export Subcommand

/// Export folder metadata as CSV to stdout
struct MetadataExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export folder metadata as CSV to stdout",
        discussion: """
            Reads metadata from all .lungfishfastq bundles in a folder and outputs
            a combined CSV to stdout. Uses resolved metadata (per-bundle metadata.csv
            takes precedence over folder-level samples.csv).

            Examples:
              lungfish metadata export ./RunFolder
              lungfish metadata export ./RunFolder > samples.csv
              lungfish metadata export ./RunFolder --format tsv
            """
    )

    @Argument(help: "Path to the folder containing .lungfishfastq bundles")
    var folderPath: String

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let folderURL = URL(fileURLWithPath: folderPath)
        guard FileManager.default.fileExists(atPath: folderPath) else {
            throw CLIError.inputFileNotFound(path: folderPath)
        }

        // Load resolved metadata
        let resolved = FASTQFolderMetadata.loadResolved(from: folderURL)

        guard !resolved.samples.isEmpty else {
            if globalOptions.outputFormat == .text && !globalOptions.quiet {
                let formatter = TerminalFormatter(useColors: globalOptions.useColors)
                print(formatter.info("No .lungfishfastq bundles found in \(folderURL.lastPathComponent)"))
            }
            return
        }

        let orderedSamples = resolved.sampleOrder.compactMap { resolved.samples[$0] }

        switch globalOptions.outputFormat {
        case .text, .tsv:
            // Output as CSV (or TSV for tsv format)
            let separator: String = globalOptions.outputFormat == .tsv ? "\t" : ","
            let csv = serializeWithSeparator(samples: orderedSamples, separator: separator)
            print(csv, terminator: "")

        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(orderedSamples)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
        }
    }

    private func serializeWithSeparator(samples: [FASTQSampleMetadata], separator: String) -> String {
        if separator == "," {
            return FASTQSampleMetadata.serializeMultiSampleCSV(samples)
        }

        // TSV: same logic but tab-separated, no quoting needed for most fields
        guard !samples.isEmpty else { return "" }

        var orderedHeaders: [String] = []
        var headerSet: Set<String> = []

        for mapping in FASTQSampleMetadata.columnMapping {
            let header = mapping.csvHeaders[0]
            for sample in samples {
                if let val = sample.value(forCSVHeader: header), !val.isEmpty {
                    if headerSet.insert(header).inserted {
                        orderedHeaders.append(header)
                    }
                    break
                }
            }
        }

        var allCustomKeys: Set<String> = []
        for sample in samples {
            allCustomKeys.formUnion(sample.customFields.keys)
        }
        for key in allCustomKeys.sorted() {
            if headerSet.insert(key).inserted {
                orderedHeaders.append(key)
            }
        }

        var lines: [String] = []
        lines.append(orderedHeaders.joined(separator: "\t"))

        for sample in samples {
            let values = orderedHeaders.map { header -> String in
                sample.value(forCSVHeader: header) ?? ""
            }
            lines.append(values.joined(separator: "\t"))
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Export BioSample Subcommand

/// Export folder metadata as NCBI BioSample TSV
struct MetadataExportBioSampleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-biosample",
        abstract: "Export folder metadata as NCBI BioSample submission TSV",
        discussion: """
            Reads metadata from all .lungfishfastq bundles in a folder and outputs
            an NCBI BioSample-compatible TSV file. This format can be submitted
            directly to NCBI's BioSample submission portal.

            Examples:
              lungfish metadata export-biosample ./RunFolder
              lungfish metadata export-biosample ./RunFolder > biosample.tsv
              lungfish metadata export-biosample ./RunFolder --package environmental
            """
    )

    @Argument(help: "Path to the folder containing .lungfishfastq bundles")
    var folderPath: String

    @Option(name: .long, help: "BioSample package: clinical (default) or environmental")
    var package: String = "clinical"

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let folderURL = URL(fileURLWithPath: folderPath)
        guard FileManager.default.fileExists(atPath: folderPath) else {
            throw CLIError.inputFileNotFound(path: folderPath)
        }

        let resolved = FASTQFolderMetadata.loadResolved(from: folderURL)
        guard !resolved.samples.isEmpty else {
            if !globalOptions.quiet {
                let formatter = TerminalFormatter(useColors: globalOptions.useColors)
                print(formatter.info("No .lungfishfastq bundles found in \(folderURL.lastPathComponent)"))
            }
            return
        }

        let orderedSamples = resolved.sampleOrder.compactMap { resolved.samples[$0] }

        let bioPackage: NCBIBioSampleExporter.BioSamplePackage
        switch package.lowercased() {
        case "environmental", "env":
            bioPackage = .pathogenEnvironmental
        default:
            bioPackage = .pathogenClinical
        }

        let tsv = NCBIBioSampleExporter.export(samples: orderedSamples, package: bioPackage)
        print(tsv, terminator: "")
    }
}
