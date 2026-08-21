// OpsCommand.swift - Operation history and resource statistics
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct OpsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ops",
        abstract: "Inspect completed operation history and resource usage",
        subcommands: [
            StatsSubcommand.self,
        ]
    )
}

extension OpsCommand {
    struct StatsSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stats",
            abstract: "Summarize runtime and peak RAM from provenance sidecars"
        )

        @Argument(help: "Project or bundle directory containing .lungfish-provenance.json sidecars")
        var project: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let formatter = TerminalFormatter(useColors: globalOptions.useColors)
            let projectURL = URL(fileURLWithPath: project).standardizedFileURL
            let report = try OperationStatsAggregator().summarize(projectURL: projectURL)

            print(formatter.header("Operation Stats"))
            print("")
            print(formatter.keyValueTable([
                ("Project", projectURL.path),
                ("Provenance sidecars", "\(report.sidecarCount)"),
                ("Completed runs", "\(report.completedRunCount)"),
                ("Total wall time", LungfishFormatters.formatDuration(report.totalWallTimeSeconds)),
                ("Peak RAM", formatBytes(report.peakMemoryBytes)),
            ]))

            guard !report.operations.isEmpty else {
                print("")
                print(formatter.info("No completed operation provenance found."))
                return
            }

            print("")
            print(formatter.table(
                headers: ["Operation", "Runs", "Total", "Average", "Peak RAM"],
                rows: report.operations.map { summary in
                    [
                        summary.name,
                        "\(summary.completedRunCount)",
                        LungfishFormatters.formatDuration(summary.totalWallTimeSeconds),
                        LungfishFormatters.formatDuration(summary.averageWallTimeSeconds),
                        formatBytes(summary.peakMemoryBytes),
                    ]
                }
            ))
        }
    }
}

private func formatBytes(_ bytes: UInt64?) -> String {
    guard let bytes else { return "unknown" }
    return LungfishFormatters.formatBytes(bytes)
}
