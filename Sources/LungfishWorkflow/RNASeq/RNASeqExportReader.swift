// RNASeqExportReader.swift - Reads each result at export and refuses in words (Phase 5.1 lane RS-HANDOFF)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `rnaseq export` reads each result with the reader of RS-KIND after its sha256 values hold, so a replaced `quant.sf` or
// table is refused in words that name the file. Route and set are read from each result at every export and never cached
// (`SCR/rulings/ADJ-BULK-5.md:18-20`). A route is the tool, its version and every setting that changes counts.

import Foundation
import LungfishIO

/// A refusal of the export, which reads as the words a person acts on. It exits 3 before any file is written.
public struct RNASeqExportRefusal: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One result as read at export.
public struct RNASeqExportResult: Sendable {
    public let url: URL
    public let result: RNASeqResult

    public var manifest: RNASeqResultManifest { result.manifest }
    /// The folder's name, which the refusals use.
    public var label: String { url.lastPathComponent }
}

/// The words of the refusals, so a test and a person read one text.
public enum RNASeqExportWords {
    /// A route as a person reads it, such as `salmon-reads (salmon 2.11.0, input reads, mode selective-alignment)`.
    public static func route(_ route: RNASeqResultManifest.Route) -> String {
        let notRecorded = RNASeqResultBundle.notRecordedText
        let tool = route.tool == notRecorded ? "tool \(notRecorded)" : "\(route.tool) \(route.toolVersion)"
        let settings = route.settings.sorted { $0.key < $1.key }.map { ", \($0.key) \($0.value)" }.joined()
        return "\(route.id) (\(tool)\(settings))"
    }

    public static func referenceSet(_ set: RNASeqResultManifest.ReferenceSet?) -> String {
        set.map { "\($0.id) (\($0.layout.rawValue) layout)" } ?? RNASeqResultBundle.notRecordedText
    }

    static func samples(_ count: Int) -> String { count == 1 ? "1 sample" : "\(count) samples" }

    static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

public enum RNASeqExportReader {
    /// A single-cell result exports by itself, because its export is a folder of matrices and not one table. It is refused
    /// beside a bulk result, and beside a second single-cell result, in words that name what to do instead.
    public static func refuseMixedModalities(_ results: [RNASeqExportResult]) throws {
        let single = results.filter { $0.manifest.modality == .singleCell }
        guard let first = single.first, results.count > 1 else { return }
        if let bulk = results.first(where: { $0.manifest.modality != .singleCell }) {
            throw RNASeqExportRefusal(
                "The single-cell result \(first.label) cannot share an export with the bulk result \(bulk.label). "
                    + "The export of a single-cell result writes its matrices and the Seurat and Scanpy templates by itself. "
                    + "Export it alone, or sum its cells with rnaseq pseudobulk and export that bulk result.")
        }
        let names = single.map(\.label)
        throw RNASeqExportRefusal(
            "The results \(RNASeqExportWords.list(names)) are \(names.count == 2 ? "both" : "all") single-cell. "
                + "LGE writes one folder of matrices for one result, so export each by itself, or import the samples into one result.")
    }

    /// Reads each folder. A file that differs from the sha256 the manifest lists is refused with its path. A folder that
    /// is no readable result is refused with the reader's own words. Nothing is written.
    public static func read(_ urls: [URL]) throws -> [RNASeqExportResult] {
        guard !urls.isEmpty else {
            throw RNASeqExportRefusal("Pass at least one RNA-seq result folder to export.")
        }
        return try urls.map { url in
            try Task.checkCancellation()
            let label = url.lastPathComponent
            do {
                // A cell map holds no counts, so it is refused in words before its files are hashed.
                if let manifest = try? RNASeqResultBundle.loadManifest(from: url), manifest.modality == .cellMap {
                    throw RNASeqExportRefusal(RNASeqCellMapError.cellMapGiven(
                        name: label, parent: manifest.parent?.path ?? RNASeqResultBundle.notRecordedText, use: .export).errorDescription ?? "")
                }
                let changed = try RNASeqResultBundle.verifyChecksums(of: url)
                if !changed.isEmpty {
                    let files = changed.map { $0.actual == nil ? "\($0.path) (missing)" : $0.path }.joined(separator: ", ")
                    throw RNASeqExportRefusal(
                        "The RNA-seq result \(label) changed after LGE wrote it. Its file \(files) no longer matches the sha256 the result lists, "
                            + "so its counts are not the ones LGE recorded. Restore the file from a copy, or import or count the data again.")
                }
                let loaded = try RNASeqResultBundle.load(from: url)
                // Manifest notHost is the authority, and the templates read the not_host flags of genes.tsv, so the two must agree.
                let flagged = Set(loaded.genes.filter { $0.notHost == true }.map(\.id))
                guard flagged == Set(loaded.manifest.notHost) else {
                    throw RNASeqExportRefusal(
                        "The RNA-seq result \(label) lists \(loaded.manifest.notHost.count) not-host features in its manifest and flags \(flagged.count) in genes.tsv, "
                            + "so LGE cannot tell which rows stay out of size factors. Count the reads again with LGE, or import the result again.")
                }
                return RNASeqExportResult(url: url, result: loaded)
            } catch let refusal as RNASeqExportRefusal {
                throw refusal
            } catch let error as RNASeqResultError {
                throw RNASeqExportRefusal("\(label) cannot be exported. \(error.localizedDescription)")
            }
        }
    }
}
