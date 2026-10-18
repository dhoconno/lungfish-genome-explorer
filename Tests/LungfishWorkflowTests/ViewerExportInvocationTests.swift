// ViewerExportInvocationTests.swift - The one builder of a viewer export leaf's argv
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M2 (2), ARCH ruling G2-3 and section 5. The CLI's ViewerExportOptionsTests prove that the
// groups' `apply(to:)` inverts these arguments.

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class ViewerExportInvocationTests: XCTestCase {
    static let readsFilter = #"{"columnId":"reads","isInverted":false,"op":"≥","value":"30"}"#
    static let nameFilter = #"{"columnId":"name","isInverted":true,"op":"∋","value":"a/b","value2":"z"}"#

    static func fullInvocation() -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: ["probe", "export", "table"],
            input: "/data/result",
            leafArguments: ["--materialize-derived"],
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
                        ColumnFilter(columnId: "name", op: .contains, value: "a/b", value2: "z", isInverted: true),
                    ],
                    composition: .any
                ),
                metadataColumns: ["Group", "Site"],
                columns: ["reads"],
                mode: "batch"
            ),
            tab: "samples",
            outputFormat: "tsv",
            selection: "/data/in/selection.json",
            output: "/data/out.tsv",
            force: true,
            emitsEvents: true
        )
    }

    func testArgumentsFollowTheFixedOrder() {
        XCTAssertEqual(Self.fullInvocation().arguments(), [
            "probe", "export", "table", "/data/result", "--materialize-derived",
            "--sample", "s1", "--sample", "s2",
            "--search", "beta",
            "--sort", "name:ascending", "--sort", "reads:descending",
            "--filter", Self.readsFilter, "--filter", Self.nameFilter, "--filter-match", "any",
            "--metadata-column", "Group", "--metadata-column", "Site",
            "--column", "reads",
            "--mode", "batch",
            "--tab", "samples",
            "--output-format", "tsv",
            "--selection", "/data/in/selection.json",
            "--output", "/data/out.tsv",
            "--force",
            "--format", "json",
        ])
    }

    func testCanonicalArgvStartsWithTheCLIName() {
        let invocation = Self.fullInvocation()
        XCTAssertEqual(invocation.canonicalArgv().first, CLICommandIdentity.executableName)
        XCTAssertEqual(Array(invocation.canonicalArgv().dropFirst()), invocation.arguments())
    }

    func testMinimalInvocationWritesOnlyThePathInputAndOutput() {
        let invocation = ViewerExportInvocation(
            commandPath: ["nvd", "export", "contigs"], input: "/r", output: "/o.tsv", emitsEvents: false
        )
        XCTAssertEqual(invocation.arguments(), ["nvd", "export", "contigs", "/r", "--output", "/o.tsv"])
    }

    func testDefaultStateWritesNoViewOption() {
        XCTAssertEqual(ViewerTableExportState().cliArguments(), [])
        var onlyMatch = ViewerTableExportState()
        onlyMatch.filters.composition = .any
        XCTAssertEqual(onlyMatch.cliArguments(), [], "--filter-match is written only with a filter")
    }

    func testFilterJSONHasSortedKeysAndDecodesBack() throws {
        let filter = ColumnFilter(columnId: "name", op: .contains, value: "a/b", value2: "z", isInverted: true)
        XCTAssertEqual(ViewerTableExportState.encodedFilter(filter), Self.nameFilter)
        XCTAssertEqual(try ViewerTableExportState.decodedFilter(Self.nameFilter), filter)
        XCTAssertThrowsError(try ViewerTableExportState.decodedFilter("{"))
    }

    func testSortKeyParsesAtTheLastColon() {
        XCTAssertEqual(
            ViewerExportSortKey(argument: "a:b:descending"), ViewerExportSortKey(column: "a:b", ascending: false)
        )
        XCTAssertEqual(ViewerExportSortKey(argument: "name:ascending")?.argument, "name:ascending")
        XCTAssertNil(ViewerExportSortKey(argument: "name:sideways"))
        XCTAssertNil(ViewerExportSortKey(argument: ":ascending"))
        XCTAssertNil(ViewerExportSortKey(argument: "name"))
    }

    func testEveryFlagIsALongNameSpelledOnce() {
        let flags = ViewerExportOption.allCases.map(\.flag)
        XCTAssertEqual(Set(flags).count, flags.count)
        XCTAssertTrue(flags.allSatisfy { $0.hasPrefix("--") && !$0.contains(" ") })
        XCTAssertFalse(flags.contains("--format"), "--format stays the event switch")
    }
}
