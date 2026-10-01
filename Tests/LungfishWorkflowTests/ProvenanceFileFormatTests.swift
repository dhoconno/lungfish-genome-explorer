// ProvenanceFileFormatTests.swift - Index files are named, not "unknown"
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

struct ProvenanceFileFormatTests {
    @Test("Index files are recognised from their names")
    func indexFormatsAreInferred() {
        #expect(FileFormat.inferred(fromPath: "/p/aln.sorted.bam.bai") == .bai)
        #expect(FileFormat.inferred(fromPath: "/p/aln.bam.csi") == .csi)
        #expect(FileFormat.inferred(fromPath: "/p/aln.cram.crai") == .crai)
        #expect(FileFormat.inferred(fromPath: "/p/calls.vcf.gz.tbi") == .tbi)
        #expect(FileFormat.inferred(fromPath: "/p/sequence.fa.gz.fai") == .fai)
        #expect(FileFormat.inferred(fromPath: "/p/sequence.fa.gz.gzi") == .gzi)
        #expect(FileFormat.inferred(fromPath: "/p/sequence.fa.gz") == .fasta)
        #expect(FileFormat.inferred(fromPath: "/p/reads.fq.gz") == .fastq)
        #expect(FileFormat.inferred(fromPath: "/p/notes.bin") == .unknown)
    }

    @Test("Formats have plain display names")
    func displayNames() {
        #expect(FileFormat.bai.displayName == "BAM index")
        #expect(FileFormat.csi.displayName == "CSI index")
        #expect(FileFormat.crai.displayName == "CRAM index")
        #expect(FileFormat.tbi.displayName == "Tabix index")
        #expect(FileFormat.fai.displayName == "FASTA index")
        #expect(FileFormat.gzi.displayName == "BGZF index")
        #expect(FileFormat.bam.displayName == "BAM")
        #expect(FileFormat.fastq.displayName == "FASTQ")
        #expect(FileFormat.genBank.displayName == "GenBank")
        #expect(FileFormat.unknown.displayName == "unknown")
    }

    @Test("A recorded unknown format resolves from the file name")
    func recordedUnknownResolvesFromName() {
        let descriptor = ProvenanceFileDescriptor(path: "/p/aln.bam.bai", format: .unknown, role: .index)
        #expect(descriptor.resolvedFormat == .bai)
        let bare = ProvenanceFileDescriptor(path: "/p/aln.bam.bai", format: nil, role: .index)
        #expect(bare.resolvedFormat == .bai)
        let recorded = ProvenanceFileDescriptor(path: "/p/table.txt", format: .json, role: .output)
        #expect(recorded.resolvedFormat == .json)
    }

    @Test("Index formats round-trip through JSON")
    func indexFormatsEncode() throws {
        let data = try JSONEncoder().encode([FileFormat.bai, .tbi, .fai, .gzi, .csi, .crai])
        let decoded = try JSONDecoder().decode([FileFormat].self, from: data)
        #expect(decoded == [.bai, .tbi, .fai, .gzi, .csi, .crai])
    }
}
