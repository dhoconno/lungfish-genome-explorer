// ViewerGraphicExport.swift - The viewer image export of a bundle, shared by the app and its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// File > Export > Image of a genome bundle, drawn from the bundle's files by `bundle export-graphic` (Phase 2.13
/// lane 13.30, owner rows O17 and O18, ARCH ruling B10 section 3).
///
/// The app builds ``invocation(bundleURL:settings:outputURL:force:emitsEvents:)`` from the view and runs its
/// ``ViewerExportInvocation/arguments()`` behind the Operations row. The leaf rebuilds the same invocation from its
/// parsed options and records ``ViewerExportInvocation/canonicalArgv()``, so row and record name one command.
public enum ViewerGraphicExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling X-1, a sibling of `bundle export`).
    public static let commandPath = ["bundle", "export-graphic"]
    /// The workflow name the leaf's record carries.
    public static let workflowName = "lungfish bundle export-graphic"
    /// The width a command line draws when it passes no `--width`. The app always passes the view's width.
    public static let defaultWidth = 800.0
    /// The bitmap scales the save panel offers, in pixels per point.
    public static let scales = [1, 2, 4]
    /// The scale a command line draws a bitmap at when it passes no `--scale`, the panel's first choice.
    public static let defaultScale = 2
    /// The convention every region of the leaf and its record is written in (BIO ruling Q-G3, item 1).
    public static let regionConvention = "1-based closed"

    /// The flags only this leaf takes, spelled once for the leaf, the app and the record. `--output-format`,
    /// `--output` and `--force` are ``ViewerExportOption`` flags.
    public enum Option: String, CaseIterable, Sendable {
        case region
        case regionsFile = "regions-file"
        case width
        case includeRuler = "include-ruler"
        case track
        case scale
        case theme
        case excludeFlags = "exclude-flags"
        case coverageScale = "coverage-scale"
        case viewState = "view-state"

        /// The long flag, such as `--include-ruler`.
        public var flag: String { "--" + rawValue }
    }

    /// The theme a figure is drawn in. The command draws light unless it is passed `dark`.
    public enum Theme: String, CaseIterable, Codable, Sendable {
        case light
        case dark

        public var appearance: ViewerFigureAppearance {
            switch self {
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// What one figure draws, as the leaf's options state it. A nil value is one the command line left out.
    public struct Settings: Sendable, Equatable {
        /// The region as passed, `contig:start-end`, 1-based and closed. Nil in the bulk form.
        public var region: String?
        /// The absolute path of the BED file of the bulk form, one figure for each region line.
        public var regionsFile: String?
        public var width: Double?
        public var includeRuler: Bool
        /// Track ids in drawn order. Empty means the bundle's default tracks.
        public var tracks: [String]
        public var format: ViewerFigureFormat
        public var scale: Int?
        public var theme: Theme?
        public var excludeFlags: UInt16?
        public var coverageScale: CoverageScaleMode?
        /// The absolute path of the view-state file the app wrote.
        public var viewState: String?

        public init(
            region: String? = nil, regionsFile: String? = nil, width: Double? = nil, includeRuler: Bool = false,
            tracks: [String] = [], format: ViewerFigureFormat, scale: Int? = nil, theme: Theme? = nil,
            excludeFlags: UInt16? = nil, coverageScale: CoverageScaleMode? = nil, viewState: String? = nil
        ) {
            self.region = region
            self.regionsFile = regionsFile
            self.width = width
            self.includeRuler = includeRuler
            self.tracks = tracks
            self.format = format
            self.scale = scale
            self.theme = theme
            self.excludeFlags = excludeFlags
            self.coverageScale = coverageScale
            self.viewState = viewState
        }
    }

    /// The leaf's invocation for one figure, with absolute standardized paths.
    public static func invocation(
        bundleURL: URL, settings: Settings, outputURL: URL, force: Bool, emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: bundleURL.standardizedFileURL.path,
            leafArguments: leafArguments(settings),
            outputFormat: settings.format.rawValue,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// The leaf's own flags in one fixed order.
    static func leafArguments(_ settings: Settings) -> [String] {
        var arguments: [String] = []
        if let region = settings.region {
            arguments += [Option.region.flag, region]
        }
        if let regionsFile = settings.regionsFile {
            arguments += [Option.regionsFile.flag, URL(fileURLWithPath: regionsFile).standardizedFileURL.path]
        }
        if let width = settings.width {
            arguments += [Option.width.flag, number(width)]
        }
        if settings.includeRuler {
            arguments.append(Option.includeRuler.flag)
        }
        for track in settings.tracks {
            arguments += [Option.track.flag, track]
        }
        if let scale = settings.scale {
            arguments += [Option.scale.flag, String(scale)]
        }
        if let theme = settings.theme {
            arguments += [Option.theme.flag, theme.rawValue]
        }
        if let excludeFlags = settings.excludeFlags {
            arguments += [Option.excludeFlags.flag, String(excludeFlags)]
        }
        if let coverageScale = settings.coverageScale {
            arguments += [Option.coverageScale.flag, coverageScale.rawValue]
        }
        if let viewState = settings.viewState {
            arguments += [Option.viewState.flag, URL(fileURLWithPath: viewState).standardizedFileURL.path]
        }
        return arguments
    }

    /// A number as the argv and the record write it, with no `.0` on a whole number.
    public static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
