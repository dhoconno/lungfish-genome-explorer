// MarkdupCommand.swift - CLI command for running samtools markdup on BAM files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO

struct MarkdupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markdup",
        abstract: "Mark PCR duplicates in BAM files using samtools markdup"
    )

    @Argument(help: "Path to a BAM file or a directory containing BAMs")
    var path: String

    @Flag(name: .long, help: "Re-run markdup even if already marked")
    var force: Bool = false

    @Option(name: .customLong("sort-threads"), help: "Threads for samtools sort (default 4)")
    var sortThreads: Int = 4

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let inputURL = URL(fileURLWithPath: path)
        let fm = FileManager.default

        guard let samtoolsPath = locateSamtools() else {
            throw ValidationError("samtools binary not found")
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
            throw ValidationError("Path does not exist: \(inputURL.path)")
        }

        if isDir.boolValue {
            // If this is a NAO-MGS result directory, materialize BAMs from SQLite first
            let naoMgsDbURL = inputURL.appendingPathComponent("hits.sqlite")
            if fm.fileExists(atPath: naoMgsDbURL.path) {
                if !globalOptions.quiet {
                    print("Detected NAO-MGS result directory; materializing BAMs from SQLite...")
                }
                do {
                    let materialized = try NaoMgsBamMaterializer.materializeAll(
                        dbPath: naoMgsDbURL.path,
                        resultURL: inputURL,
                        samtoolsPath: samtoolsPath,
                        force: force
                    )
                    if !globalOptions.quiet {
                        print("Materialized \(materialized.count) BAM file(s)")
                    }
                } catch {
                    if !globalOptions.quiet {
                        print("Warning: NAO-MGS BAM materialization failed: \(error.localizedDescription)")
                    }
                }
            }

            if !globalOptions.quiet {
                print("Scanning \(inputURL.path) for BAM files...")
            }
            let results = try MarkdupService.markdupDirectory(
                inputURL,
                samtoolsPath: samtoolsPath,
                threads: sortThreads,
                force: force
            )
            if !globalOptions.quiet {
                printSummary(results)
            }
        } else {
            guard inputURL.pathExtension == "bam" else {
                throw ValidationError("File is not a .bam: \(inputURL.path)")
            }
            let result = try MarkdupService.markdup(
                bamURL: inputURL,
                samtoolsPath: samtoolsPath,
                threads: sortThreads,
                force: force
            )
            if !globalOptions.quiet {
                printSummary([result])
            }
        }
    }

    private func printSummary(_ results: [MarkdupResult]) {
        let processed = results.count
        let skipped = results.filter { $0.wasAlreadyMarkduped }.count
        let totalReads = results.reduce(0) { $0 + $1.totalReads }
        let totalDups = results.reduce(0) { $0 + $1.duplicateReads }
        let totalTime = results.reduce(0.0) { $0 + $1.durationSeconds }

        print("Processed \(processed) BAM file\(processed == 1 ? "" : "s") (\(skipped) already marked)")
        print("Total reads: \(totalReads), duplicates: \(totalDups)")
        print(String(format: "Elapsed: %.1fs", totalTime))
    }

    private func locateSamtools() -> String? {
        Self.locateSamtools()
    }

    static func locateSamtools(homeDirectory: URL = currentHomeDirectory()) -> String? {
        SamtoolsLocator.locate(homeDirectory: homeDirectory, searchPath: nil)
    }

    private static func currentHomeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
