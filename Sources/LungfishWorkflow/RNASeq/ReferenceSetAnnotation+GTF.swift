// ReferenceSetAnnotation+GTF.swift - The two passes over a set's GTF and the GTF that gffread reads (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// gffread never reads the annotation as given. RefSeq gives the tRNA, rRNA and CDS lines of a mitochondrion one
// transcript id, and gffread 0.12.9 then writes chimeric records of one name, so LGE writes the GTF it hands gffread
// in the stage (`docs/formats/reference-set.md`, section Layout).

import Foundation
import LungfishIO

/// One feature line of a GTF, with its attributes parsed. A comment, an empty line or a line without nine columns is none.
struct ReferenceSetGTFFeature {
    let contig: String
    let type: String
    let start: Substring
    let end: Substring
    let strand: String
    let attributes: [String: String]

    var gene: String { attributes["gene_id"] ?? "" }
    var transcript: String { attributes["transcript_id"] ?? "" }

    init?(_ line: String) {
        if line.hasPrefix("#") || line.isEmpty { return nil }
        let cells = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false)
        guard cells.count == 9 else { return nil }
        contig = String(cells[0])
        type = String(cells[2])
        start = cells[3]
        end = cells[4]
        strand = String(cells[6])
        attributes = ReferenceSetAnnotationReader.parseAttributes(cells[8])
    }

    /// `line` with this feature's transcript id replaced by `renamed` in the attribute column, and nothing else changed.
    func renamingTranscript(in line: String, to renamed: String) -> String {
        let cells = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false)
        var column = String(cells[8])
        for form in ["transcript_id \"\(transcript)\"", "transcript_id \(transcript)"] {
            if let range = column.range(of: form) {
                column.replaceSubrange(range, with: "transcript_id \"\(renamed)\"")
                break
            }
        }
        return cells[0..<8].joined(separator: "\t") + "\t" + column
    }
}

extension ReferenceSetAnnotationReader {
    /// The first pass: the genes, the sequence names, the dropped features, and the genes, contigs and strands each
    /// transcript id names.
    static func scanGTF(_ url: URL, into read: inout ReferenceSetAnnotationRead) throws -> Scan {
        var scan = Scan()
        var seenNames = Set<String>()
        var seenPairs = Set<String>()
        var lineNumber = 0
        try url.forEachLineAutoDecompressing { line in
            lineNumber += 1
            guard let feature = ReferenceSetGTFFeature(line) else { return }
            if seenNames.insert(feature.contig).inserted { read.sequenceNames.append(feature.contig) }
            let geneID = feature.gene
            guard !geneID.isEmpty else {
                read.dropped.append("\(feature.contig)\t\(feature.type)\t\(feature.start)\t\(feature.end)")
                return
            }
            let gene = scan.genes[geneID] ?? Gene(contig: feature.contig, firstLine: lineNumber)
            scan.genes[geneID] = gene
            if gene.name == nil { gene.name = feature.attributes["gene_name"] ?? feature.attributes["gene"] }
            if gene.biotype == nil { gene.biotype = feature.attributes["gene_biotype"] ?? feature.attributes["gene_type"] }
            let transcript = feature.transcript
            if !transcript.isEmpty {
                let place = "\(feature.contig)\t\(feature.strand)"
                if let known = scan.owners[transcript] {
                    if !known.contains(where: { $0.gene == geneID && $0.place == place }) {
                        scan.owners[transcript] = known + [(geneID, place)]
                    }
                } else {
                    scan.owners[transcript] = [(geneID, place)]
                    scan.transcriptOrder.append(transcript)
                }
                if feature.type == "exon" || feature.type == "CDS" || feature.type == "transcript",
                   seenPairs.insert("\(transcript)\t\(geneID)").inserted {
                    scan.pairs.append((transcript, geneID))
                }
            }
            guard let start = Int(feature.start), let end = Int(feature.end), start <= end else { return }
            if feature.type == "exon" {
                gene.firstExon = gene.firstExon ?? lineNumber
                gene.exons.append(start...end)
            } else if feature.type == "CDS" || feature.type == "stop_codon" {
                if feature.type == "CDS" { gene.firstCDS = gene.firstCDS ?? lineNumber }
                guard !transcript.isEmpty else { return }
                if feature.type == "CDS", !gene.codingOrder.contains(transcript) { gene.codingOrder.append(transcript) }
                let span = gene.coding[transcript].map { min($0.span.lowerBound, start)...max($0.span.upperBound, end) } ?? start...end
                gene.coding[transcript] = (span, feature.contig, feature.strand)
            }
        }
        return scan
    }

    /// The second pass writes the GTF that gffread reads. It leaves out each line of empty `gene_id` and each line of a
    /// gene in `leaving`, except the lines with no transcript id of a gene in `keepingGeneLines` (a gene the deposit
    /// layout keeps without an exon), renames each transcript id by `rename`, and adds one exon line a transcript with
    /// a CDS of each gene in `addedExons` from its CDS and stop codon span.
    static func writeGTF(
        from url: URL, to gtf: URL, leaving: Set<String>, keepingGeneLines: Set<String>,
        rename: (String, String) -> String, addedExons: [(id: String, gene: Gene)]
    ) throws {
        let writer = try ReferenceSetLineWriter(gtf)
        try url.forEachLineAutoDecompressing { line in
            guard let feature = ReferenceSetGTFFeature(line) else { return }
            let geneID = feature.gene
            let transcript = feature.transcript
            guard !geneID.isEmpty else { return }
            if leaving.contains(geneID), !(transcript.isEmpty && keepingGeneLines.contains(geneID)) { return }
            if transcript.isEmpty { return try writer.write(line) }
            let renamed = rename(transcript, geneID)
            try writer.write(renamed == transcript ? line : feature.renamingTranscript(in: line, to: renamed))
        }
        for (id, gene) in addedExons {
            for transcript in gene.codingOrder {
                guard let coding = gene.coding[transcript] else { continue }
                try writer.write("\(coding.contig)\tLGE\texon\t\(coding.span.lowerBound)\t\(coding.span.upperBound)\t.\t"
                    + "\(coding.strand)\t.\tgene_id \"\(id)\"; transcript_id \"\(rename(transcript, id))\";")
            }
        }
        try writer.close()
    }
}

/// Writes lines through one handle and a buffer, for a work file in the stage that goes before the rename.
final class ReferenceSetLineWriter {
    private let handle: FileHandle
    private var buffer = Data()

    init(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ReferenceSetError.invalidRequest("Lungfish could not write \(url.path).")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: String) throws {
        buffer.append(contentsOf: line.utf8)
        buffer.append(0x0A)
        if buffer.count >= 1 << 20 { try flush() }
    }

    func close() throws {
        try flush()
        try handle.close()
    }

    private func flush() throws {
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
