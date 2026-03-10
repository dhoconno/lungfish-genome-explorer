// PlatformAdapters.swift - Embedded adapter and flanking sequences for all platforms
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Constant adapter sequences for all supported sequencing platforms.
///
/// These are universal/kit-level sequences that are the same for every sample.
/// Users never need to know or enter these — the app assembles them automatically
/// based on the selected platform and kit type.
public enum PlatformAdapters {

    // MARK: - ONT

    /// Y-adapter top strand (Native Barcoding kits: NBD104, NBD114, etc.).
    ///
    /// This is the constant sequence upstream of the barcode on the
    /// top strand of the Y-adapter. The user's sequence `TCGTTCAGTTACGTATT`
    /// is a substring of this adapter — it is NOT a barcode.
    public static let ontYAdapterTop = "AATGTACTTCGTTCAGTTACGTATTGCT"

    /// Y-adapter bottom strand (reverse complement of top).
    public static let ontYAdapterBottom = "AGCAATACGTAACTGAACGAAGT"

    /// Outer flank between Y-adapter and barcode on the 5' side (native barcoding).
    /// Part of the ONT adapter construct, NOT a user primer.
    public static let ontNativeOuterFlank5 = "AAGGTTAA"

    /// Outer flank between barcode_RC and Y-adapter on the 3' side (RC of outer flank 5').
    public static let ontNativeOuterFlank3 = "TTAACCTT"

    /// Native barcode 5' internal flank (constant across all native barcodes).
    /// Sits between the barcode and the insert on the 5' side.
    /// Typically a PCR primer start — used for primer trimming, NOT demultiplexing.
    public static let ontNativeBarcodeFlank5 = "CAGCACCT"

    /// Native barcode 3' internal flank (reverse complement of 5' flank).
    /// Sits between the insert and the barcode on the 3' side.
    public static let ontNativeBarcodeFlank3 = "AGGTGCTG"

    /// Rapid adapter (RAP-T), used in RBK, RAD, RPB kits.
    /// Includes the poly-T motor protein loading sequence.
    public static let ontRapidAdapter =
        "GGCGTCTGCTTGGGTGTTTAACCTTTTTTTTTTAATGTACTTCGTTCAGTTACGTATTGCT"

    /// Transposase mosaic end (rapid barcoding, forward).
    public static let ontTransposaseME = "AGATGTGTATAAGAGACAG"

    /// Transposase mosaic end (reverse complement).
    public static let ontTransposaseMErc = "CTGTCTCTTATACACATCT"

    // MARK: - Illumina

    /// Universal adapter prefix (matches both TruSeq R1 and R2).
    /// Useful for quick contamination detection.
    public static let illuminaUniversal = "AGATCGGAAGAG"

    /// TruSeq Read 1 adapter (read-through contamination in R1).
    /// Also used by Element AVITI and Ultima Genomics (intentionally compatible).
    public static let truseqR1 = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA"

    /// TruSeq Read 2 adapter (read-through contamination in R2).
    public static let truseqR2 = "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT"

    /// Nextera / Illumina DNA Prep Read 1 adapter.
    public static let nexteraR1 = "CTGTCTCTTATACACATCTCCGAGCCCACGAGAC"

    /// Nextera / Illumina DNA Prep Read 2 adapter.
    public static let nexteraR2 = "CTGTCTCTTATACACATCTGACGCTGCCGACGA"

    /// TruSeq Small RNA 3' adapter.
    public static let smallRNA3 = "TGGAATTCTCGGGTGCCAAGG"

    /// TruSeq Small RNA 5' adapter.
    public static let smallRNA5 = "GTTCAGAGTTCTACAGTCCGACGATC"

    /// P5 flow cell oligo (rarely needed for trimming, useful for QC).
    public static let illuminaP5 = "AATGATACGGCGACCACCGAGATCTACAC"

    /// P7 flow cell oligo.
    public static let illuminaP7 = "CAAGCAGAAGACGGCATACGAGAT"

    // MARK: - PacBio

    /// SMRTbell adapter v3 (current, used with Revio and Sequel IIe).
    /// Already removed by CCS processing — presence in HiFi FASTQ indicates a QC issue.
    public static let smrtbellV3 = "AAAAAAAAAAAAAAAAAATTAACGGAGGAGGAGGA"

    /// SMRTbell adapter v2.
    public static let smrtbellV2 = "AAGTCACAGCGGAACGGCGA"

    /// SMRTbell adapter v1 (legacy).
    public static let smrtbellV1 = "ATCTCTCTCTTTTCCTCCTCCTCCGTTGTTGTTGTTGAGAGAGAT"

    // MARK: - Element Biosciences (AVITI)

    // Read-through adapters are TruSeq-identical by design.
    // Use `truseqR1` / `truseqR2`.

    // MARK: - Ultima Genomics

    // Read-through adapters are TruSeq-identical by design.
    // Use `truseqR1` / `truseqR2`.

    // MARK: - MGI / DNBSEQ

    /// MGI Read 1 adapter (read-through contamination in R1).
    public static let mgiR1 = "AAGTCGGAGGCCAAGCGGTCTTAGGAAGACAA"

    /// MGI Read 2 adapter (read-through contamination in R2).
    public static let mgiR2 = "AAGTCGGATCGTAGCCATGTCGTTCTGTGAGCCAAGGAGTTG"

    // MARK: - Reverse Complement Helper

    /// Computes the reverse complement of a DNA sequence.
    public static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { complement($0) })
    }

    /// Returns the complement of a single nucleotide.
    private static func complement(_ base: Character) -> Character {
        switch base {
        case "A", "a": return "T"
        case "T", "t": return "A"
        case "C", "c": return "G"
        case "G", "g": return "C"
        case "N", "n": return "N"
        default: return base
        }
    }
}
