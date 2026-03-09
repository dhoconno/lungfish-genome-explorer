// IlluminaBarcodeKits.swift - Built-in Illumina barcode kit definitions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Illumina Barcode Definition

/// A barcode kit definition for demultiplexing, supporting single- and dual-indexed kits.
public struct IlluminaBarcodeDefinition: Codable, Sendable, Equatable, Identifiable {
    /// Unique identifier (e.g., "truseq-single-a").
    public let id: String

    /// Human-readable name (e.g., "TruSeq Single Index Set A").
    public let displayName: String

    /// Vendor name.
    public let vendor: String

    /// Whether this kit uses dual indexing (i5 + i7).
    public let isDualIndexed: Bool

    /// Individual barcode entries.
    public let barcodes: [IlluminaBarcode]

    public init(
        id: String,
        displayName: String,
        vendor: String = "illumina",
        isDualIndexed: Bool = false,
        barcodes: [IlluminaBarcode]
    ) {
        self.id = id
        self.displayName = displayName
        self.vendor = vendor
        self.isDualIndexed = isDualIndexed
        self.barcodes = barcodes
    }
}

/// A single barcode entry with index sequences.
public struct IlluminaBarcode: Codable, Sendable, Equatable {
    /// Barcode ID (e.g., "D701", "N501", "A01").
    public let id: String

    /// i7 index sequence (5'-to-3').
    public let i7Sequence: String

    /// i5 index sequence (5'-to-3'). Nil for single-indexed kits.
    public let i5Sequence: String?

    /// Optional user-assigned sample name.
    public var sampleName: String?

    public init(
        id: String,
        i7Sequence: String,
        i5Sequence: String? = nil,
        sampleName: String? = nil
    ) {
        self.id = id
        self.i7Sequence = i7Sequence
        self.i5Sequence = i5Sequence
        self.sampleName = sampleName
    }
}

// MARK: - Barcode Location

/// Where barcodes are located within reads, affecting cutadapt adapter specification.
public enum BarcodeLocation: String, Codable, Sendable, CaseIterable {
    /// Barcode at the 5' (start) of the read. Uses cutadapt `-g ^SEQUENCE`.
    case fivePrime

    /// Barcode at the 3' (end) of the read. Uses cutadapt `-a SEQUENCE$`.
    case threePrime

    /// Barcode may be anywhere in the read. Uses cutadapt `-b SEQUENCE`.
    case anywhere
}

// MARK: - Illumina Adapter Flanking Sequences

/// Standard Illumina adapter sequences flanking the index for improved matching specificity.
///
/// For TruSeq/Nextera kits, the i7 index sits within the P7 adapter:
/// `...GATCGGAAGAGCACACGTCTGAACTCCAGTCAC[i7_INDEX]ATCTCGTATGCCGTCTTCTGCTTG`
///
/// Including flanking context reduces false positive barcode matches in long reads (ONT).
public enum IlluminaAdapterContext {
    /// 15 bp upstream of the i7 index in the TruSeq/Nextera P7 adapter.
    public static let i7Upstream = "AACTCCAGTCAC"

    /// 15 bp downstream of the i7 index in the TruSeq/Nextera P7 adapter.
    public static let i7Downstream = "ATCTCGTATGCC"

    /// 12 bp upstream of the i5 index in the TruSeq P5 adapter.
    public static let i5Upstream = "AGATCGGAAGAG"

    /// 12 bp downstream of the i5 index in the TruSeq P5 adapter.
    public static let i5Downstream = "GTGTAGATCTCG"

    /// Wraps a barcode sequence with flanking adapter context for improved specificity.
    public static func withContext(
        sequence: String,
        upstream: String,
        downstream: String
    ) -> String {
        "\(upstream)\(sequence)\(downstream)"
    }
}

// MARK: - Barcode Kit Registry

/// Registry of built-in and custom barcode kits for demultiplexing.
public enum IlluminaBarcodeKitRegistry {

    /// Returns all built-in barcode kit definitions.
    public static func builtinKits() -> [IlluminaBarcodeDefinition] {
        [truseqSingleA, truseqSingleB, truseqHTDual, nexteraXTv2, idtUDIndexes]
    }

    /// Looks up a built-in kit by ID.
    public static func kit(byID id: String) -> IlluminaBarcodeDefinition? {
        builtinKits().first { $0.id == id }
    }

    /// Loads a custom barcode kit from a CSV file.
    ///
    /// CSV format (header optional):
    /// ```
    /// id,i7_sequence[,i5_sequence][,sample_name]
    /// A01,ATCACG
    /// A02,CGATGT,,Sample-42
    /// ```
    public static func loadCustomKit(
        from url: URL,
        name: String
    ) throws -> IlluminaBarcodeDefinition {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var barcodes: [IlluminaBarcode] = []
        var isDualIndexed = false

        for line in lines {
            let cols = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2 else { continue }

            // Skip header row
            if cols[0].lowercased() == "id" || cols[0].lowercased() == "barcode_id" { continue }

            let id = cols[0]
            let i7 = cols[1].uppercased()
            let i5: String? = cols.count > 2 && !cols[2].isEmpty ? cols[2].uppercased() : nil
            let sample: String? = cols.count > 3 && !cols[3].isEmpty ? cols[3] : nil

            if i5 != nil { isDualIndexed = true }

            barcodes.append(IlluminaBarcode(
                id: id,
                i7Sequence: i7,
                i5Sequence: i5,
                sampleName: sample
            ))
        }

        let sanitizedID = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        return IlluminaBarcodeDefinition(
            id: "custom-\(sanitizedID)",
            displayName: name,
            vendor: "custom",
            isDualIndexed: isDualIndexed,
            barcodes: barcodes
        )
    }

    /// Generates cutadapt-compatible adapter FASTA for demultiplexing.
    ///
    /// For single-indexed kits, produces entries like:
    /// ```
    /// >A01
    /// ^ATCACG
    /// ```
    ///
    /// When `includeAdapterContext` is true, wraps barcode sequences with flanking
    /// Illumina adapter context for improved specificity in long reads (ONT):
    /// ```
    /// >A01
    /// AACTCCAGTCACATCACGATCTCGTATGCC
    /// ```
    ///
    /// For dual-indexed kits, produces separate i7 and i5 FASTA files
    /// for use with `--pair-adapters`.
    ///
    /// - Parameters:
    ///   - kit: The barcode kit definition.
    ///   - outputURL: URL for the primary (i7) adapter FASTA file.
    ///   - location: Where barcodes are expected in the read.
    ///   - includeAdapterContext: Whether to include flanking adapter sequences
    ///     around the barcode for improved specificity. Default true.
    /// - Returns: URL of the i5 FASTA file if dual-indexed, otherwise nil.
    @discardableResult
    public static func generateCutadaptFASTA(
        for kit: IlluminaBarcodeDefinition,
        to outputURL: URL,
        location: BarcodeLocation = .fivePrime,
        includeAdapterContext: Bool = true
    ) throws -> URL? {
        var i7Lines: [String] = []
        var i5Lines: [String] = []

        for barcode in kit.barcodes {
            let rawI7 = includeAdapterContext
                ? IlluminaAdapterContext.withContext(
                    sequence: barcode.i7Sequence,
                    upstream: IlluminaAdapterContext.i7Upstream,
                    downstream: IlluminaAdapterContext.i7Downstream
                )
                : barcode.i7Sequence
            let seq = formatSequenceForCutadapt(rawI7, location: location)
            i7Lines.append(">\(barcode.id)")
            i7Lines.append(seq)

            if let i5Seq = barcode.i5Sequence {
                let rawI5 = includeAdapterContext
                    ? IlluminaAdapterContext.withContext(
                        sequence: i5Seq,
                        upstream: IlluminaAdapterContext.i5Upstream,
                        downstream: IlluminaAdapterContext.i5Downstream
                    )
                    : i5Seq
                let i5Formatted = formatSequenceForCutadapt(rawI5, location: location)
                i5Lines.append(">\(barcode.id)")
                i5Lines.append(i5Formatted)
            }
        }

        let i7Content = i7Lines.joined(separator: "\n") + "\n"
        try i7Content.write(to: outputURL, atomically: true, encoding: .utf8)

        if kit.isDualIndexed && !i5Lines.isEmpty {
            let i5URL = outputURL.deletingPathExtension()
                .appendingPathExtension("i5")
                .appendingPathExtension("fasta")
            let i5Content = i5Lines.joined(separator: "\n") + "\n"
            try i5Content.write(to: i5URL, atomically: true, encoding: .utf8)
            return i5URL
        }

        return nil
    }

    // MARK: - Private Helpers

    private static func formatSequenceForCutadapt(
        _ sequence: String,
        location: BarcodeLocation
    ) -> String {
        switch location {
        case .fivePrime:
            return "^\(sequence)"  // Anchored to 5' end
        case .threePrime:
            return "\(sequence)$"  // Anchored to 3' end
        case .anywhere:
            return sequence         // Unanchored
        }
    }

    // MARK: - Built-In Kit Definitions

    /// TruSeq Single Index Set A (indices D701-D712).
    /// Sequences from Illumina Adapter Sequences Document (pub. 2024).
    public static let truseqSingleA = IlluminaBarcodeDefinition(
        id: "truseq-single-a",
        displayName: "TruSeq Single Index Set A (D701-D712)",
        barcodes: [
            IlluminaBarcode(id: "D701", i7Sequence: "ATTACTCG"),
            IlluminaBarcode(id: "D702", i7Sequence: "TCCGGAGA"),
            IlluminaBarcode(id: "D703", i7Sequence: "CGCTCATT"),
            IlluminaBarcode(id: "D704", i7Sequence: "GAGATTCC"),
            IlluminaBarcode(id: "D705", i7Sequence: "ATTCAGAA"),
            IlluminaBarcode(id: "D706", i7Sequence: "GAATTCGT"),
            IlluminaBarcode(id: "D707", i7Sequence: "CTGAAGCT"),
            IlluminaBarcode(id: "D708", i7Sequence: "TAATGCGC"),
            IlluminaBarcode(id: "D709", i7Sequence: "CGGCTATG"),
            IlluminaBarcode(id: "D710", i7Sequence: "TCCGCGAA"),
            IlluminaBarcode(id: "D711", i7Sequence: "TCTCGCGC"),
            IlluminaBarcode(id: "D712", i7Sequence: "AGCGATAG"),
        ]
    )

    /// TruSeq Single Index Set B (indices D501-D508).
    public static let truseqSingleB = IlluminaBarcodeDefinition(
        id: "truseq-single-b",
        displayName: "TruSeq Single Index Set B (D501-D508)",
        barcodes: [
            IlluminaBarcode(id: "D501", i7Sequence: "TATAGCCT"),
            IlluminaBarcode(id: "D502", i7Sequence: "ATAGAGGC"),
            IlluminaBarcode(id: "D503", i7Sequence: "CCTATCCT"),
            IlluminaBarcode(id: "D504", i7Sequence: "GGCTCTGA"),
            IlluminaBarcode(id: "D505", i7Sequence: "AGGCGAAG"),
            IlluminaBarcode(id: "D506", i7Sequence: "TAATCTTA"),
            IlluminaBarcode(id: "D507", i7Sequence: "CAGGACGT"),
            IlluminaBarcode(id: "D508", i7Sequence: "GTACTGAC"),
        ]
    )

    /// TruSeq HT Dual Index (i7 D701-D712 × i5 D501-D508 = 96 combinations).
    public static let truseqHTDual: IlluminaBarcodeDefinition = {
        let i7s = truseqSingleA.barcodes
        let i5s = truseqSingleB.barcodes

        var barcodes: [IlluminaBarcode] = []
        for i7 in i7s {
            for i5 in i5s {
                barcodes.append(IlluminaBarcode(
                    id: "\(i7.id)-\(i5.id)",
                    i7Sequence: i7.i7Sequence,
                    i5Sequence: i5.i7Sequence  // i5 sequences stored as i7Sequence in Set B
                ))
            }
        }

        return IlluminaBarcodeDefinition(
            id: "truseq-ht-dual",
            displayName: "TruSeq HT Dual Index (96 combinations)",
            isDualIndexed: true,
            barcodes: barcodes
        )
    }()

    /// Nextera XT Index Kit v2 (indices N701-N712 × S502-S508).
    public static let nexteraXTv2 = IlluminaBarcodeDefinition(
        id: "nextera-xt-v2",
        displayName: "Nextera XT Index Kit v2",
        isDualIndexed: true,
        barcodes: {
            let i7s: [(String, String)] = [
                ("N701", "TAAGGCGA"), ("N702", "CGTACTAG"),
                ("N703", "AGGCAGAA"), ("N704", "TCCTGAGC"),
                ("N705", "GGACTCCT"), ("N706", "TAGGCATG"),
                ("N707", "CTCTCTAC"), ("N708", "CAGAGAGG"),
                ("N709", "GCTACGCT"), ("N710", "CGAGGCTG"),
                ("N711", "AAGAGGCA"), ("N712", "GTAGAGGA"),
            ]
            let i5s: [(String, String)] = [
                ("S502", "CTCTCTAT"), ("S503", "TATCCTCT"),
                ("S504", "AGAGTAGA"), ("S505", "GTAAGGAG"),
                ("S506", "ACTGCATA"),
                ("S507", "AAGGAGTA"), ("S508", "CTAAGCCT"),
            ]

            var barcodes: [IlluminaBarcode] = []
            for (i7id, i7seq) in i7s {
                for (i5id, i5seq) in i5s {
                    barcodes.append(IlluminaBarcode(
                        id: "\(i7id)-\(i5id)",
                        i7Sequence: i7seq,
                        i5Sequence: i5seq
                    ))
                }
            }
            return barcodes
        }()
    )

    /// IDT for Illumina UD Indexes (96 unique dual pairs).
    public static let idtUDIndexes = IlluminaBarcodeDefinition(
        id: "idt-ud-indexes",
        displayName: "IDT for Illumina UD Indexes (96 pairs)",
        isDualIndexed: true,
        barcodes: {
            // Representative subset — first 24 pairs (A01-A24).
            // Full kit has 96 unique pairs.
            let pairs: [(String, String, String)] = [
                ("A01", "GAACATAC", "AACTGTAG"),
                ("A02", "ACGTGACT", "CACTATCG"),
                ("A03", "CATTCGGT", "GTAACTGC"),
                ("A04", "GCATCTCC", "TGGACTTG"),
                ("A05", "TGAGCTGT", "AGCGTGTT"),
                ("A06", "CTTGGATG", "CTAGGAAC"),
                ("A07", "AGCAGATG", "GATCAGGT"),
                ("A08", "TAACGAGG", "TGACGTCG"),
                ("A09", "GCTACTCT", "AACTGTAG"),
                ("A10", "CCAGTTGA", "CACTATCG"),
                ("A11", "TTGCAGAC", "GTAACTGC"),
                ("A12", "GACGATCT", "TGGACTTG"),
                ("A13", "AGTCAGGA", "AGCGTGTT"),
                ("A14", "TGTCGGAT", "CTAGGAAC"),
                ("A15", "CATACTTG", "GATCAGGT"),
                ("A16", "GCTTCACA", "TGACGTCG"),
                ("A17", "TCGTCTGA", "AACTGTAG"),
                ("A18", "GAGACGAT", "CACTATCG"),
                ("A19", "ATCCAGAG", "GTAACTGC"),
                ("A20", "CGATCAGT", "TGGACTTG"),
                ("A21", "TGCTTGCT", "AGCGTGTT"),
                ("A22", "ACTCGATG", "CTAGGAAC"),
                ("A23", "GTCGAATG", "GATCAGGT"),
                ("A24", "CAGTCCAA", "TGACGTCG"),
            ]

            return pairs.map { id, i7, i5 in
                IlluminaBarcode(id: id, i7Sequence: i7, i5Sequence: i5)
            }
        }()
    )
}
