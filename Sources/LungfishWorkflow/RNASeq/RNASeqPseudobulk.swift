// RNASeqPseudobulk.swift - Sums a single-cell result's UMIs by sample and label (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli rnaseq pseudobulk` reads a single-cell `.lungfishrnaseq` result and a label table the analyst exports
// from Seurat or Scanpy, and returns the writer's request for a bulk result of one column a group of one sample and one
// label (`docs/formats/rnaseq-bundle.md`, Pseudobulk). It checks the result's sha256 values, refuses in words before it
// sums, reads each matrix under `source/` once and sums whole counts, never rounded. It writes nothing. The leaf writes
// the request through `RNASeqResultWriter`, so a refusal, an error or a cancel leaves no folder.

import Foundation
import LungfishCore
import LungfishIO

public enum RNASeqPseudobulk {
    /// A group of fewer cells is left out and said.
    public static let minimumCells = 10
    /// The route setting that names the sum, so a pseudobulk table never joins a bulk route's.
    public static let routeSetting = "pseudobulk"
    public static let routeSettingValue = "UMIs summed by sample and label, groups of 10 or more cells"
    static let geneExpression = "Gene Expression"

    /// One sample and one label. `umis` counts the `Gene Expression` features only.
    public struct Group: Equatable, Sendable {
        public var sample: String
        public var label: String
        public var column: String
        public var cells: Int
        public var umis: UInt64
    }

    /// The cells of one sample that the table gives no label.
    public struct Unlabelled: Equatable, Sendable {
        public var sample: String
        public var cells: Int
        public var umis: UInt64
    }

    /// What one run sums, with the writer's request and the record's facts.
    public struct Outcome: Sendable {
        public var request: RNASeqResultWriter.Request
        public var kept: [Group]
        public var dropped: [Group]
        public var unlabelled: [Unlabelled]
        /// The dropped and unlabelled lines that standard output and the record give.
        public var notes: [String]
        public var facts: [String: ParameterValue]
        public var resultManifestSHA256: String
        public var labelTableSHA256: String
    }

    public static func droppedWords(_ group: Group) -> String {
        "Group \(group.sample) \(group.label) holds \(group.cells) cells, under \(minimumCells), and is left out."
    }

    public static func unlabelledWords(_ cells: Unlabelled) -> String {
        cells.cells == 1 ? "1 cell of sample \(cells.sample) has no label and is left out."
            : "\(cells.cells) cells of sample \(cells.sample) have no label and are left out."
    }

    /// The column id of a group.
    public static func column(sample: String, label: String) -> String { "\(sample)_\(label)" }

    /// Refuses an output that exists, that is no `.lungfishrnaseq` name or whose folder is missing.
    public static func checkOutput(_ url: URL) throws {
        guard RNASeqResultBundle.isBundleURL(url) else { throw RNASeqPseudobulkRefusal.notAResultName(name: url.lastPathComponent) }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw RNASeqPseudobulkRefusal.outputExists(path: url.path) }
        var isDirectory: ObjCBool = false
        let folder = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RNASeqPseudobulkRefusal.noOutputFolder(path: folder.path)
        }
    }

    /// Labels sort by code point, as a stdlib script sorts them.
    static func codePointOrder(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.map(\.value).lexicographicallyPrecedes(b.unicodeScalars.map(\.value))
    }
}
