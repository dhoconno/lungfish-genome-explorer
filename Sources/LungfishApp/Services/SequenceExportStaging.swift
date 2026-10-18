// SequenceExportStaging.swift - The files lungfish-cli convert reads for a sequence export selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Stages a sequence export selection as files that `lungfish-cli convert` reads (Phase 2.12 lane 12.13, A49-GAP).
///
/// A captured document snapshot holds sequences in memory with no file, and `convert` does not read a `.seq`,
/// `.txt` or extensionless file. Before the row begins, ``stage(_:format:outputURL:)`` writes each captured
/// document as `.gb` for a GenBank export and `.fa` otherwise, the records the app's own writer built (a feature
/// that names no sequence goes with every sequence of its document, as there), and copies each file `convert`
/// does not read as `.fa` (`.fa.gz` after a `.gz`), since the app read such a file as FASTA. Each file is
/// published with `DurableReplace` into `<project>/.tmp/sequence-export-<id>/` (the system temporary folder when
/// the selection names no project or its project cannot be written), beside `selection.json`, the
/// selection's metadata. The folder's marker keeps intermediates, so no sweep removes it. It stays after a
/// finished export, because the record `convert` writes names its files, and a failed or refused export
/// discards it, since no record names it then. A file `convert` reads is used where it is, and a selection of
/// such files stages nothing.
enum SequenceExportStaging {
    /// The inputs of one export run.
    struct Staged: Sendable {
        /// The files `convert` reads, in the order of the selection.
        let inputs: [URL]
        /// The staging folder, or nil when the selection staged nothing.
        let folder: URL?

        /// Removes the staging folder of an export that published nothing.
        func discard() {
            guard let folder else { return }
            try? FileManager.default.removeItem(at: folder)
        }

        /// Runs `body` on the staged inputs and removes the staging folder when it throws, since a failed or
        /// cancelled export publishes no record that names it. It runs on the caller's isolation, so a `body`
        /// that is isolated to an actor needs no hop to call it.
        func run<T>(
            isolation: isolated (any Actor)? = #isolation,
            _ body: ([URL]) async throws -> T
        ) async throws -> T {
            // Rare edge, kept: a convert that exits 0 with no readable count throws after its record names this folder.
            do { return try await body(inputs) } catch { discard(); throw error }
        }
    }

    /// The name of the selection's metadata in the staging folder.
    static let selectionFileName = "selection.json"

    /// The line width of a staged FASTA, the width of `FASTAWriter`.
    private static let fastaLineWidth = 60

    /// The bytes held before each write into a stage file.
    private static let chunkSize = 1 << 20

    /// Whether `source` is staged before `convert` reads it.
    static func needsStaging(_ source: SequenceExportSourceResolver.Source) -> Bool {
        source.document != nil || !SequenceExportRoute.convertReads(source.metadata.url)
    }

    /// Writes what `convert` cannot read of `sources` into a new staging folder and returns the inputs of the run.
    ///
    /// - Throws: "No sequences found in selected files." when every source is a captured document with no
    ///   sequence, as the app's own writer refused it, before any folder is made. A file counts as non-empty,
    ///   since only `convert` can tell, and one empty document beside a non-empty file still exports.
    ///   `CancellationError` when the calling task is cancelled, or the error of a write, after the
    ///   staging folder is removed.
    static func stage(
        _ sources: [SequenceExportSourceResolver.Source],
        format: SequenceExportFormat,
        outputURL: URL,
        date: String = AppDelegate.currentDateString()
    ) throws -> Staged {
        guard sources.contains(where: needsStaging) else {
            return Staged(inputs: sources.map(\.metadata.url), folder: nil)
        }
        guard sources.contains(where: { $0.document.map { !$0.sequences.isEmpty } ?? true }) else {
            throw NSError(
                domain: "com.lungfish.browser", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No sequences found in selected files."]
            )
        }
        let project = projectURL(for: sources, outputURL: outputURL)
        let folder: URL
        do {
            folder = try ProjectTempDirectory.create(prefix: "sequence-export-", in: project, keepIntermediates: true)
        } catch {
            // A project that cannot be written (a read-only folder or volume) must not stop an export that worked
            // at the base, which staged beside the output, so the copy goes to the system temporary folder.
            guard project != nil else { throw error }
            folder = try ProjectTempDirectory.create(prefix: "sequence-export-", in: nil, keepIntermediates: true)
        }
        do {
            var inputs: [URL] = []
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                guard needsStaging(source) else {
                    inputs.append(source.metadata.url)
                    continue
                }
                let name = stagedName(index: index, source: source, format: format)
                try DurableReplace.replace(named: name, in: folder) { writer in
                    if let document = source.document {
                        try write(document, format: format, date: date, to: writer)
                    } else {
                        try copy(source.metadata.url, to: writer)
                    }
                }
                inputs.append(folder.appendingPathComponent(name))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try DurableReplace.replace(try encoder.encode(sources.map(\.metadata)), named: selectionFileName, in: folder)
            return Staged(inputs: inputs, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The project whose `.tmp/` folder holds the staged files. A native project sequence names its project,
    /// and otherwise the first source or the output inside a project names it. Nil, when none is a folder,
    /// stages in the system temporary folder.
    static func projectURL(for sources: [SequenceExportSourceResolver.Source], outputURL: URL) -> URL? {
        let named = sources.compactMap(\.metadata.projectURL)
        let enclosing = (sources.map(\.metadata.url) + [outputURL]).compactMap(ProjectTempDirectory.findProjectRoot)
        return (named + enclosing).first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// The staged file's name, the selection's position first so two sources never share a name.
    static func stagedName(
        index: Int,
        source: SequenceExportSourceResolver.Source,
        format: SequenceExportFormat
    ) -> String {
        if let document = source.document {
            return "\(index + 1)-\(stem(document.name)).\(format == .genbank ? "gb" : "fa")"
        }
        var url = source.metadata.url
        let compressed = url.pathExtension.lowercased() == "gz"
        if compressed { url = url.deletingPathExtension() }
        return "\(index + 1)-\(stem(url.lastPathComponent)).fa" + (compressed ? ".gz" : "")
    }

    /// `name` as one file-name word.
    private static func stem(_ name: String) -> String {
        let stem = name
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return stem.isEmpty ? "sequences" : String(stem.prefix(80))
    }

    /// Writes `document` as the app's own writer wrote it, GenBank records for a GenBank export and FASTA otherwise.
    private static func write(
        _ document: SequenceExportDocumentSnapshot,
        format: SequenceExportFormat,
        date: String,
        to writer: DurableReplace.StageWriter
    ) throws {
        switch format {
        case .fasta:
            for sequence in document.sequences {
                try Task.checkCancellation()
                try writeFASTA(sequence, to: writer)
            }
        case .genbank:
            let formatter = GenBankWriter(url: URL(fileURLWithPath: "/dev/null"))
            for record in genBankRecords(document, date: date) {
                try Task.checkCancellation()
                try writer.write(Data(formatter.format(record).utf8))
            }
        }
    }

    /// The GenBank records of `document`, one for each sequence with the features that name it or name no
    /// sequence, a linear LOCUS dated `date` and the sequence's description as its DEFINITION.
    static func genBankRecords(_ document: SequenceExportDocumentSnapshot, date: String) -> [GenBankRecord] {
        document.sequences.map { sequence in
            let moleculeType: MoleculeType
            switch sequence.alphabet {
            case .dna: moleculeType = .dna
            case .rna: moleculeType = .rna
            case .protein: moleculeType = .protein
            }
            return GenBankRecord(
                sequence: sequence,
                annotations: document.annotations.filter { $0.chromosome == nil || $0.chromosome == sequence.name },
                locus: LocusInfo(
                    name: sequence.name, length: sequence.length, moleculeType: moleculeType,
                    topology: .linear, division: nil, date: date
                ),
                definition: sequence.description,
                accession: nil,
                version: nil
            )
        }
    }

    /// Writes `sequence` as `FASTAWriter` does, its header and then its bases in lines of 60.
    private static func writeFASTA(_ sequence: LungfishCore.Sequence, to writer: DurableReplace.StageWriter) throws {
        var header = ">\(sequence.name)"
        if let description = sequence.description { header += " \(description)" }
        try writer.write(Data((header + "\n").utf8))
        let bases = Array(sequence.asString().utf8)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(min(chunkSize + fastaLineWidth + 1, bases.count + bases.count / fastaLineWidth + 1))
        var start = 0
        while start < bases.count {
            let end = min(start + fastaLineWidth, bases.count)
            buffer.append(contentsOf: bases[start..<end])
            buffer.append(0x0A)
            start = end
            if buffer.count >= chunkSize {
                try buffer.withUnsafeBytes { try writer.write($0) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try buffer.withUnsafeBytes { try writer.write($0) }
    }

    /// Copies the bytes of `url` into the stage file in bounded chunks.
    private static func copy(_ url: URL, to writer: DurableReplace.StageWriter) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            try writer.write(chunk)
        }
    }
}
