// ReferenceSetAnnotation.swift - Reading a set's GTF and FASTA files and deriving its tables (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

struct ReferenceSetGeneRow: Equatable {
    var id: String
    var name: String
    var biotype: String
    var contig: String
    var length: Int
    var notHost: Bool
}

struct ReferenceSetAnnotationRead {
    var genes: [ReferenceSetGeneRow] = []
    var transcriptGenes: [(transcript: String, gene: String)] = []
    /// Every sequence name a feature line gives, in the order first seen.
    var sequenceNames: [String] = []
    var exonsAdded: [String] = []
    var keptWithoutExon: [String] = []
    var dropped: [String] = []
}

struct ReferenceSetFASTARecord: Equatable {
    var name: String
    var length: Int
    var header: String
}

enum ReferenceSetAnnotationReader {
    private final class Gene {
        var contig: String
        var name: String?
        var biotype: String?
        var firstExon: Int?
        var firstCDS: Int?
        var exons: [ClosedRange<Int>] = []
        /// CDS and stop codon lines by transcript, for a gene the annotation gives no exon.
        var coding: [String: ClosedRange<Int>] = [:]
        init(contig: String) { self.contig = contig }
    }

    /// Reads a GTF, plain or gzip. With `addExon`, a gene with a CDS and no exon gets its CDS and stop codon as one
    /// exon a transcript (LGE's layout). Without it the gene keeps no exon and counts 0 (the deposit layout).
    static func read(_ url: URL, addExon: Bool, notHost: Bool) throws -> ReferenceSetAnnotationRead {
        var read = ReferenceSetAnnotationRead()
        var genes: [String: Gene] = [:]
        var seenNames = Set<String>()
        var seenTranscripts = Set<String>()
        var lineNumber = 0
        try url.forEachLineAutoDecompressing { line in
            lineNumber += 1
            if line.hasPrefix("#") || line.isEmpty { return }
            let cells = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false)
            guard cells.count == 9 else { return }
            let contig = String(cells[0])
            if seenNames.insert(contig).inserted { read.sequenceNames.append(contig) }
            let type = cells[2]
            let attributes = parseAttributes(cells[8])
            guard let geneID = attributes["gene_id"], !geneID.isEmpty else {
                read.dropped.append("\(contig)\t\(type)\t\(cells[3])\t\(cells[4])")
                return
            }
            let gene = genes[geneID] ?? Gene(contig: contig)
            genes[geneID] = gene
            if gene.name == nil { gene.name = attributes["gene_name"] ?? attributes["gene"] }
            if gene.biotype == nil { gene.biotype = attributes["gene_biotype"] ?? attributes["gene_type"] }
            guard type == "exon" || type == "CDS" || type == "stop_codon",
                  let start = Int(cells[3]), let end = Int(cells[4]), start <= end else { return }
            let transcript = attributes["transcript_id"] ?? ""
            if type == "exon" {
                gene.firstExon = gene.firstExon ?? lineNumber
                gene.exons.append(start...end)
            } else {
                if type == "CDS" { gene.firstCDS = gene.firstCDS ?? lineNumber }
                let span = gene.coding[transcript].map { min($0.lowerBound, start)...max($0.upperBound, end) } ?? start...end
                gene.coding[transcript] = span
            }
            if type != "stop_codon", !transcript.isEmpty, seenTranscripts.insert(transcript).inserted {
                read.transcriptGenes.append((transcript, geneID))
            }
        }
        let ordered = genes.compactMap { id, gene in (gene.firstExon ?? gene.firstCDS).map { ($0, id, gene) } }
            .sorted { $0.0 < $1.0 }
        for (_, id, gene) in ordered {
            var spans = gene.exons
            if spans.isEmpty {
                if addExon {
                    spans = Array(gene.coding.values)
                    read.exonsAdded.append(id)
                } else {
                    read.keptWithoutExon.append(id)
                }
            }
            read.genes.append(ReferenceSetGeneRow(
                id: id, name: gene.name ?? id, biotype: gene.biotype ?? "", contig: gene.contig,
                length: mergedLength(spans), notHost: notHost))
        }
        return read
    }

    /// One feature a record, named by the record (an extra in LGE's layout).
    static func recordFeatures(_ records: [ReferenceSetFASTARecord], biotype: String) -> ReferenceSetAnnotationRead {
        var read = ReferenceSetAnnotationRead()
        for record in records {
            read.genes.append(ReferenceSetGeneRow(
                id: record.name, name: record.name, biotype: biotype, contig: record.name, length: record.length, notHost: true))
            read.transcriptGenes.append((record.name, record.name))
            read.sequenceNames.append(record.name)
        }
        return read
    }

    /// The `key "value"` pairs of a GTF attribute column. A quoted value may hold a `;`.
    static func parseAttributes(_ column: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = column.startIndex
        while index < column.endIndex {
            while index < column.endIndex, column[index] == " " || column[index] == ";" { index = column.index(after: index) }
            guard let space = column[index...].firstIndex(of: " ") else { break }
            let key = String(column[index..<space])
            var cursor = column.index(after: space)
            var value = ""
            if cursor < column.endIndex, column[cursor] == "\"" {
                let open = column.index(after: cursor)
                let close = column[open...].firstIndex(of: "\"") ?? column.endIndex
                value = String(column[open..<close])
                cursor = close < column.endIndex ? column.index(after: close) : close
            } else {
                let stop = column[cursor...].firstIndex(of: ";") ?? column.endIndex
                value = String(column[cursor..<stop])
                cursor = stop
            }
            if result[key] == nil { result[key] = value }
            index = column[cursor...].firstIndex(of: ";") ?? column.endIndex
        }
        return result
    }

    /// The bases the spans cover, each base once.
    static func mergedLength(_ spans: [ClosedRange<Int>]) -> Int {
        var total = 0
        var current: ClosedRange<Int>?
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let open = current, span.lowerBound <= open.upperBound + 1 {
                current = open.lowerBound...max(open.upperBound, span.upperBound)
            } else {
                if let open = current { total += open.count }
                current = span
            }
        }
        return total + (current?.count ?? 0)
    }

    /// The records of a FASTA, plain or gzip, with each name the first word of its header.
    static func fastaRecords(_ url: URL) throws -> [ReferenceSetFASTARecord] {
        var records: [ReferenceSetFASTARecord] = []
        try url.forEachLineAutoDecompressing { line in
            if line.hasPrefix(">") {
                let header = String(line.dropFirst())
                let name = header.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                records.append(ReferenceSetFASTARecord(name: name, length: 0, header: header))
            } else if !records.isEmpty {
                records[records.count - 1].length += line.trimmingCharacters(in: .whitespacesAndNewlines).count
            }
        }
        return records
    }

    /// The mitochondrial contigs: the ones named, else the assembly report's Mitochondrion, else a header that says
    /// mitochondrion, else a contig of a mitochondrial name. Never a gene name prefix (`refcheck.py:225`).
    static func mitochondrialContigs(
        named: [String], report: URL?, genome: [ReferenceSetFASTARecord], annotationNames: [String]
    ) throws -> [String] {
        if !named.isEmpty { return named }
        let known = Set(genome.map(\.name)).union(annotationNames)
        if let report {
            var hits: [String] = []
            try report.forEachLineAutoDecompressing { line in
                let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard !line.hasPrefix("#"), cells.count > 6, cells[3] == "Mitochondrion" else { return }
                for index in [6, 4, 0, 9] where index < cells.count && cells[index] != "na" && known.contains(cells[index]) {
                    if !hits.contains(cells[index]) { hits.append(cells[index]) }
                }
            }
            if !hits.isEmpty { return hits }
        }
        let headers = genome.filter { $0.header.lowercased().contains("mitochondrion") }.map(\.name)
        if !headers.isEmpty { return headers }
        return ["MT", "chrM", "chrMT", "M", "Mt"].filter(known.contains)
    }
}
