// MetadataExportSubcommand.swift - Export folder metadata as CSV to stdout
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

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
              lungfish-cli metadata export ./RunFolder
              lungfish-cli metadata export ./RunFolder > samples.csv
              lungfish-cli metadata export ./RunFolder --format tsv
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
