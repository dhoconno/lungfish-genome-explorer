// ViewerExportOptionsTests.swift - The viewer export option groups parse what the GUI's invocation writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M2, ARCH ruling G2 section 5. A probe composes every group once and builds its invocation the
// way a leaf does, so these tests prove that the groups' `apply(to:)` inverts `ViewerTableExportState.cliArguments()`
// and that every `ViewerExportOption` case is declared by a group.

import ArgumentParser
import XCTest
@testable import LungfishCLI
import LungfishWorkflow

private enum ProbeMode: String, CaseIterable, ViewerExportChoice {
    case batch
    case single
}

private enum ProbeTab: String, CaseIterable, ViewerExportChoice {
    case samples
    case demux
}

private struct ViewerExportOptionsProbe: ParsableCommand {
    static let commandPath = ["probe", "export", "table"]
    static let configuration = CommandConfiguration(commandName: "table")

    @Argument(help: "Input") var input: String
    @OptionGroup var samples: ViewerExportOptions.Samples
    @OptionGroup var search: ViewerExportOptions.Search
    @OptionGroup var sort: ViewerExportOptions.Sort
    @OptionGroup var filters: ViewerExportOptions.Filters
    @OptionGroup var metadataColumns: ViewerExportOptions.MetadataColumns
    @OptionGroup var columns: ViewerExportOptions.Columns
    @OptionGroup var mode: ViewerExportOptions.Mode<ProbeMode>
    @OptionGroup var tab: ViewerExportOptions.Tab<ProbeTab>
    @OptionGroup var format: ViewerExportOptions.ExportFormat<ViewerExportDelimitedFormat>
    @OptionGroup var selection: ViewerExportOptions.Selection
    @OptionGroup var output: ViewerExportOptions.Output
    @OptionGroup var globalOptions: GlobalOptions

    func invocation() throws -> ViewerExportInvocation {
        var state = ViewerTableExportState()
        try samples.apply(to: &state)
        try search.apply(to: &state)
        try sort.apply(to: &state)
        try filters.apply(to: &state)
        try metadataColumns.apply(to: &state)
        try columns.apply(to: &state)
        try mode.apply(to: &state)
        return ViewerExportInvocation(
            commandPath: Self.commandPath,
            input: input,
            state: state,
            tab: tab.tab.rawValue,
            outputFormat: format.format.rawValue,
            selection: selection.path,
            output: output.path,
            force: output.force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }
}

final class ViewerExportOptionsTests: XCTestCase {
    private static func fullInvocation() -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: ViewerExportOptionsProbe.commandPath,
            input: "/data/result",
            state: ViewerTableExportState(
                samples: ["s1", "s2"],
                searchText: "beta",
                sortKeys: [
                    ViewerExportSortKey(column: "name", ascending: true),
                    ViewerExportSortKey(column: "reads", ascending: false),
                ],
                filters: ColumnFilterSet(
                    filters: [
                        ColumnFilter(columnId: "reads", op: .greaterOrEqual, value: "30"),
                        ColumnFilter(columnId: "name", op: .contains, value: "x", isInverted: true),
                    ],
                    composition: .any
                ),
                metadataColumns: ["Group", "Site"],
                columns: ["reads"],
                mode: ProbeMode.batch.rawValue
            ),
            tab: ProbeTab.samples.rawValue,
            outputFormat: ViewerExportDelimitedFormat.tsv.rawValue,
            selection: "/data/in/selection.json",
            output: "/data/out.tsv",
            force: true,
            emitsEvents: true
        )
    }

    private static func parse(_ invocation: ViewerExportInvocation) throws -> ViewerExportOptionsProbe {
        try ViewerExportOptionsProbe.parse(Array(invocation.arguments().dropFirst(invocation.commandPath.count)))
    }

    func testEveryGroupRoundTripsAFullState() throws {
        let built = Self.fullInvocation()
        let parsed = try Self.parse(built).invocation()
        XCTAssertEqual(parsed, built)
        XCTAssertEqual(parsed.arguments(), built.arguments())
    }

    func testFullInvocationUsesEveryOptionName() {
        let tokens = Set(Self.fullInvocation().arguments().filter { $0.hasPrefix("--") })
        XCTAssertEqual(tokens.subtracting(["--format"]), Set(ViewerExportOption.allCases.map(\.flag)))
    }

    func testDefaultStateWritesNoViewOption() throws {
        XCTAssertEqual(ViewerTableExportState().cliArguments(), [])
        let probe = try ViewerExportOptionsProbe.parse([
            "/data/result", "--tab", "demux", "--output-format", "csv",
            "--selection", "/data/in/selection.json", "--output", "/data/out.csv",
        ])
        let invocation = try probe.invocation()
        XCTAssertEqual(invocation.state, ViewerTableExportState())
        XCTAssertFalse(invocation.force)
        XCTAssertFalse(invocation.emitsEvents)
    }

    func testShortOutputNameParses() throws {
        let probe = try ViewerExportOptionsProbe.parse([
            "/r", "--tab", "demux", "--output-format", "csv", "--selection", "/s.json", "-o", "/o.csv",
        ])
        XCTAssertEqual(probe.output.path, "/o.csv")
    }

    func testRefusesMalformedValues() {
        let base = ["/r", "--tab", "demux", "--output-format", "csv", "--selection", "/s.json", "--output", "/o.csv"]
        XCTAssertThrowsError(try ViewerExportOptionsProbe.parse(base + ["--sort", "name:sideways"]))
        XCTAssertThrowsError(try ViewerExportOptionsProbe.parse(base + ["--filter", "{"]))
        XCTAssertThrowsError(try ViewerExportOptionsProbe.parse(base + ["--filter-match", "any"]))
        XCTAssertThrowsError(try ViewerExportOptionsProbe.parse(base + ["--mode", "pivot"]))
        XCTAssertThrowsError(try ViewerExportOptionsProbe.parse(
            ["/r", "--tab", "demux", "--output-format", "xlsx", "--selection", "/s.json", "--output", "/o.csv"]
        ))
    }

    func testSortKeyKeepsAColonInTheColumnId() throws {
        let base = ["/r", "--tab", "demux", "--output-format", "csv", "--selection", "/s.json", "--output", "/o.csv"]
        let probe = try ViewerExportOptionsProbe.parse(base + ["--sort", "a:b:descending"])
        XCTAssertEqual(probe.sort.keys, [ViewerExportSortKey(column: "a:b", ascending: false)])
    }
}
