// SequenceExportParityExpected.swift - The app writer's text of each parity case after decompression
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Written by `SequenceExportPinConformanceTests` when `LUNGFISH_RECAPTURE_SEQUENCE_EXPORT_PARITY=1`.

enum SequenceExportParityExpected {
    static let cases: [String: String] = [
        "fastq": #"""
>read1 sample=one
ACGTACGTAC
>read2
TTGGCCAA

"""#,
        "genbank-file": #"""
LOCUS       geneB                    30 bp    DNA  linear <DATE>
DEFINITION  Synthetic record with one gene.
FEATURES             Location/Qualifiers
     gene            4..21
                     /gene="geneB"
ORIGIN      
        1 acgtacgtac ggttaaccgg ttaaccggtt
//

"""#,
        "gz-wrapped": #"""
>wrapped one
ACGTNNACGTACGT
>wrapped-two second record
CCGGTTAAGG

"""#,
        "mixed": #"""
>chrA
ACGTACGTACGTACGTACGT
>alpha first record
ACGTACGTAC
>beta
TTGGCCAATT

"""#,
        "seq-file": #"""
>one
ACGT
>two described
TTGGCC

"""#,
        "snapshot-genbank": #"""
LOCUS       segA                     24 bp    DNA  linear <DATE>
DEFINITION  segment A of first
FEATURES             Location/Qualifiers
     gene            1..9
                     /gene="shared"
                     /note="names no chromosome"
ORIGIN      
        1 acgtacgtaa acccgggttt acgt
//
LOCUS       segB                     16 bp    DNA  linear <DATE>
FEATURES             Location/Qualifiers
     gene            1..9
                     /gene="shared"
                     /note="names no chromosome"
     cds             complement(join(1..6,10..15))
                     /gene="onlyB"
                     /product="a split protein"
ORIGIN      
        1 ttttggggcc ccaaaa
//
LOCUS       solo                     16 bp    DNA  linear <DATE>
FEATURES             Location/Qualifiers
     gene            3..8
                     /gene="soloGene"
ORIGIN      
        1 ggggaaaacc cctttt
//

"""#,
        "snapshot-mixed": #"""
LOCUS       segA                     24 bp    DNA  linear <DATE>
DEFINITION  segment A of first
FEATURES             Location/Qualifiers
     gene            1..9
                     /gene="shared"
                     /note="names no chromosome"
ORIGIN      
        1 acgtacgtaa acccgggttt acgt
//
LOCUS       segB                     16 bp    DNA  linear <DATE>
FEATURES             Location/Qualifiers
     gene            1..9
                     /gene="shared"
                     /note="names no chromosome"
     cds             complement(join(1..6,10..15))
                     /gene="onlyB"
                     /product="a split protein"
ORIGIN      
        1 ttttggggcc ccaaaa
//
LOCUS       one                       4 bp    DNA  linear <DATE>
ORIGIN      
        1 acgt
//
LOCUS       two                       6 bp    DNA  linear <DATE>
DEFINITION  described
ORIGIN      
        1 ttggcc
//
LOCUS       alpha                    10 bp    DNA  linear <DATE>
DEFINITION  first record
ORIGIN      
        1 acgtacgtac
//
LOCUS       beta                     10 bp    DNA  linear <DATE>
ORIGIN      
        1 ttggccaatt
//

"""#,
    ]
}
