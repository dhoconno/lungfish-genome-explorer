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
        public let sampleName: String?

        public init(
            consensusAF: Double = 0.75,
            mergeAFThreshold: Double = 0.25,
            badQualityThreshold: Int = 20,
            ignoreStrandBias: Bool = true,
            sourceLine: String = "iVar (TSV-to-VCF: Lungfish)",
            contigs: [Contig] = [],
            gffMissingNote: Bool = false,
            sampleName: String? = nil
        ) {
            self.consensusAF = consensusAF
            self.mergeAFThreshold = mergeAFThreshold
            self.badQualityThreshold = badQualityThreshold
            self.ignoreStrandBias = ignoreStrandBias
            self.sourceLine = sourceLine
            self.contigs = contigs
            self.gffMissingNote = gffMissingNote
            self.sampleName = sampleName
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
        let resolvedSampleName = options.sampleName ?? defaultSampleName(from: tsvURL)
        try writeVCF(variants: sorted, to: primaryVCFURL, options: options, sampleName: resolvedSampleName)
        if let allHaplotypesVCFURL {
            let allSorted = (merged.allHaplotypes + indels.map {
                IVarCodonMerger.MergedVariant(positions: [$0.pos], rows: [$0], kind: .single)
            }).sorted { $0.positions[0] < $1.positions[0] }
            try writeVCF(variants: allSorted, to: allHaplotypesVCFURL, options: options, sampleName: resolvedSampleName)
        }
    }

    private func defaultSampleName(from tsvURL: URL) -> String {
        // Match Python's `os.path.splitext(os.path.basename(self.file_in))[0]`:
        // strip exactly one extension off the basename.
        tsvURL.deletingPathExtension().lastPathComponent
    }

    private func writeVCF(
        variants: [IVarCodonMerger.MergedVariant],
        to url: URL,
        options: Options,
        sampleName: String
    ) throws {
        var buffer = ""
        buffer += "##fileformat=VCFv4.2\n"
        buffer += "##source=\(options.sourceLine)\n"
        for contig in options.contigs {
            buffer += "##contig=<ID=\(contig.name),length=\(contig.length)>\n"
        }
        if options.gffMissingNote {
            buffer += "##LungfishNote=GFF unavailable; codon merging skipped\n"
        }
        buffer += #"##INFO=<ID=TYPE,Number=1,Type=String,Description="Either SNP (Single Nucleotide Polymorphism), DEL (deletion) or INS (Insertion)">"# + "\n"
        buffer += #"##FILTER=<ID=PASS,Description="All filters passed">"# + "\n"
        buffer += #"##FILTER=<ID=ft,Description="Fisher's exact test of variant frequency compared to mean error rate, p-value > 0.05">"# + "\n"
        buffer += #"##FILTER=<ID=bq,Description="Bad quality variant: ALT_QUAL lower than 20">"# + "\n"
        if !options.ignoreStrandBias {
            buffer += #"##FILTER=<ID=sb,Description="Strand bias filter not passed">"# + "\n"
        }
        buffer += #"##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">"# + "\n"
        buffer += #"##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Total Depth">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_DP,Number=1,Type=Integer,Description="Depth of reference base">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_RV,Number=1,Type=Integer,Description="Depth of reference base on reverse reads">"# + "\n"
        buffer += #"##FORMAT=<ID=REF_QUAL,Number=1,Type=Integer,Description="Mean quality of reference base">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_DP,Number=1,Type=Integer,Description="Depth of alternate base">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_RV,Number=1,Type=Integer,Description="Depth of alternate base on reverse reads">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_QUAL,Number=1,Type=Integer,Description="Mean quality of alternate base">"# + "\n"
        buffer += #"##FORMAT=<ID=ALT_FREQ,Number=1,Type=Float,Description="Frequency of alternate base">"# + "\n"
        buffer += #"##FORMAT=<ID=MERGED_AF,Number=A,Type=Float,Description="Frequency of each merged variant comma separated">"# + "\n"
        buffer += #"##FORMAT=<ID=MERGED_DP,Number=A,Type=Float,Description="Total Depth of each merged variant comma separated">"# + "\n"
        buffer += "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\t\(sampleName)\n"
        for variant in variants {
            let row = variant.rows[0]
            let (refOut, altOut, typeTag) = encodeAlleles(variant: variant)
            let filterText = filterColumn(variant: variant, options: options)
            let (format, sample) = sampleFields(variant: variant)
            buffer += "\(row.region)\t\(row.pos)\t.\t\(refOut)\t\(altOut)\t.\t\(filterText)\tTYPE=\(typeTag)\t\(format)\t\(sample)\n"
        }
        try buffer.write(to: url, atomically: true, encoding: .utf8)
    }

    private func encodeAlleles(variant: IVarCodonMerger.MergedVariant) -> (ref: String, alt: String, type: String) {
        if variant.kind == .merged, variant.rows.count > 1 {
            return (
                variant.rows.map(\.ref).joined(),
                variant.rows.map(\.alt).joined(),
                "SNP"
            )
        }
        return encodeAlleles(row: variant.rows[0])
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

    private func filterColumn(variant: IVarCodonMerger.MergedVariant, options: Options) -> String {
        if variant.kind != .merged {
            return filterColumn(row: variant.rows[0], options: options)
        }

        var codes: [String] = []
        for row in variant.rows {
            let rowFilter = filterColumn(row: row, options: options)
            guard rowFilter != "PASS" else { continue }
            for code in rowFilter.split(separator: ";").map(String.init) where !codes.contains(code) {
                codes.append(code)
            }
        }
        return codes.isEmpty ? "PASS" : codes.joined(separator: ";")
    }

    private func sampleFields(variant: IVarCodonMerger.MergedVariant) -> (format: String, sample: String) {
        let row = variant.rows[0]
        var format = "GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ"
        var altFreq = formatAF(row.altFreq)
        var suffix = ""

        if variant.kind == .merged, variant.rows.count > 1 {
            let mergedAF = variant.rows.map { formatAF($0.altFreq) }.joined(separator: ",")
            let mergedDP = variant.rows.map { String($0.altDP) }.joined(separator: ",")
            altFreq = formatAF(variant.rows.map(\.altFreq).min() ?? row.altFreq)
            format += ":MERGED_AF:MERGED_DP"
            suffix = ":\(mergedAF):\(mergedDP)"
        }

        let sample = "1:\(row.totalDP):\(row.refDP):\(row.refRV):\(row.refQual):\(row.altDP):\(row.altRV):\(row.altQual):\(altFreq)\(suffix)"
        return (format, sample)
    }

    private func filterColumn(row: IVarTSVRow, options: Options) -> String {
        // Python's order in apply_filters: [ivar_filter, stb_filter, bad_quality_filter]
        // joined with ";" -> "ft;sb;bq" when all three apply.
        var codes: [String] = []
        if !row.pass {
            codes.append("ft")
        }
        if !options.ignoreStrandBias {
            // scipy.stats.fisher_exact([[REF_DP-REF_RV, REF_RV],
            //                           [ALT_DP-ALT_RV, ALT_RV]],
            //                          alternative="greater")
            let refForward = max(0, row.refDP - row.refRV)
            let refReverse = row.refRV
            let altForward = max(0, row.altDP - row.altRV)
            let altReverse = row.altRV
            let p = FisherExactTest.oneSidedGreaterPValue(
                a: refForward, b: refReverse, c: altForward, d: altReverse
            )
            if p < 0.05 { codes.append("sb") }
        }
        if row.altQual < options.badQualityThreshold {
            codes.append("bq")
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
