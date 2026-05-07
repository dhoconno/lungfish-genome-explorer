// IVarTSVToVCFConverter.swift - Convert iVar's TSV variant output to VCF 4.2
// at parity with nf-core/viralrecon's ivar_variants_to_vcf.py. Implements
// indel anchoring, codon-aware haplotype merging, and Fisher's exact strand-bias filter.

import Foundation

public struct IVarTSVToVCFConverter: Sendable {
    public struct Contig: Sendable, Equatable {
        public let name: String
        public let length: Int
        public init(name: String, length: Int) {
            self.name = name
            self.length = length
        }
    }

    public struct Options: Sendable {
        public let consensusAF: Double
        public let mergeAFThreshold: Double
        public let badQualityThreshold: Int
        public let ignoreStrandBias: Bool
        public let sourceLine: String
        public let contigs: [Contig]
        public let gffMissingNote: Bool

        public init(
            consensusAF: Double = 0.75,
            mergeAFThreshold: Double = 0.25,
            badQualityThreshold: Int = 20,
            ignoreStrandBias: Bool = true,
            sourceLine: String = "iVar (TSV-to-VCF: Lungfish)",
            contigs: [Contig] = [],
            gffMissingNote: Bool = false
        ) {
            self.consensusAF = consensusAF
            self.mergeAFThreshold = mergeAFThreshold
            self.badQualityThreshold = badQualityThreshold
            self.ignoreStrandBias = ignoreStrandBias
            self.sourceLine = sourceLine
            self.contigs = contigs
            self.gffMissingNote = gffMissingNote
        }
    }

    public enum ConverterError: Error, LocalizedError, Equatable {
        case missingHeader
        case malformedRow(line: String)

        public var errorDescription: String? {
            switch self {
            case .missingHeader: return "iVar TSV is missing a header line"
            case .malformedRow(let line): return "iVar TSV row is malformed: \(line)"
            }
        }
    }

    public init() {}

    public func convert(
        tsvURL: URL,
        primaryVCFURL: URL,
        allHaplotypesVCFURL: URL?,
        options: Options
    ) throws {
        let text = try String(contentsOf: tsvURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first, header.hasPrefix("REGION\t") else {
            throw ConverterError.missingHeader
        }
        let rows: [IVarTSVRow] = try lines.dropFirst().map { line in
            guard let parsed = IVarTSVRow.parse(line: line, header: header) else {
                throw ConverterError.malformedRow(line: line)
            }
            return parsed
        }
        let merged = IVarCodonMerger.merge(
            rows: rows.filter { $0.kind == .snp },
            consensusAF: options.consensusAF,
            mergeAFThreshold: options.mergeAFThreshold
        )
        let indels = rows.filter { $0.kind != .snp }
        let consensusVariants = merged.consensus + indels.map {
            IVarCodonMerger.MergedVariant(positions: [$0.pos], rows: [$0], kind: .single)
        }
        let sorted = consensusVariants.sorted { $0.positions[0] < $1.positions[0] }
        try writeVCF(variants: sorted, to: primaryVCFURL, options: options)
        if let allHaplotypesVCFURL {
            let allSorted = (merged.allHaplotypes + indels.map {
                IVarCodonMerger.MergedVariant(positions: [$0.pos], rows: [$0], kind: .single)
            }).sorted { $0.positions[0] < $1.positions[0] }
            try writeVCF(variants: allSorted, to: allHaplotypesVCFURL, options: options)
        }
    }

    private func writeVCF(
        variants: [IVarCodonMerger.MergedVariant],
        to url: URL,
        options: Options
    ) throws {
        var buffer = ""
        buffer += "##fileformat=VCFv4.2\n"
        buffer += "##source=\(options.sourceLine)\n"
        if options.gffMissingNote {
            buffer += "##LungfishNote=GFF unavailable; codon merging skipped\n"
        }
        for contig in options.contigs {
            buffer += "##contig=<ID=\(contig.name),length=\(contig.length)>\n"
        }
        buffer += #"##INFO=<ID=TYPE,Number=1,Type=String,Description="Either SNP, INS or DEL">"# + "\n"
        buffer += #"##FILTER=<ID=PASS,Description="All filters passed">"# + "\n"
        buffer += #"##FILTER=<ID=ft,Description="iVar PASS column was FALSE">"# + "\n"
        buffer += #"##FILTER=<ID=bq,Description="ALT_QUAL below threshold">"# + "\n"
        buffer += #"##FILTER=<ID=sb,Description="Strand bias detected by Fisher exact test">"# + "\n"
        buffer += #"##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">"# + "\n"
        buffer += #"##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Total depth">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_DP,Number=1,Type=Integer,Description="Reference depth">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_RV,Number=1,Type=Integer,Description="Reference reverse-strand depth">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_QUAL,Number=1,Type=Integer,Description="Mean reference base quality">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_DP,Number=1,Type=Integer,Description="Alternate depth">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_RV,Number=1,Type=Integer,Description="Alternate reverse-strand depth">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_QUAL,Number=1,Type=Integer,Description="Mean alternate base quality">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_FREQ,Number=1,Type=Float,Description="Alternate allele frequency">"# + "\n"
        buffer += "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE\n"
        for variant in variants {
            let row = variant.rows[0]
            let (refOut, altOut, typeTag) = encodeAlleles(row: row)
            let filterText = filterColumn(row: row, options: options)
            let format = "GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ"
            let sample = "1:\(row.totalDP):\(row.refDP):\(row.refRV):\(row.refQual):\(row.altDP):\(row.altRV):\(row.altQual):\(formatAF(row.altFreq))"
            buffer += "\(row.region)\t\(row.pos)\t.\t\(refOut)\t\(altOut)\t.\t\(filterText)\tTYPE=\(typeTag)\t\(format)\t\(sample)\n"
        }
        try buffer.write(to: url, atomically: true, encoding: .utf8)
    }

    private func encodeAlleles(row: IVarTSVRow) -> (ref: String, alt: String, type: String) {
        switch row.kind {
        case .snp:
            return (row.ref, row.alt, "SNP")
        case .insertion(let inserted):
            return (row.ref, row.ref + inserted, "INS")
        case .deletion(let deleted):
            return (row.ref + deleted, row.ref, "DEL")
        }
    }

    private func filterColumn(row: IVarTSVRow, options: Options) -> String {
        var codes: [String] = []
        if !row.pass {
            codes.append("ft")
        }
        if row.altQual < options.badQualityThreshold {
            codes.append("bq")
        }
        if !options.ignoreStrandBias {
            let refForward = max(0, row.refDP - row.refRV)
            let refReverse = row.refRV
            let altForward = max(0, row.altDP - row.altRV)
            let altReverse = row.altRV
            let p = FisherExactTest.twoSidedPValue(a: refForward, b: refReverse, c: altForward, d: altReverse)
            if p < 0.05 { codes.append("sb") }
        }
        return codes.isEmpty ? "PASS" : codes.joined(separator: ";")
    }

    private func formatAF(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.1f", value)
        }
        return String(format: "%g", value)
    }
}
