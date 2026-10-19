// GenotypeWorkbookExport.swift - The genotype workbook export the genotype viewer and its leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The genotype viewer's Excel export (Phase 2.12 lane 12.35, row B1, ARCH-12.35-B1 route (a)).
///
/// The workbook's rows are projections that only the viewer's matrix computes. So before `begin` the viewer writes
/// the capture it froze before the save panel opened, and the provenance request that describes it, to
/// `capture.json` and `request.json` in a new `.lungfish-export-inputs/<UUID>/` folder beside the output. The row then
/// runs `lungfish-cli genotype export-xlsx --snapshot <capture> --provenance-request <request> --python <python>
/// --output <file> [--force]`, which renders the capture through ``GenotypeExcelExportService``, and its receipt names
/// both files as inputs with their digests. The capture is a frozen view capture, an input class of its own with B1
/// its only member, and not the selection file of ``ViewerExportSelection``. It may hold the view's projected values,
/// styles and colors, since rendering them is the leaf's work, and never the workbook.
public enum GenotypeWorkbookExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["genotype", "export-xlsx"]
    /// The capture's file name inside the inputs folder.
    public static let captureFileName = "capture.json"
    /// The request's file name inside the inputs folder.
    public static let requestFileName = "request.json"
    /// The workflow the viewer's request names. The leaf's receipt keeps it as `originalWorkflowName`.
    public static let requestWorkflowName = "genotype.export.excel"

    /// The leaf's invocation, with absolute standardized paths. The begin helper passes its `arguments()` to the
    /// runner and to the row's command, the viewer's request records its `canonicalArgv()`, and the leaf rebuilds it
    /// from its options and records the same array.
    public struct Invocation: Sendable, Equatable {
        public var capture: String
        public var request: String
        public var python: String
        public var output: String
        public var force: Bool

        public init(captureURL: URL, requestURL: URL, pythonURL: URL, outputURL: URL, force: Bool) {
            capture = captureURL.standardizedFileURL.path
            request = requestURL.standardizedFileURL.path
            python = pythonURL.standardizedFileURL.path
            output = outputURL.standardizedFileURL.path
            self.force = force
        }

        /// The argv without the executable. The leaf's contract row is a result row, so it carries no
        /// `--format json`.
        public func arguments() -> [String] {
            GenotypeWorkbookExport.commandPath + [
                "--snapshot", capture,
                "--provenance-request", request,
                "--python", python,
                "--output", output,
            ] + (force ? ["--force"] : [])
        }

        /// The argv the request and the receipt record, which starts with ``CLICommandIdentity/executableName``.
        public func canonicalArgv() -> [String] {
            [CLICommandIdentity.executableName] + arguments()
        }
    }

    /// The capture and request files of a new `.lungfish-export-inputs/<UUID>/` folder beside `outputURL`. Nothing is
    /// written, so the request can name its own path before it is written.
    public static func inputURLs(besideOutput outputURL: URL) -> (capture: URL, request: URL) {
        let directory = outputURL.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent(ViewerExportSelection.inputsFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (directory.appendingPathComponent(captureFileName), directory.appendingPathComponent(requestFileName))
    }

    /// Writes the capture and the request to the files `invocation` names with the Excel service's one encoder, so
    /// that the digest of `capture.json` equals the receipt's `snapshot.sha256` (ARCH-12.35-B1 condition 1). A failed
    /// write removes the folder.
    public static func write(
        capture: GenotypeWorkbookPresentation.Snapshot,
        request: GenotypeExcelExportService.ProvenanceRequest,
        to invocation: Invocation
    ) throws {
        let captureURL = URL(fileURLWithPath: invocation.capture)
        let directory = captureURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try GenotypeExcelExportService.replayEncoded(capture).write(to: captureURL, options: .atomic)
            try GenotypeExcelExportService.replayEncoded(request)
                .write(to: URL(fileURLWithPath: invocation.request), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
