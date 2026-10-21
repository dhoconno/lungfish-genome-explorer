// SequenceExportPinExpected.swift - The text of each pinned sequence export after decompression
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Written by `SequenceExportPinConformanceTests` when `LUNGFISH_RECAPTURE_SEQUENCE_EXPORT=1`.

enum SequenceExportPinExpected {
    static let cases: [String: String] = [
        "bundle": #"""
LOCUS       chrA                     20 bp    DNA  linear <DATE>
FEATURES             Location/Qualifiers
     gene            1..10
ORIGIN      
        1 acgtacgtac gtacgtacgt
//

"""#,
        "captured": #"""
>native
ACGTTGCA

"""#,
        "file": #"""
>alpha first record
ACGTACGTAC
>beta
TTGGCCAATT

"""#,
        "two": #"""
>alpha first record
ACGTACGTAC
>beta
TTGGCCAATT
>gamma
GGGGCCCCAAAATTTT

"""#,
    ]
}
