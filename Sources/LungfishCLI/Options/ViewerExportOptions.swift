// ViewerExportOptions.swift - The option groups a viewer export leaf composes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishWorkflow

/// A group that carries part of a viewer's table state into ``ViewerTableExportState``. Its `apply(to:)` inverts the
/// state's `cliArguments()` for the options it declares (Phase 2.12, ARCH ruling G2-4).
protocol ViewerExportStateGroup: ParsableArguments {
    func apply(to state: inout ViewerTableExportState) throws
}

/// The values one leaf accepts for `--mode`, `--tab` or `--output-format`, each a `String` raw-value enum.
protocol ViewerExportChoice: ExpressibleByArgument, CaseIterable, RawRepresentable, Sendable
    where RawValue == String {}

/// The option groups of the viewer export leaves (Phase 2.12, ARCH ruling G2-1).
///
/// One small group per row of the ARCH 1.2 table, plus `Tab`. A leaf composes one `@OptionGroup` for each group whose
/// state changes its bytes, so its help lists only the options it applies. Every name comes from
/// ``ViewerExportOption``, the spelling the GUI's ``ViewerExportInvocation`` writes, and `--format` stays the event
/// switch of ``GlobalOptions``.
enum ViewerExportOptions {
    struct Samples: ViewerExportStateGroup {
        @Option(
            name: .customLong(ViewerExportOption.sample.rawValue),
            parsing: .singleValue,
            help: "A sample to export, as the result records its id. Repeat for more. Absent means every sample"
        )
        var samples: [String] = []

        func apply(to state: inout ViewerTableExportState) throws {
            state.samples = samples
        }
    }

    struct Search: ViewerExportStateGroup {
        @Option(
            name: .customLong(ViewerExportOption.search.rawValue),
            help: "Keep the rows the viewer's search matches for this text"
        )
        var text: String?

        func apply(to state: inout ViewerTableExportState) throws {
            state.searchText = text
        }
    }

    struct Sort: ViewerExportStateGroup {
        @Option(
            name: .customLong(ViewerExportOption.sort.rawValue),
            parsing: .singleValue,
            help: "Sort by a column, written <column>:ascending or <column>:descending. The first is the primary key"
        )
        var keys: [ViewerExportSortKey] = []

        func apply(to state: inout ViewerTableExportState) throws {
            state.sortKeys = keys
        }
    }

    struct Filters: ViewerExportStateGroup {
        @Option(
            name: .customLong(ViewerExportOption.filter.rawValue),
            parsing: .singleValue,
            help: "A column filter as the viewer stores it, one JSON object. Repeat for more"
        )
        var filters: [String] = []

        @Option(
            name: .customLong(ViewerExportOption.filterMatch.rawValue),
            help: "Keep a row when all filters match or when any filter matches (default all)"
        )
        var match: ColumnFilterComposition?

        func validate() throws {
            if match != nil, filters.isEmpty {
                throw ValidationError("Pass --filter-match only with at least one --filter.")
            }
            _ = try decodedFilters()
        }

        func apply(to state: inout ViewerTableExportState) throws {
            try validate()
            state.filters = ColumnFilterSet(filters: try decodedFilters(), composition: match ?? .all)
        }

        private func decodedFilters() throws -> [ColumnFilter] {
            try filters.map { text in
                do {
                    return try ViewerTableExportState.decodedFilter(text)
                } catch {
                    throw ValidationError("The --filter value is not a column filter: \(text)")
                }
            }
        }
    }

    struct MetadataColumns: ViewerExportStateGroup {
        @Option(
            name: .customLong(ViewerExportOption.metadataColumn.rawValue),
            parsing: .singleValue,
            help: "A sample metadata column to add, by name. Repeat for more. Values come from the result's metadata"
        )
        var columns: [String] = []

        func apply(to state: inout ViewerTableExportState) throws {
            state.metadataColumns = columns
        }
    }

    struct Columns: ViewerExportStateGroup {
        @Option(
            name: .customLong(ViewerExportOption.column.rawValue),
            parsing: .singleValue,
            help: "A table column to write, by id. Repeat for more"
        )
        var columns: [String] = []

        func apply(to state: inout ViewerTableExportState) throws {
            state.columns = columns
        }
    }

    struct Mode<Value: ViewerExportChoice>: ViewerExportStateGroup {
        @Option(name: .customLong(ViewerExportOption.mode.rawValue), help: "The table mode whose rows to write")
        var mode: Value?

        func apply(to state: inout ViewerTableExportState) throws {
            state.mode = mode?.rawValue
        }
    }

    struct Tab<Value: ViewerExportChoice>: ParsableArguments {
        @Option(name: .customLong(ViewerExportOption.tab.rawValue), help: "The tab whose table to write")
        var tab: Value
    }

    struct ExportFormat<Format: ViewerExportChoice>: ParsableArguments {
        @Option(name: .customLong(ViewerExportOption.outputFormat.rawValue), help: "The file format to write")
        var format: Format
    }

    struct Selection: ParsableArguments {
        @Option(
            name: .customLong(ViewerExportOption.selection.rawValue),
            help: "The selection file the app wrote for state the result files do not hold"
        )
        var path: String
    }

    struct Output: ParsableArguments {
        @Option(
            name: [.customLong(ViewerExportOption.output.rawValue), .customShort("o")],
            help: "The file to write. An existing file is refused without --force"
        )
        var path: String

        @Flag(name: .customLong(ViewerExportOption.force.rawValue), help: "Overwrite an existing output file")
        var force = false
    }

    /// What one viewer figure draws (Phase 2.13 lane 13.30, ARCH ruling B10 3.1). Each name comes from
    /// ``ViewerGraphicExport/Option``, the spelling the app's invocation writes.
    struct Graphic: ParsableArguments {
        @Option(
            name: .customLong(ViewerGraphicExport.Option.region.rawValue),
            help: "The region to draw, as contig:start-end, 1-based and inclusive, as samtools takes it, such as chr1:101-200."
        )
        var region: String

        @Option(
            name: .customLong(ViewerGraphicExport.Option.width.rawValue),
            help: "The figure width in points. The default is 800. The app passes the width of its view."
        )
        var width: Double?

        @Flag(
            name: .customLong(ViewerGraphicExport.Option.includeRuler.rawValue),
            help: "Draw the coordinate ruler above the tracks."
        )
        var includeRuler = false

        @Option(
            name: .customLong(ViewerGraphicExport.Option.track.rawValue),
            parsing: .singleValue,
            help: "A track to draw, by the id the bundle's manifest records. Repeat for more, in drawn order. Absent means the bundle's tracks."
        )
        var tracks: [String] = []

        @Option(
            name: .customLong(ViewerExportOption.outputFormat.rawValue),
            help: "The image format, png, jpeg, tiff or pdf."
        )
        var format: ViewerFigureFormat

        @Option(
            name: .customLong(ViewerGraphicExport.Option.scale.rawValue),
            help: "Pixels per point of a bitmap, 1, 2 or 4. The default is 2. A PDF takes no scale."
        )
        var scale: Int?

        @Option(
            name: .customLong(ViewerGraphicExport.Option.theme.rawValue),
            help: "The theme to draw with, light or dark. The default is light. The app passes the appearance of its viewer."
        )
        var theme: ViewerGraphicExport.Theme?

        @Option(
            name: .customLong(ViewerGraphicExport.Option.excludeFlags.rawValue),
            help: "The SAM flags of reads to leave out, as a number. The default is 2308, as in the viewer."
        )
        var excludeFlags: UInt16?

        @Option(
            name: .customLong(ViewerGraphicExport.Option.coverageScale.rawValue),
            help: "The coverage scale of an alignment track, linear, log10 or squareRoot."
        )
        var coverageScale: CoverageScaleMode?

        @Option(
            name: .customLong(ViewerGraphicExport.Option.viewState.rawValue),
            help: "The view-state file the app wrote for track settings it holds only in memory."
        )
        var viewState: String?

        func validate() throws {
            if let scale, !ViewerGraphicExport.scales.contains(scale) {
                throw ValidationError("Pass --scale 1, 2 or 4.")
            }
            if scale != nil, format == .pdf {
                throw ValidationError("A PDF takes no --scale. Pass --scale only with png, jpeg or tiff.")
            }
            if let width, !(width.isFinite && width >= 1) {
                throw ValidationError("Pass a --width of at least 1 point.")
            }
        }

        var settings: ViewerGraphicExport.Settings {
            ViewerGraphicExport.Settings(
                region: region, width: width, includeRuler: includeRuler, tracks: tracks, format: format, scale: scale,
                theme: theme, excludeFlags: excludeFlags, coverageScale: coverageScale, viewState: viewState
            )
        }
    }
}

extension ViewerFigureFormat: ViewerExportChoice {}
extension ViewerGraphicExport.Theme: ExpressibleByArgument {}
extension CoverageScaleMode: ExpressibleByArgument {}

extension ViewerExportSortKey: ExpressibleByArgument {}
extension ColumnFilterComposition: ExpressibleByArgument {}
extension ViewerExportDelimitedFormat: ViewerExportChoice {}
extension FASTQSampleBarcodeTab: ViewerExportChoice {}
