// RNASeqResultWriter+Files.swift - The files the one writer puts in a result (Phase 5.1 lane RS-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

public enum RNASeqResultWriterError: Error, Equatable, LocalizedError, Sendable {
    case notAResultFolder(String)
    case alreadyExists(String)
    case appleDoubleFile(String)
    case unsafeSourcePath(String)
    case duplicateSourcePath(String)
    case cannotCreate(String)
    case duplicateCountTable(String)
    case noMaskedTranscriptTable
    case referenceSetMismatch
    case invalidGeneTable(String)
    case geneNotInReferenceSet(String)
    case matrixFileNotKept(String)

    public var errorDescription: String? {
        switch self {
        case .notAResultFolder(let name):
            return "\(name) cannot hold an RNA-seq result, because the name of a result folder ends in .lungfishrnaseq."
        case .alreadyExists(let name):
            return "\(name) already exists, so the RNA-seq result was not written. Choose another name."
        case .appleDoubleFile(let name):
            return "\(name) is an AppleDouble file that macOS leaves beside a file on an ExFAT drive, and no tool wrote it. Leave it out of the files to keep."
        case .unsafeSourcePath(let path):
            return "The path \(path) of a file to keep is absolute or leaves its sample's folder."
        case .duplicateSourcePath(let path):
            return "Two files of the tool would be kept as \(path). Name them apart or keep one."
        case .cannotCreate(let name):
            return "The file \(name) of the RNA-seq result could not be created."
        case .duplicateCountTable(let path):
            return "The result would hold two count tables as \(path). One table holds one route on one reference set."
        case .noMaskedTranscriptTable:
            return "A result keeps no masked table of transcripts. Only gene tables have a masked column."
        case .referenceSetMismatch:
            return "A result with a reference set takes its genes from that set's gene table, and a result with none holds the feature ids only."
        case .invalidGeneTable(let name):
            return "The reference set's gene table \(name) has no header, so the result's genes could not be written."
        case .geneNotInReferenceSet(let id):
            return "The gene \(id) is not in the reference set's gene table, so the result's genes could not be written."
        case .matrixFileNotKept(let path):
            return "The matrix file \(path) is not among the files to keep, so its hash is unknown."
        }
    }
}

extension RNASeqResultWriter {
    struct CopiedSources {
        var entries: [Manifest.SourceFileEntry] = []
        /// Each sample's folder under `source/`, which the sanitizer may have changed or suffixed.
        var folders: [String: String] = [:]
    }

    private static func isPlainRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !parts.contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    /// Copies each file into `source/`, as given, hashing it as it reads it.
    func copySources(_ request: Request, into stage: URL) throws -> CopiedSources {
        let fileManager = FileManager.default
        let source = stage.appendingPathComponent("source", isDirectory: true)
        let tables = source.appendingPathComponent("tables", isDirectory: true)
        // `tables` is taken first, so no sample folder takes that name and a sample called tables becomes tables-2.
        try fileManager.createDirectory(at: tables, withIntermediateDirectories: true)
        var copied = CopiedSources()
        for file in request.sourceFiles {
            try Task.checkCancellation()
            guard Self.isPlainRelativePath(file.relativePath) else { throw RNASeqResultWriterError.unsafeSourcePath(file.relativePath) }
            guard !file.url.lastPathComponent.hasPrefix("._") else { throw RNASeqResultWriterError.appleDoubleFile(file.url.lastPathComponent) }
            let relative: String
            if let sample = file.sample {
                if copied.folders[sample] == nil {
                    copied.folders[sample] = try AnalysesFolder.batchSampleDirectory(named: sample, in: source).lastPathComponent
                }
                relative = "source/\(copied.folders[sample] ?? sample)/\(file.relativePath)"
            } else {
                relative = "source/tables/\(file.url.lastPathComponent)"
            }
            let destination = stage.appendingPathComponent(relative)
            guard !fileManager.fileExists(atPath: destination.path) else { throw RNASeqResultWriterError.duplicateSourcePath(relative) }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (sha256, size) = try copyHashing(file.url, to: destination)
            copied.entries.append(.init(path: relative, sha256: sha256, size: size, sample: file.sample ?? "", tool: file.tool))
        }
        for folder in [tables, source] where (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try fileManager.removeItem(at: folder)
        }
        return copied
    }

    func copyHashing(_ source: URL, to destination: URL) throws -> (sha256: String, size: Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw RNASeqResultWriterError.cannotCreate(destination.lastPathComponent)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            size += Int64(chunk.count)
        }
        try output.synchronize()
        return (RNASeqResultBundle.hex(hasher.finalize()), size)
    }

    /// Writes each count table under `counts/`, named by its rows and column as the layout page names them.
    func writeCounts(_ inputs: [CountInput], into stage: URL) throws -> [Manifest.CountEntry] {
        var entries: [Manifest.CountEntry] = []
        let folder = stage.appendingPathComponent("counts", isDirectory: true)
        for input in inputs {
            let name: String
            switch (input.rows, input.column) {
            case (.gene, .default): name = "genes.counts.tsv"
            case (.gene, .masked): name = "genes.masked.tsv"
            case (.transcript, .default): name = "transcripts.counts.tsv"
            case (.transcript, .masked): throw RNASeqResultWriterError.noMaskedTranscriptTable
            }
            let path = "counts/\(name)"
            guard !entries.contains(where: { $0.path == path }) else { throw RNASeqResultWriterError.duplicateCountTable(path) }
            let data = try input.table.tsvData()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try DurableReplace.replace(data, named: name, in: folder)
            entries.append(.init(path: path, sha256: RNASeqResultBundle.sha256Hex(data), rows: input.rows, unit: input.unit, column: input.column))
        }
        return entries
    }

    /// The bytes of `genes.tsv`: the set's file when every gene is kept, its rows for fewer, the ids alone with no set.
    func genesTable(for request: Request) throws -> Data {
        switch request.genes {
        case .ids(let ids):
            guard request.referenceSet == nil else { throw RNASeqResultWriterError.referenceSetMismatch }
            var seen = Set<String>()
            return try RNASeqGeneRecord.tsvData(ids.filter { seen.insert($0).inserted }.map { RNASeqGeneRecord(id: $0) })
        case .referenceSetTable(let url, let keeping):
            guard request.referenceSet != nil else { throw RNASeqResultWriterError.referenceSetMismatch }
            let data = try Data(contentsOf: url)
            let lines = String(decoding: data, as: UTF8.self)
                .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map(String.init)
            guard let header = lines.first else { throw RNASeqResultWriterError.invalidGeneTable(url.lastPathComponent) }
            var byID: [String: String] = [:]
            var order: [String] = []
            for line in lines.dropFirst() {
                let id = String(line.prefix { $0 != "\t" })
                if byID.updateValue(line, forKey: id) == nil { order.append(id) }
            }
            if let missing = keeping.first(where: { byID[$0] == nil }) { throw RNASeqResultWriterError.geneNotInReferenceSet(missing) }
            let kept = Set(keeping)
            if kept.count == order.count { return data }
            return Data((([header] + order.filter { kept.contains($0) }.compactMap { byID[$0] }).joined(separator: "\n") + "\n").utf8)
        }
    }

    /// Refuses a quality row whose sample is not among the request's samples, before anything is staged.
    func checkQuality(_ request: Request) throws {
        guard let quality = request.quality else { return }
        let known = Set(request.samples.map(\.id))
        if let stray = quality.rows.first(where: { !known.contains($0.sample) }) {
            throw RNASeqResultError.invalidTable(
                path: RNASeqQualityTable.path, reason: "the sample \(stray.sample) is not among the result's samples")
        }
    }

    /// Writes `quality/samples.quality.tsv` when the request holds a quality table.
    func writeQuality(_ table: RNASeqQualityTable?, into stage: URL) throws -> Manifest.FileEntry? {
        guard let table else { return nil }
        let data = try table.tsvData()
        let folder = stage.appendingPathComponent("quality", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DurableReplace.replace(data, named: "samples.quality.tsv", in: folder)
        return .init(path: RNASeqQualityTable.path, sha256: RNASeqResultBundle.sha256Hex(data))
    }
}
