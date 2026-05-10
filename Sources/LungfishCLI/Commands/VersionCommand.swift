import ArgumentParser
import Foundation
import LungfishWorkflow

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the Lungfish version and bundled tool reference"
    )

    @Flag(help: "Print the bundled and managed tool version table")
    var tools = false

    func run() async throws {
        Swift.print("Lungfish \(LungfishCLI.configuration.version)")

        guard tools else { return }

        let entries = ToolReferenceCatalog.sortedEntries()
        Swift.print("")
        Swift.print("Bundled and Managed Tools")
        printTable(entries)
    }

    private func printTable(_ entries: [ToolReferenceEntry]) {
        let rows = entries.map { entry in
            [
                entry.displayName,
                entry.version,
                entry.source.displayName,
                entry.environment ?? "-",
                entry.executables.isEmpty ? "-" : entry.executables.joined(separator: ", "),
            ]
        }

        printRows(columns: ["Tool", "Version", "Source", "Environment", "Executables"], rows: rows)
    }

    private func printRows(columns: [String], rows: [[String]]) {
        let widths = columns.indices.map { index in
            ([columns[index]] + rows.map { $0[index] }).map(\.count).max() ?? columns[index].count
        }

        Swift.print(formatRow(columns, widths: widths))
        Swift.print(formatRow(widths.map { String(repeating: "-", count: $0) }, widths: widths))
        for row in rows {
            Swift.print(formatRow(row, widths: widths))
        }
    }

    private func formatRow(_ values: [String], widths: [Int]) -> String {
        values.indices.map { index in
            values[index].padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }
}
