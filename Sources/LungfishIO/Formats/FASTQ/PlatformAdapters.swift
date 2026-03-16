// PlatformAdapters.swift - Embedded adapter and flanking sequences for all platforms
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

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

    /// M13 Forward (-20) universal primer (17-mer).
    ///
    /// Used in PacBio barcoded amplicon workflows. Sits between the barcode
    /// and the gene-specific primer on the 5' side of the amplicon.
    /// Read structure: [barcode]-[M13F]-[gene primer]-[amplicon]-[gene primer]-[M13R_RC]-[barcode_RC]
    public static let m13Forward = "GTAAAACGACGGCCAGT"

    /// M13 Reverse universal primer (17-mer).
    ///
    /// Sits between the amplicon and the barcode on the 3' side.
    public static let m13Reverse = "CAGGAAACAGCTATGAC"

    /// M13 Forward RC (reverse complement of M13 Forward).
    public static let m13ForwardRC = "ACTGGCCGTCGTTTTAC"

    /// M13 Reverse RC (reverse complement of M13 Reverse).
    public static let m13ReverseRC = "GTCATAGCTGTTTCCTG"

    /// SMRTbell adapter v3 (current, used with Revio and Sequel IIe).
    /// Already removed by CCS processing — presence in HiFi FASTQ indicates a QC issue.
    /// NOTE: This sequence is from PacBio technical notes. Verify against SMRT Link's
    /// `adapter.fasta` reference for your specific chemistry version if needed.
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

    // MARK: - SMRTbell Contamination Check

    /// All known SMRTbell adapter sequences for contamination scanning.
    public static let smrtbellAdapters: [(label: String, sequence: String)] = [
        ("SMRTbell v3", smrtbellV3),
        ("SMRTbell v2", smrtbellV2),
        ("SMRTbell v1", smrtbellV1),
    ]

    /// Scans a sequence for the presence of any SMRTbell adapter subsequence.
    ///
    /// Returns the label of the first matching adapter, or nil if none found.
    /// Uses a sliding window with the minimum adapter length for O(n) scanning.
    public static func detectSMRTbellContamination(in sequence: String) -> String? {
        let upper = sequence.uppercased()
        for (label, adapter) in smrtbellAdapters {
            // Check for at least a 16-base substring match (robust against partial adapters)
            let matchLen = min(adapter.count, 16)
            let prefix = String(adapter.prefix(matchLen))
            if upper.contains(prefix) { return label }
            // Also check reverse complement
            let rcPrefix = String(reverseComplement(adapter).prefix(matchLen))
            if upper.contains(rcPrefix) { return label }
        }
        return nil
    }

    // MARK: - Reverse Complement Helper

    /// Computes the reverse complement of a DNA/RNA sequence.
    /// Delegates to TranslationEngine for full IUPAC ambiguity code support.
    public static func reverseComplement(_ sequence: String) -> String {
        TranslationEngine.reverseComplement(sequence)
    }
}

// MARK: - Adapter QC Result

/// Result of scanning reads for residual adapter contamination.
public struct AdapterQCResult: Codable, Sendable, Equatable {
    /// Number of reads scanned.
    public let readsScanned: Int

    /// Number of reads with detected adapter contamination.
    public let contaminatedReadCount: Int

    /// Per-adapter hit counts, keyed by adapter label.
    public let hitsByAdapter: [String: Int]

    /// Contamination rate (0.0–1.0).
    public var contaminationRate: Double {
        readsScanned > 0 ? Double(contaminatedReadCount) / Double(readsScanned) : 0
    }

    /// Whether contamination is above the warning threshold (>0.1%).
    public var isWarning: Bool {
        contaminationRate > 0.001
    }

    /// Human-readable summary.
    public var summary: String {
        if contaminatedReadCount == 0 {
            return "No adapter contamination detected in \(readsScanned) reads."
        }
        let pct = String(format: "%.2f%%", contaminationRate * 100)
        let adapters = hitsByAdapter.sorted { $0.value > $1.value }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return "\(contaminatedReadCount)/\(readsScanned) reads (\(pct)) contain residual adapter sequences [\(adapters)]."
    }

    public init(readsScanned: Int, contaminatedReadCount: Int, hitsByAdapter: [String: Int]) {
        self.readsScanned = readsScanned
        self.contaminatedReadCount = contaminatedReadCount
        self.hitsByAdapter = hitsByAdapter
    }
}
