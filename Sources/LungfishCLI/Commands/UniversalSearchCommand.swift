// UniversalSearchCommand.swift - Project-scoped universal metadata search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO

/// Search datasets and analysis artifacts within a single project.
struct UniversalSearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "universal-search",
        abstract: "Universal search across datasets and analyses in a project",
        discussion: """
            Queries the project-scoped universal search index for FASTQ datasets,
            reference/VCF metadata, classification results, EsViritu detections,
            and flattened JSON manifests.

            Examples:
              lungfish universal-search ./Project.lungfish --query "type:fastq_dataset role:air_sample date>=2025-01-01"
              lungfish universal-search ./Project.lungfish --query "virus:HKU1" --stats
              lungfish universal-search ./Project.lungfish --query "sample:patient42" --reindex --format json
            """
    )

    @Argument(help: "Path to the project directory (.lungfish)")
    var projectPath: String

    @Option(name: .long, help: "Universal search query text")
    var query: String = ""

    @Option(name: .long, help: "Maximum number of results (default: 200)")
    var limit: Int = 200

    @Flag(name: .long, help: "Force index rebuild before querying")
    var reindex: Bool = false

    @Flag(name: .long, help: "Include indexing/query timing and entity-count diagnostics")
    var stats: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CLIError.inputFileNotFound(path: projectPath)
        }

        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let boundedLimit = max(1, limit)
        let commandStart = Date()

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        let preStats = try index.indexStats()

        var rebuildStats: ProjectUniversalSearchBuildStats?
        if reindex || preStats.entityCount == 0 {
            if globalOptions.outputFormat == .text, !globalOptions.quiet {
                let message = reindex
                    ? "Rebuilding universal search index..."
                    : "Building universal search index..."
                print(formatter.info(message))
            }
            rebuildStats = try index.rebuild()
        }

        let queryStart = Date()
        let results = try index.search(rawQuery: query, limit: boundedLimit)
        let queryDuration = Date().timeIntervalSince(queryStart)
        let finalStats = try index.indexStats()
        let totalDuration = Date().timeIntervalSince(commandStart)

        switch globalOptions.outputFormat {
        case .json:
            let payload = UniversalSearchOutput(
                projectPath: projectURL.path,
                query: query,
                limit: boundedLimit,
                resultCount: results.count,
                results: results.map {
                    UniversalSearchResultPayload(
                        id: $0.id,
                        kind: $0.kind,
                        title: $0.title,
                        subtitle: $0.subtitle,
                        format: $0.format,
                        path: relativePath(for: $0.url, projectURL: projectURL)
                    )
                },
                stats: stats
                    ? UniversalSearchStatsPayload(
                        totalDurationSeconds: totalDuration,
                        queryDurationSeconds: queryDuration,
                        indexEntityCount: finalStats.entityCount,
                        indexAttributeCount: finalStats.attributeCount,
                        perKindCounts: finalStats.perKindCounts,
                        rebuild: rebuildStats.map {
                            UniversalSearchBuildPayload(
                                indexedEntities: $0.indexedEntities,
                                indexedAttributes: $0.indexedAttributes,
                                durationSeconds: $0.durationSeconds,
                                perKindCounts: $0.perKindCounts
                            )
                        }
                    )
                    : nil
            )
            JSONOutputHandler().writeData(payload, label: nil)

        case .tsv:
            print("kind\ttitle\tsubtitle\tformat\tpath")
            for result in results {
                print([
                    result.kind,
                    sanitizeTSV(result.title),
                    sanitizeTSV(result.subtitle ?? ""),
                    sanitizeTSV(result.format ?? ""),
                    sanitizeTSV(relativePath(for: result.url, projectURL: projectURL)),
                ].joined(separator: "\t"))
            }

            if stats {
                FileHandle.standardError.write(
                    "query_seconds\ttotal_seconds\tentities\tattributes\n".data(using: .utf8) ?? Data()
                )
                FileHandle.standardError.write(
                    "\(queryDuration)\t\(totalDuration)\t\(finalStats.entityCount)\t\(finalStats.attributeCount)\n"
                        .data(using: .utf8) ?? Data()
                )
            }

        case .text:
            if !globalOptions.quiet {
                print(formatter.success("Found \(results.count) result(s)"))
            }

            for result in results {
                let subtitle = result.subtitle.map { " — \($0)" } ?? ""
                let format = result.format.map { " [\($0)]" } ?? ""
                let rel = relativePath(for: result.url, projectURL: projectURL)
                print("[\(result.kind)] \(result.title)\(subtitle)\(format) -> \(rel)")
            }

            if stats {
                if !results.isEmpty { print("") }
                print(formatter.header("Universal Search Stats"))
                print(formatter.keyValueTable([
                    ("Query Seconds", String(format: "%.3f", queryDuration)),
                    ("Total Seconds", String(format: "%.3f", totalDuration)),
                    ("Index Entities", "\(finalStats.entityCount)"),
                    ("Index Attributes", "\(finalStats.attributeCount)"),
                ]))

                if let rebuildStats {
                    print("")
                    print(formatter.header("Rebuild"))
                    print(formatter.keyValueTable([
                        ("Indexed Entities", "\(rebuildStats.indexedEntities)"),
                        ("Indexed Attributes", "\(rebuildStats.indexedAttributes)"),
                        ("Duration", String(format: "%.3fs", rebuildStats.durationSeconds)),
                    ]))
                }

                if !finalStats.perKindCounts.isEmpty {
                    print("")
                    print(formatter.header("Per Kind"))
                    for (kind, count) in finalStats.perKindCounts.sorted(by: { $0.key < $1.key }) {
                        print("  \(kind): \(count)")
                    }
                }
            }
        }
    }

    private func relativePath(for url: URL, projectURL: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let absolutePath = url.standardizedFileURL.path
        let rootPrefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"

        if absolutePath == projectPath {
            return "."
        }

        if absolutePath.hasPrefix(rootPrefix) {
            return String(absolutePath.dropFirst(rootPrefix.count))
        }

        return absolutePath
    }

    private func sanitizeTSV(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private struct UniversalSearchResultPayload: Codable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let format: String?
    let path: String
}

private struct UniversalSearchBuildPayload: Codable {
    let indexedEntities: Int
    let indexedAttributes: Int
    let durationSeconds: Double
    let perKindCounts: [String: Int]
}

private struct UniversalSearchStatsPayload: Codable {
    let totalDurationSeconds: Double
    let queryDurationSeconds: Double
    let indexEntityCount: Int
    let indexAttributeCount: Int
    let perKindCounts: [String: Int]
    let rebuild: UniversalSearchBuildPayload?
}

private struct UniversalSearchOutput: Codable {
    let projectPath: String
    let query: String
    let limit: Int
    let resultCount: Int
    let results: [UniversalSearchResultPayload]
    let stats: UniversalSearchStatsPayload?
}
