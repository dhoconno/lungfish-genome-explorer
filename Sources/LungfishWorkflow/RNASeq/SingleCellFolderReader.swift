// SingleCellFolderReader.swift - Cell Ranger outs folders and STARsolo run folders read as given (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A Cell Ranger `outs/` folder keeps `filtered_feature_bc_matrix/` and `metrics_summary.csv`, and a STARsolo run folder
// keeps `Log.final.out`, `Solo.out/Gene/filtered/` and `Solo.out/Gene/Summary.csv` (`docs/formats/rnaseq-bundle.md`,
// The tool's own files). The reader checks the matrix's header and size line against its features and barcodes before
// anything is written, and names every other file it leaves out, each `.h5` with its sha256 and size. It never keeps a
// `raw` matrix, whose barcodes are the whole list of 10x (`Tests/Fixtures/rnaseq/README.md:27`). The writer's pass reads
// each kept matrix once into `cells.sqlite` (`SingleCellSummarizer`).

import CryptoKit
import Foundation
import LungfishIO

public enum SingleCellTool: String, Sendable, Equatable {
    case cellRanger = "Cell Ranger"
    case starsolo = "STARsolo"
}

/// One Cell Ranger or STARsolo folder as the tool wrote it.
public struct SingleCellFolder: Sendable, Equatable {
    /// A file the import leaves out but names with its checksum, such as an HDF5 matrix.
    public struct LeftOutFile: Sendable, Equatable {
        public var path: String
        public var sha256: String
        public var size: Int64

        public init(path: String, sha256: String, size: Int64) {
            self.path = path
            self.sha256 = sha256
            self.size = size
        }
    }

    /// The sample id, the run folder's name unless a sample sheet labels it.
    public var sample: String
    /// The folder every path below is under: Cell Ranger's `outs/` or STARsolo's run folder.
    public var url: URL
    public var tool: SingleCellTool
    /// The version the matrix states, Cell Ranger's from its `%metadata_json:` line, or nil when it states none.
    public var toolVersion: String?
    public var matrix: String
    public var features: String
    public var barcodes: String
    /// The files kept under `source/<sample>/`, sorted with `<`.
    public var keptFiles: [String]
    /// Every other file or folder (with a trailing `/`), sorted with `<`.
    public var leftOut: [String]
    public var leftOutHDF5: [LeftOutFile]
    public var size: MatrixMarketSize
    public var featureIDs: [String]
    /// The type of each feature, `Gene Expression` for a file with no type column.
    public var featureTypeOfRow: [String]
    /// The summary file's names and values as the tool printed them.
    public var qualityColumns: [String]
    public var qualityValues: [String]

    public var featureTypes: [String: Int] { featureTypeOfRow.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
}

/// Why a single-cell folder was refused, in words a person can act on.
public enum SingleCellImportError: Error, Equatable, LocalizedError, Sendable {
    case notSingleCellFolder(String)
    case cellRangerMulti(String)
    case missingFile(tool: String, sample: String, file: String)
    case sizeDiffers(sample: String, what: String, stated: Int, file: String, listed: Int)
    case toolsDiffer
    case featuresDiffer(first: String, other: String)
    case featureOfNoGenome(feature: String, sample: String, genomes: [String])

    public var errorDescription: String? {
        switch self {
        case .notSingleCellFolder(let name):
            return "\(name) holds neither the filtered_feature_bc_matrix folder of Cell Ranger nor the Solo.out folder of STARsolo, so it is no single-cell folder LGE reads."
        case .cellRangerMulti(let name):
            return "\(name) is the outs folder of cellranger multi, whose per-sample folders LGE does not import yet. Import a cellranger count outs folder or a STARsolo run folder."
        case .missingFile(let tool, let sample, let file):
            return "The \(tool) folder \(sample) has no \(file), so it cannot be imported."
        case .sizeDiffers(let sample, let what, let stated, let file, let listed):
            return "The matrix of \(sample) states \(stated) \(what) in its size line and \(file) lists \(listed), so the files do not belong together."
        case .toolsDiffer:
            return "Cell Ranger and STARsolo count cells by two routes, so their folders cannot share one result. Import each tool's folders in a run of its own."
        case .featuresDiffer(let first, let other):
            return "The single-cell folders \(first) and \(other) list different features, so they were not counted on one reference and cannot share one result."
        case .featureOfNoGenome(let feature, let sample, let genomes):
            return "The feature \(feature) of \(sample) starts with none of the genomes named (\(genomes.joined(separator: ", "))). Name every genome of the reference with --genome, or none."
        }
    }
}

public enum SingleCellFolderReader {
    public static let geneExpression = "Gene Expression"

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether `url` is a folder this reader takes: Cell Ranger's `outs/`, a run folder that holds it, or STARsolo's.
    public static func isSingleCellFolder(_ url: URL) -> Bool {
        let outs = url.appendingPathComponent("outs", isDirectory: true)
        return ["filtered_feature_bc_matrix", "per_sample_outs", "Solo.out"].contains { isDirectory(url.appendingPathComponent($0)) }
            || ["filtered_feature_bc_matrix", "per_sample_outs"].contains { isDirectory(outs.appendingPathComponent($0)) }
    }

    public static func read(folder: URL) throws -> SingleCellFolder {
        var base = folder
        var sample = folder.lastPathComponent
        if sample == "outs" {
            sample = folder.deletingLastPathComponent().lastPathComponent
        } else if isDirectory(folder.appendingPathComponent("outs", isDirectory: true)) {
            base = folder.appendingPathComponent("outs", isDirectory: true)
        }
        if isDirectory(base.appendingPathComponent("per_sample_outs")) { throw SingleCellImportError.cellRangerMulti(sample) }
        let tool: SingleCellTool
        let matrixFolder: String
        var extra: [String] = []
        if isDirectory(base.appendingPathComponent("filtered_feature_bc_matrix")) {
            tool = .cellRanger
            matrixFolder = "filtered_feature_bc_matrix"
            extra = ["metrics_summary.csv"]
        } else if isDirectory(base.appendingPathComponent("Solo.out")) {
            tool = .starsolo
            matrixFolder = "Solo.out/Gene/filtered"
            extra = ["Log.final.out", "Solo.out/Gene/Summary.csv"]
        } else {
            throw SingleCellImportError.notSingleCellFolder(folder.lastPathComponent)
        }
        func find(_ names: [String]) throws -> String {
            let paths = names.flatMap { ["\(matrixFolder)/\($0).gz", "\(matrixFolder)/\($0)"] }
            guard let found = paths.first(where: { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }) else {
                throw SingleCellImportError.missingFile(tool: tool.rawValue, sample: sample, file: "\(matrixFolder)/\(names[0])")
            }
            return found
        }
        let matrix = try find(["matrix.mtx"])
        let features = try find(["features.tsv", "genes.tsv"])
        let barcodes = try find(["barcodes.tsv"])
        let present = extra.filter { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
        let kept = ([matrix, features, barcodes] + present).sorted()

        let reader = try MatrixMarketReader(url: base.appendingPathComponent(matrix))
        let size = reader.size
        let toolVersion = tool == .cellRanger ? cellRangerVersion(reader.comments) : nil
        reader.close()
        let featureRows = try MatrixMarketReader.textLines(of: base.appendingPathComponent(features)).map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        let barcodeCount = try MatrixMarketReader.textLines(of: base.appendingPathComponent(barcodes)).count
        let featuresName = (features as NSString).lastPathComponent
        guard featureRows.count == size.rows else {
            throw SingleCellImportError.sizeDiffers(sample: sample, what: "features", stated: size.rows, file: featuresName, listed: featureRows.count)
        }
        guard barcodeCount == size.columns else {
            throw SingleCellImportError.sizeDiffers(
                sample: sample, what: "barcodes", stated: size.columns, file: (barcodes as NSString).lastPathComponent, listed: barcodeCount)
        }
        let quality = try summary(base, tool: tool, present: present)
        var leftOut: [String] = []
        var hdf5: [SingleCellFolder.LeftOutFile] = []
        try walk(base, prefix: "", kept: Set(kept), leftOut: &leftOut, hdf5: &hdf5)
        return SingleCellFolder(
            sample: sample, url: base, tool: tool, toolVersion: toolVersion, matrix: matrix, features: features, barcodes: barcodes, keptFiles: kept,
            leftOut: leftOut.sorted(), leftOutHDF5: hdf5.sorted { $0.path < $1.path }, size: size,
            featureIDs: featureRows.map { $0.first ?? "" },
            featureTypeOfRow: featureRows.map { $0.count > 2 ? $0[2] : geneExpression },
            qualityColumns: quality.map(\.0), qualityValues: quality.map(\.1))
    }

    /// Cell Ranger's version from the comment its matrix writes on line 2, `%metadata_json: {"format_version": 2,
    /// "software_version": "3.0.0"}` (5.0 writes `cellranger-5.0.0`, whose prefix is dropped). Nil when no such line
    /// names a version.
    static func cellRangerVersion(_ comments: [String]) -> String? {
        let key = "%metadata_json:"
        guard let line = comments.first(where: { $0.hasPrefix(key) }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(key.count).utf8)) as? [String: Any],
              let stated = (object["software_version"] as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        let version = stated.hasPrefix("cellranger-") ? String(stated.dropFirst("cellranger-".count)) : stated
        return version.isEmpty ? nil : version
    }

    /// Names each file and folder under `folder` that is not kept, a folder with no kept file as one entry.
    private static func walk(
        _ folder: URL, prefix: String, kept: Set<String>, leftOut: inout [String], hdf5: inout [SingleCellFolder.LeftOutFile]
    ) throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let relative = prefix + name
            let url = folder.appendingPathComponent(name)
            if kept.contains(relative) { continue }
            if isDirectory(url) {
                if kept.contains(where: { $0.hasPrefix(relative + "/") }) {
                    try walk(url, prefix: relative + "/", kept: kept, leftOut: &leftOut, hdf5: &hdf5)
                } else {
                    leftOut.append(relative + "/")
                }
                continue
            }
            leftOut.append(relative)
            if name.hasSuffix(".h5") {
                let (sha256, size) = try hashFile(url)
                hdf5.append(.init(path: relative, sha256: sha256, size: size))
            }
        }
    }

    /// The sha256 and size of an `.h5` file, read in 1 MiB chunks, each in its own autorelease pool so the hash holds
    /// one chunk and not the whole file.
    static func hashFile(_ url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            try Task.checkCancellation()
            hasher.update(data: chunk)
            size += Int64(chunk.count)
            return true
        }) {}
        return (RNASeqResultBundle.hex(hasher.finalize()), size)
    }
}
