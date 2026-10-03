// MetadataGetSubcommand.swift - Display all metadata for a FASTQ bundle
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

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
              lungfish-cli metadata get SampleA.lungfishfastq
              lungfish-cli metadata get SampleA.lungfishfastq --format json
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
