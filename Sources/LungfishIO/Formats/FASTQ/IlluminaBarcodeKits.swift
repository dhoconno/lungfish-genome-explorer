// IlluminaBarcodeKits.swift - Built-in barcode kit definitions for all platforms
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Barcode Kit Registry

/// Registry of built-in and custom barcode kits for demultiplexing.
public enum BarcodeKitRegistry {

    /// Returns all built-in barcode kit definitions.
    public static func builtinKits() -> [BarcodeKitDefinition] {
        [
            truseqSingleA,
            truseqSingleB,
            truseqHTDual,
            nexteraXTv2,
            idtUDIndexes,
            fluidigmAccessArray,
            pacbioSequel16V3,
            pacbioSequel96V2,
            pacbioSequel384V1,
            m13UniversalPrimers,
            ontNativeBarcoding12NBD104,
            ontNativeBarcoding12NBD114,
            ontNativeBarcoding24,
            ontNativeBarcoding96,
            ontPCRBarcoding96,
            ontRapidBarcoding12,
            ontRapidBarcoding24,
            ontRapidBarcoding96,
            ont16SBarcoding24,
            ont16SRapidAmplicon24,
        ]
    }

    /// Looks up a built-in kit by ID.
    public static func kit(byID id: String) -> BarcodeKitDefinition? {
        builtinKits().first { $0.id == id }
    }

    /// Loads a custom barcode kit from a delimited text file.
    ///
    /// CSV, TSV, or whitespace-delimited format (header optional):
    /// ```
    /// id,i7_sequence[,i5_sequence][,sample_name]
    /// A01,ATCACG
    /// FLD0001    GTATCGTCGT
    /// A02,CGATGT,,Sample-42
    /// ```
    public static func loadCustomKit(
        from url: URL,
        name: String
    ) throws -> BarcodeKitDefinition {
        let content = try String(contentsOf: url, encoding: .utf8)
        let barcodes = try parseDelimitedBarcodeRecords(content)
        let isDualIndexed = barcodes.contains { $0.i5Sequence != nil }

        let sanitizedID = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }

        return BarcodeKitDefinition(
            id: "custom-\(sanitizedID)",
            displayName: name,
            vendor: "custom",
            isDualIndexed: isDualIndexed,
            pairingMode: isDualIndexed ? .fixedDual : .singleEnd,
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
        for kit: BarcodeKitDefinition,
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
        case .bothEnds:
            return "^\(sequence)"  // For single-end generation, treat as 5' anchored.
        }
    }

    /// Column roles of a custom barcode definition.
    ///
    /// Without a header the columns are positional:
    /// `id,sequence[,secondary_sequence][,sample_name]`. A header line may
    /// instead name the columns, so `id,sequence,sample_name` puts sample
    /// names in the third column. Sequence columns must hold nucleotide
    /// letters; a non-sequence value in a sequence column is reported with
    /// the two accepted layouts rather than handed to cutadapt.
    struct BarcodeDefinitionLayout: Equatable {
        var idColumn = 0
        var sequenceColumn = 1
        var secondaryColumn: Int? = 2
        var sampleColumn: Int? = 3

        static let positional = BarcodeDefinitionLayout()
    }

    static let secondarySequenceHeaders: Set<String> = [
        "secondary_sequence", "secondary", "i5_sequence", "i5", "i5_index", "index2", "index_2",
        "reverse_sequence", "reverse", "barcode_2", "barcode2", "sequence_2", "sequence2",
    ]

    static let sampleNameHeaders: Set<String> = [
        "sample_name", "sample", "sample_id", "sampleid", "samplename", "name", "sample_label", "label",
    ]

    private static let nucleotideLetters: Set<Character> = Set("ACGTUNRYSWKMBDHV")

    static func isNucleotideSequence(_ value: String) -> Bool {
        !value.isEmpty && value.uppercased().allSatisfy { nucleotideLetters.contains($0) }
    }

    /// Maps a header line onto column roles. Columns beyond the first two are
    /// assigned by name; an unrecognised name keeps the positional role so
    /// older files with free-form headers still load.
    static func barcodeDefinitionLayout(header columns: [String]) -> BarcodeDefinitionLayout {
        var layout = BarcodeDefinitionLayout(idColumn: 0, sequenceColumn: 1, secondaryColumn: nil, sampleColumn: nil)
        for (index, column) in columns.enumerated() where index >= 2 {
            let name = normalizedHeader(column)
            if secondarySequenceHeaders.contains(name), layout.secondaryColumn == nil {
                layout.secondaryColumn = index
            } else if sampleNameHeaders.contains(name), layout.sampleColumn == nil {
                layout.sampleColumn = index
            }
        }
        let namedColumns = Set([layout.secondaryColumn, layout.sampleColumn].compactMap { $0 })
        if layout.secondaryColumn == nil, columns.count > 2, !namedColumns.contains(2) {
            layout.secondaryColumn = 2
        }
        if layout.sampleColumn == nil, columns.count > 3, !namedColumns.contains(3) {
            layout.sampleColumn = 3
        }
        return layout
    }

    private static func parseDelimitedBarcodeRecords(_ content: String) throws -> [BarcodeEntry] {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        var barcodes: [BarcodeEntry] = []
        var layout = BarcodeDefinitionLayout.positional
        var sawHeader = false
        for (lineIndex, line) in lines.enumerated() {
            let cols = splitBarcodeDefinitionLine(line)
            guard cols.count >= 2 else { continue }
            if barcodes.isEmpty, !sawHeader, isBarcodeDefinitionHeader(cols) {
                layout = barcodeDefinitionLayout(header: cols)
                sawHeader = true
                continue
            }

            func value(at column: Int?) -> String? {
                guard let column, column < cols.count, !cols[column].isEmpty else { return nil }
                return cols[column]
            }

            let rowNumber = lineIndex + 1
            let id = cols[layout.idColumn]
            // A row with an empty sequence cell is skipped, as before.
            guard let rawSequence = value(at: layout.sequenceColumn) else { continue }
            guard isNucleotideSequence(rawSequence) else {
                throw BarcodeKitLoadError.invalidSequence(row: rowNumber, id: id, value: rawSequence)
            }
            let rawSecondary = value(at: layout.secondaryColumn)
            if let rawSecondary, !isNucleotideSequence(rawSecondary) {
                if sawHeader {
                    throw BarcodeKitLoadError.invalidSecondarySequence(row: rowNumber, id: id, value: rawSecondary)
                }
                throw BarcodeKitLoadError.ambiguousThirdColumn(row: rowNumber, id: id, value: rawSecondary)
            }

            barcodes.append(BarcodeEntry(
                id: id,
                i7Sequence: rawSequence.uppercased(),
                i5Sequence: rawSecondary?.uppercased(),
                sampleName: value(at: layout.sampleColumn)
            ))
        }

        guard !barcodes.isEmpty else {
            throw BarcodeKitLoadError.noBarcodeRows
        }

        return barcodes
    }

    private static func splitBarcodeDefinitionLine(_ line: String) -> [String] {
        if line.contains(",") {
            return line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        if line.contains("\t") {
            return line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        return line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
    }

    private static func isBarcodeDefinitionHeader(_ columns: [String]) -> Bool {
        guard columns.count >= 2 else { return false }
        let first = normalizedHeader(columns[0])
        let second = normalizedHeader(columns[1])
        let idHeaders: Set<String> = ["id", "barcode_id", "barcode", "barcode_name", "index", "index_id"]
        let sequenceHeaders: Set<String> = ["sequence", "i7_sequence", "barcode_sequence", "index_sequence", "i7"]
        return idHeaders.contains(first) && sequenceHeaders.contains(second)
    }

    private static func normalizedHeader(_ header: String) -> String {
        header.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Built-In Kit Definitions

    /// TruSeq Single Index Set A (indices D701-D712).
    /// Sequences from Illumina Adapter Sequences Document (pub. 2024).
    public static let truseqSingleA = BarcodeKitDefinition(
        id: "truseq-single-a",
        displayName: "TruSeq Single Index Set A (D701-D712)",
        platform: .illumina,
        kitType: .truseq,
        barcodes: [
            BarcodeEntry(id: "D701", i7Sequence: "ATTACTCG"),
            BarcodeEntry(id: "D702", i7Sequence: "TCCGGAGA"),
            BarcodeEntry(id: "D703", i7Sequence: "CGCTCATT"),
            BarcodeEntry(id: "D704", i7Sequence: "GAGATTCC"),
            BarcodeEntry(id: "D705", i7Sequence: "ATTCAGAA"),
            BarcodeEntry(id: "D706", i7Sequence: "GAATTCGT"),
            BarcodeEntry(id: "D707", i7Sequence: "CTGAAGCT"),
            BarcodeEntry(id: "D708", i7Sequence: "TAATGCGC"),
            BarcodeEntry(id: "D709", i7Sequence: "CGGCTATG"),
            BarcodeEntry(id: "D710", i7Sequence: "TCCGCGAA"),
            BarcodeEntry(id: "D711", i7Sequence: "TCTCGCGC"),
            BarcodeEntry(id: "D712", i7Sequence: "AGCGATAG"),
        ]
    )

    /// TruSeq Single Index Set B (indices D501-D508).
    public static let truseqSingleB = BarcodeKitDefinition(
        id: "truseq-single-b",
        displayName: "TruSeq Single Index Set B (D501-D508)",
        platform: .illumina,
        kitType: .truseq,
        barcodes: [
            BarcodeEntry(id: "D501", i7Sequence: "TATAGCCT"),
            BarcodeEntry(id: "D502", i7Sequence: "ATAGAGGC"),
            BarcodeEntry(id: "D503", i7Sequence: "CCTATCCT"),
            BarcodeEntry(id: "D504", i7Sequence: "GGCTCTGA"),
            BarcodeEntry(id: "D505", i7Sequence: "AGGCGAAG"),
            BarcodeEntry(id: "D506", i7Sequence: "TAATCTTA"),
            BarcodeEntry(id: "D507", i7Sequence: "CAGGACGT"),
            BarcodeEntry(id: "D508", i7Sequence: "GTACTGAC"),
        ]
    )

    /// TruSeq HT Dual Index (i7 D701-D712 × i5 D501-D508 = 96 combinations).
    public static let truseqHTDual: BarcodeKitDefinition = {
        let i7s = truseqSingleA.barcodes
        let i5s = truseqSingleB.barcodes

        var barcodes: [BarcodeEntry] = []
        for i7 in i7s {
            for i5 in i5s {
                barcodes.append(BarcodeEntry(
                    id: "\(i7.id)-\(i5.id)",
                    i7Sequence: i7.i7Sequence,
                    i5Sequence: i5.i7Sequence  // i5 sequences stored as i7Sequence in Set B
                ))
            }
        }

        return BarcodeKitDefinition(
            id: "truseq-ht-dual",
            displayName: "TruSeq HT Dual Index (96 combinations)",
            platform: .illumina,
            kitType: .truseq,
            isDualIndexed: true,
            pairingMode: .fixedDual,
            barcodes: barcodes
        )
    }()

    /// Nextera XT Index Kit v2 (indices N701-N712 × S502-S508).
    public static let nexteraXTv2 = BarcodeKitDefinition(
        id: "nextera-xt-v2",
        displayName: "Nextera XT Index Kit v2",
        platform: .illumina,
        kitType: .nextera,
        isDualIndexed: true,
        pairingMode: .fixedDual,
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

            var barcodes: [BarcodeEntry] = []
            for (i7id, i7seq) in i7s {
                for (i5id, i5seq) in i5s {
                    barcodes.append(BarcodeEntry(
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
    public static let idtUDIndexes = BarcodeKitDefinition(
        id: "idt-ud-indexes",
        displayName: "IDT for Illumina UD Indexes (96 pairs)",
        platform: .illumina,
        kitType: .truseq,
        isDualIndexed: true,
        pairingMode: .fixedDual,
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
                BarcodeEntry(id: id, i7Sequence: i7, i5Sequence: i5)
            }
        }()
    )

    /// Fluidigm Access Array 10 bp indexes as a symmetric long-read barcode set.
    ///
    /// These are bare barcode sequences. In ONT-style both-end demultiplexing, the
    /// expected read structure is `[barcode]-[insert]-[barcode_rc]`.
    public static let fluidigmAccessArray: BarcodeKitDefinition = {
        let barcodes: [BarcodeEntry]
        do {
            barcodes = try parseDelimitedBarcodeRecords(FluidigmBarcodeData.accessArrayCSV)
        } catch {
            preconditionFailure("Bundled Fluidigm barcode data is invalid: \(error)")
        }

        return BarcodeKitDefinition(
            id: "fluidigm-access-array",
            displayName: "Fluidigm Access Array (864)",
            vendor: "fluidigm",
            platform: .oxfordNanopore,
            kitType: .fluidigmAccessArray,
            isDualIndexed: false,
            pairingMode: .symmetric,
            barcodes: barcodes
        )
    }()

    /// PacBio Sequel 16 barcodes (v3) as a combinatorial asymmetric set.
    ///
    /// Source: Pacific Biosciences "Sequel_16_Barcodes_v3.fasta".
    public static let pacbioSequel16V3: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(PacBioBarcodeData.sequel16V3FASTA)
        return BarcodeKitDefinition(
            id: "pacbio-sequel-16-v3",
            displayName: "PacBio Sequel 16 (v3)",
            vendor: "pacbio",
            platform: .pacbio,
            kitType: .pacbioM13Amplicon,
            isDualIndexed: true,
            pairingMode: .combinatorialDual,
            barcodes: barcodes
        )
    }()

    /// PacBio Sequel 96 barcodes (v2) as a combinatorial asymmetric set.
    ///
    /// Source: Pacific Biosciences "Sequel_96_barcodes_v2.fasta".
    public static let pacbioSequel96V2: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(PacBioBarcodeData.sequel96V2FASTA)
        return BarcodeKitDefinition(
            id: "pacbio-sequel-96-v2",
            displayName: "PacBio Sequel 96 (v2)",
            vendor: "pacbio",
            platform: .pacbio,
            kitType: .pacbioM13Amplicon,
            isDualIndexed: true,
            pairingMode: .combinatorialDual,
            barcodes: barcodes
        )
    }()

    /// PacBio Sequel 384 barcodes (`bc1001`-`bc1384`) as a combinatorial asymmetric set.
    ///
    /// Source: Pacific Biosciences "Sequel_384_barcodes_v1.fasta".
    public static let pacbioSequel384V1: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(PacBioBarcodeData.sequel384V1FASTA)
        return BarcodeKitDefinition(
            id: "pacbio-sequel-384-v1",
            displayName: "PacBio Sequel 384 (v1)",
            vendor: "pacbio",
            platform: .pacbio,
            kitType: .pacbioM13Amplicon,
            isDualIndexed: true,
            pairingMode: .combinatorialDual,
            barcodes: barcodes
        )
    }()

    /// M13 Universal Primers for amplicon barcoding workflows.
    ///
    /// Contains M13 Forward (-20) and M13 Reverse as adapter sequences.
    /// Used with PacBio barcoded amplicon kits where M13 universal primer tails
    /// flank the gene-specific primers. Select this kit to trim M13 primer
    /// sequences from demultiplexed reads.
    public static let m13UniversalPrimers = BarcodeKitDefinition(
        id: "m13-universal-primers",
        displayName: "M13 Universal Primers",
        vendor: "universal",
        platform: .pacbio,
        kitType: .pacbioM13Amplicon,
        isDualIndexed: false,
        pairingMode: .singleEnd,
        barcodes: [
            BarcodeEntry(id: "M13F", i7Sequence: PlatformAdapters.m13Forward),
            BarcodeEntry(id: "M13R", i7Sequence: PlatformAdapters.m13Reverse),
        ]
    )

    /// ONT Native Barcoding (NBD104, 12 barcodes).
    public static let ontNativeBarcoding12NBD104: BarcodeKitDefinition = {
        let allBarcodes = parseFASTARecords(ONTBarcodeData.nbd104Nbd114FASTA)
        let barcodes = barcodesWithNumericSuffix(in: 1...12, from: allBarcodes)
        return BarcodeKitDefinition(
            id: "ont-nbd104",
            displayName: "ONT Native Barcoding (NBD104, 12)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .nativeBarcoding,
            isDualIndexed: false,
            pairingMode: .symmetric,
            barcodes: barcodes
        )
    }()

    /// ONT Native Barcoding (NBD114, 12 barcodes).
    public static let ontNativeBarcoding12NBD114: BarcodeKitDefinition = {
        let allBarcodes = parseFASTARecords(ONTBarcodeData.nbd104Nbd114FASTA)
        let barcodes = barcodesWithNumericSuffix(in: 13...24, from: allBarcodes)
        return BarcodeKitDefinition(
            id: "ont-nbd114",
            displayName: "ONT Native Barcoding (NBD114, 12)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .nativeBarcoding,
            isDualIndexed: false,
            pairingMode: .symmetric,
            barcodes: barcodes
        )
    }()

    /// ONT Native Barcoding Expansion (NBD104/NBD114, 24 barcodes).
    public static let ontNativeBarcoding24: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(ONTBarcodeData.nbd104Nbd114FASTA)
        return BarcodeKitDefinition(
            id: "ont-nbd104-114",
            displayName: "ONT Native Barcoding (NBD104/NBD114, 24)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .nativeBarcoding,
            isDualIndexed: false,
            pairingMode: .symmetric,
            barcodes: barcodes
        )
    }()

    /// ONT PCR Barcoding Expansion (PBC096, 96 barcodes).
    public static let ontPCRBarcoding96: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(ONTBarcodeData.pbc096FASTA)
        return BarcodeKitDefinition(
            id: "ont-pbc096",
            displayName: "ONT PCR Barcoding (PBC096, 96)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .pcrBarcoding,
            isDualIndexed: false,
            pairingMode: .symmetric,
            barcodes: barcodes
        )
    }()

    /// ONT Rapid Barcoding Kit (RBK004, 12 barcodes).
    public static let ontRapidBarcoding12: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(ONTBarcodeData.rbk004FASTA)
        return BarcodeKitDefinition(
            id: "ont-rbk004",
            displayName: "ONT Rapid Barcoding (RBK004, 12)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .rapidBarcoding,
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: barcodes
        )
    }()

    /// ONT Native Barcoding 96 (SQK-NBD114-96, V14).
    /// Also compatible with SQK-MLK114-96-XL and SQK-HTB114-96.
    public static let ontNativeBarcoding96: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(ONTBarcodeData.nativeBarcoding96FASTA)
        return BarcodeKitDefinition(
            id: "ont-nbd114-96",
            displayName: "ONT Native Barcoding V14 (SQK-NBD114-96, 96)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .nativeBarcoding,
            isDualIndexed: false,
            pairingMode: .symmetric,
            barcodes: barcodes
        )
    }()

    /// ONT Rapid Barcoding 24 (SQK-RBK114-24, V14).
    /// Uses BC01-BC24 sequences (same as PCR barcoding).
    public static let ontRapidBarcoding24: BarcodeKitDefinition = {
        let allBarcodes = parseFASTARecords(ONTBarcodeData.bc96FASTA)
        let barcodes = barcodesWithNumericSuffix(in: 1...24, from: allBarcodes)
        return BarcodeKitDefinition(
            id: "ont-rbk114-24",
            displayName: "ONT Rapid Barcoding V14 (SQK-RBK114-24, 24)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .rapidBarcoding,
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: barcodes
        )
    }()

    /// ONT Rapid Barcoding 96 (SQK-RBK114-96, V14).
    /// Uses BC01-BC96 with 6 variant substitutions at positions 26, 39, 40, 48, 54, 60.
    public static let ontRapidBarcoding96: BarcodeKitDefinition = {
        let baseBarcodes = parseFASTARecords(ONTBarcodeData.bc96FASTA)
        let variants = parseFASTARecords(ONTBarcodeData.rbk114_96VariantFASTA)
        let variantMap = Dictionary(uniqueKeysWithValues: variants.map { ($0.id, $0) })

        // Build the RBK114-96 arrangement: BC01-96 but replace specific positions.
        let rbkSubstitutions: [Int: String] = [
            26: "RBK26", 39: "RBK39", 40: "RBK40", 48: "RBK48", 54: "RBK54", 60: "RBK60",
        ]
        var barcodes: [BarcodeEntry] = []
        for bc in baseBarcodes {
            let digits = bc.id.filter(\.isNumber)
            if let num = Int(digits), let variantID = rbkSubstitutions[num],
               let variant = variantMap[variantID] {
                barcodes.append(variant)
            } else {
                barcodes.append(bc)
            }
        }
        return BarcodeKitDefinition(
            id: "ont-rbk114-96",
            displayName: "ONT Rapid Barcoding V14 (SQK-RBK114-96, 96)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .rapidBarcoding,
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: barcodes
        )
    }()

    /// ONT 16S Barcoding 24 (SQK-16S114-24, V14).
    /// Uses BC01-BC24 sequences with 16S-specific flanking regions.
    public static let ont16SBarcoding24: BarcodeKitDefinition = {
        let allBarcodes = parseFASTARecords(ONTBarcodeData.bc96FASTA)
        let barcodes = barcodesWithNumericSuffix(in: 1...24, from: allBarcodes)
        return BarcodeKitDefinition(
            id: "ont-16s114-24",
            displayName: "ONT 16S Barcoding V14 (SQK-16S114-24, 24)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .sixteenS,
            isDualIndexed: false,
            pairingMode: .symmetric,
            barcodes: barcodes
        )
    }()

    /// ONT 16S Rapid Amplicon Barcoding (RAB204/RAB214, 24 barcodes).
    /// Legacy kit; uses BC01-BC24 sequences.
    public static let ont16SRapidAmplicon24: BarcodeKitDefinition = {
        let barcodes = parseFASTARecords(ONTBarcodeData.rab204Rab214FASTA)
        return BarcodeKitDefinition(
            id: "ont-rab204-214",
            displayName: "ONT 16S Rapid Amplicon (RAB204/RAB214, 24)",
            vendor: "oxford-nanopore",
            platform: .oxfordNanopore,
            kitType: .sixteenS,
            isDualIndexed: false,
            pairingMode: .singleEnd,
            barcodes: barcodes
        )
    }()

    private static func parseFASTARecords(_ fasta: String) -> [BarcodeEntry] {
        var parsed: [BarcodeEntry] = []
        var currentID: String?
        var sequenceLines: [String] = []

        func flushCurrent() {
            guard let currentID else { return }
            let sequence = sequenceLines.joined().trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !sequence.isEmpty else { return }
            parsed.append(BarcodeEntry(id: currentID, i7Sequence: sequence))
        }

        for rawLine in fasta.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(">") {
                flushCurrent()
                currentID = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                sequenceLines = []
            } else {
                sequenceLines.append(line)
            }
        }
        flushCurrent()
        return parsed
    }

    private static func barcodesWithNumericSuffix(
        in range: ClosedRange<Int>,
        from barcodes: [BarcodeEntry]
    ) -> [BarcodeEntry] {
        barcodes.filter { barcode in
            let digits = barcode.id.filter(\.isNumber)
            guard let value = Int(digits) else { return false }
            return range.contains(value)
        }
    }
}
