// ProvenanceMethodsSubjectTableTests.swift - The subject each program gets in the methods text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The constant subjects of the methods export are rows of a table keyed by program token. This suite pins
// every row at the text the switch it replaced had, so a row cannot change by accident when a later lane
// adds a program.

import Testing
@testable import LungfishWorkflow

struct ProvenanceMethodsSubjectTableTests {
    private static let exporter = ProvenanceExporter(signingProvider: nil)

    /// The subject of the sentence of `tool` when its steps recorded no subcommand.
    private static func subject(_ tool: String) -> String {
        exporter.methodsOperation(tool: tool, subcommands: [])
    }

    @Test("Each program with one subject keeps it under every spelling of its name")
    func constantSubjects() {
        let rows: [(programs: [String], subject: String)] = [
            (["bgzip"], "Files were block-compressed"),
            (["tabix"], "Compressed files were indexed"),
            (["bedToBigBed"], "BED files were converted to BigBed"),
            (["bedGraphToBigWig"], "Signal tracks were converted to BigWig"),
            (["fastp"], "Reads were quality-filtered and trimmed"),
            (["fastqc"], "Read quality was assessed"),
            (["multiqc"], "Quality reports were aggregated"),
            (["bwa", "bwa-mem2"], "Reads were aligned"),
            (["minimap2"], "Reads were mapped to the reference"),
            (["spades", "spades.py"], "Reads were assembled de novo"),
            (["seqkit"], "Sequences were summarized"),
            (["vsearch"], "Sequences were clustered"),
            (["cutadapt"], "Adapters were trimmed"),
            (["bbduk.sh", "bbduk"], "Reads were quality-filtered and adapters removed"),
            (["bbmerge.sh", "bbmerge"], "Paired reads were merged"),
            (["clumpify.sh", "clumpify"], "Reads were clumped and deduplicated"),
            (["pigz", "gzip"], "Files were compressed"),
            (["kraken2"], "Reads were classified taxonomically"),
            (["bracken"], "Taxon abundances were re-estimated"),
            (["EsViritu"], "Viral sequences were detected"),
            (["mafft"], "Sequences were aligned"),
            (["iqtree", "iqtree2", "iqtree3"], "A phylogeny was inferred"),
        ]
        #expect(rows.flatMap(\.programs).count == 30)
        for row in rows {
            for program in row.programs {
                #expect(Self.subject(program) == row.subject, Comment(rawValue: program))
            }
        }
    }

    @Test("The subject is read from the program token, so a folder, a letter case or a subcommand in the name changes nothing")
    func subjectFollowsTheProgramToken() {
        #expect(Self.subject("/opt/conda/envs/bbtools/bin/bbduk.sh") == "Reads were quality-filtered and adapters removed")
        #expect(Self.subject("FastQC") == "Read quality was assessed")
        #expect(Self.subject("fastp trim") == "Reads were quality-filtered and trimmed")
    }

    @Test("A program without a row, and an empty name, get the neutral subject")
    func unlistedProgramsAreNeutral() {
        #expect(Self.subject("megahit") == "Processing was performed")
        #expect(Self.subject("") == "Processing was performed")
    }
}
