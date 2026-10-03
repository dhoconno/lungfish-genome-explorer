// ENAReadsSubcommand.swift - Get read data with FASTQ URLs from ENA
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Get read data with FASTQ URLs from ENA
struct ENAReadsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reads",
        abstract: "Get read/SRA data with FASTQ download URLs"
    )

    @Argument(help: "Run accession or study ID (e.g., SRR11140748, PRJNA123456)")
    var accession: String

    @Option(
        name: .customLong("limit"),
        help: "Maximum results (default: 20)"
    )
    var limit: Int = 20

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Fetching read info for \(accession) from ENA..."))
        }

        let service = ENAService()

        do {
            let records = try await service.searchReads(term: accession, limit: limit)

            if globalOptions.outputFormat == .json {
                let jsonResults = ENAReadsJSONResult(
                    accession: accession,
                    records: records.map { record in
                        ENAReadJSON(
                            runAccession: record.runAccession,
                            studyAccession: record.studyAccession,
                            platform: record.instrumentPlatform,
                            libraryStrategy: record.libraryStrategy,
                            libraryLayout: record.libraryLayout,
                            readCount: record.readCount,
                            fileSize: record.formattedFileSize,
                            fastqURLs: record.fastqHTTPURLs.map { $0.absoluteString }
                        )
                    }
                )
                let handler = JSONOutputHandler()
                handler.writeData(jsonResults, label: nil)
            } else {
                print(formatter.header("ENA Read Data"))

                if records.isEmpty {
                    print(formatter.warning("No read data found for \(accession)"))
                } else {
                    print("Found \(records.count) run(s)\n")

                    for record in records {
                        print(formatter.keyValueTable([
                            ("Run", record.runAccession),
                            ("Study", record.studyAccession ?? "Unknown"),
                            ("Platform", record.instrumentPlatform ?? "Unknown"),
                            ("Strategy", record.libraryStrategy ?? "Unknown"),
                            ("Layout", record.libraryLayout ?? "Unknown"),
                            ("Reads", record.readCount != nil ? "\(record.readCount!)" : "Unknown"),
                            ("File Size", record.formattedFileSize ?? "Unknown"),
                        ]))

                        let urls = record.fastqHTTPURLs
                        if !urls.isEmpty {
                            print("\n  FASTQ URLs:")
                            for url in urls {
                                print("    \(url.absoluteString)")
                            }
                        }
                        print("")
                    }
                }
            }
        } catch {
            throw CLIError.networkError(reason: "ENA read fetch failed: \(error.localizedDescription)")
        }
    }
}
