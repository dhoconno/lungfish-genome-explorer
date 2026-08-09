import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCPivotSample: Sendable, Equatable {
    let sample: String
    let mappedReadCount: Int?
    let totalReadCount: Int?
    let retainedPercent: Double?
}

enum FullLengthONTMHCPivotWorkbookBuilder {
    private static let canonicalLoci = [
        "MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB",
    ]

    private static let sectionSuffixOrder = [
        "-F alleles",
        "-G alleles",
        "-AG alleles",
        "-A major alleles",
        "-A minor alleles",
        "-70 alleles",
        "-L alleles",
        "-E alleles",
        "-B alleles",
        "-DRB alleles",
        "-DQA/DQB alleles",
        "-DPA/DPB alleles",
    ]

    static func buildRows(
        reportRows: [FullLengthONTMHCReportRow],
        samples: [FullLengthONTMHCPivotSample],
        orderedAlleles: [String],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[String]] {
        let pivotSamples = completeSamples(samples, with: reportRows)
        let sampleNames = pivotSamples.map(\.sample)
        let speciesPrefix = inferSpeciesPrefix(reportRows: reportRows, haplotypeAnalysis: haplotypeAnalysis)
        let countsBySampleAllele = alleleCounts(reportRows)
        let observedAlleles = Set(countsBySampleAllele.keys)
        let orderedObservedAlleles = orderedObservedAlleles(
            observedAlleles: observedAlleles,
            orderedAlleles: orderedAlleles
        )

        var rows = buildHeaderRows(
            reportRows: reportRows,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis
        )

        let sectionOrder = sectionSuffixOrder.map { speciesPrefix + $0 }
        let observedBySection = Dictionary(grouping: orderedObservedAlleles) {
            sectionLabel(for: $0, speciesPrefix: speciesPrefix)
        }

        for section in sectionOrder {
            guard let alleles = observedBySection[section], !alleles.isEmpty else { continue }
            rows.append([section, "", ""] + Array(repeating: "", count: sampleNames.count))
            for allele in alleles {
                rows.append(alleleRow(allele, sampleNames: sampleNames, countsBySampleAllele: countsBySampleAllele))
            }
        }

        for section in observedBySection.keys.sorted().filter({ !sectionOrder.contains($0) }) {
            guard let alleles = observedBySection[section], !alleles.isEmpty else { continue }
            rows.append([section, "", ""] + Array(repeating: "", count: sampleNames.count))
            for allele in alleles {
                rows.append(alleleRow(allele, sampleNames: sampleNames, countsBySampleAllele: countsBySampleAllele))
            }
        }

        return rows
    }

    static func buildHeaderRows(
        reportRows: [FullLengthONTMHCReportRow],
        samples: [FullLengthONTMHCPivotSample],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> [[String]] {
        let pivotSamples = completeSamples(samples, with: reportRows)
        let sampleNames = pivotSamples.map(\.sample)
        let callsBySampleLocus = haplotypeCallsBySampleLocus(haplotypeAnalysis)
        var rows = [
            ["Client ID", "", ""] + sampleNames,
            ["GS ID", "Total", "Average"] + sampleNames,
        ]
        let mappedCounts = pivotSamples.map(\.mappedReadCount)
        rows.append(
            ["Mapped Read Count", formatNumber(mappedCounts.compactMap { $0 }.reduce(0, +)), formatNumber(average(mappedCounts))]
            + mappedCounts.map { formatNumber($0) }
        )
        rows.append(["total_read_count", "", ""] + pivotSamples.map { formatNumber($0.totalReadCount) })
        rows.append(
            ["percent_reads_unmapped", "", ""]
            + pivotSamples.map { sample in
                sample.retainedPercent.map { formatNumber(max(0.0, min(100.0, 100.0 - $0))) } ?? ""
            }
        )
        for locus in canonicalLoci {
            for slot in 1...2 {
                rows.append(
                    ["\(locus) Haplotype \(slot)", "", ""]
                    + sampleNames.map { sample in
                        haplotypeValue(callsBySampleLocus[sample]?[locus], slot: slot) ?? ""
                    }
                )
            }
        }
        rows.append(
            ["Comments", "Subtotal", "# Obs."]
            + sampleNames.map { sample in haplotypeComments(callsBySampleLocus[sample] ?? [:]) }
        )
        return rows
    }

    private static func completeSamples(
        _ samples: [FullLengthONTMHCPivotSample],
        with reportRows: [FullLengthONTMHCReportRow]
    ) -> [FullLengthONTMHCPivotSample] {
        var result = samples
        var seen = Set(samples.map(\.sample))
        let missingSamples = Set(reportRows.map(\.sample))
            .subtracting(seen)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for sample in missingSamples {
            let sampleRows = reportRows.filter { $0.sample == sample }
            let mapped = sampleRows.reduce(0) { $0 + $1.passedUniqueReads }
            let first = sampleRows.first
            result.append(FullLengthONTMHCPivotSample(
                sample: sample,
                mappedReadCount: mapped,
                totalReadCount: first?.sampleTotalReads,
                retainedPercent: first?.sampleUniqueRetainedPercent
            ))
            seen.insert(sample)
        }
        return result
    }

    private static func alleleCounts(_ reportRows: [FullLengthONTMHCReportRow]) -> [String: [String: Int]] {
        var counts: [String: [String: Int]] = [:]
        for row in reportRows {
            counts[row.genotype, default: [:]][row.sample, default: 0] += row.passedUniqueReads
        }
        return counts
    }

    private static func orderedObservedAlleles(
        observedAlleles: Set<String>,
        orderedAlleles: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for allele in orderedAlleles where observedAlleles.contains(allele) && seen.insert(allele).inserted {
            result.append(allele)
        }
        let remaining = observedAlleles
            .filter { !seen.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        result.append(contentsOf: remaining)
        return result
    }

    private static func haplotypeCallsBySampleLocus(
        _ analysis: GenotypeHaplotypeAnalysis?
    ) -> [String: [String: GenotypeHaplotypeLocusCall]] {
        guard let analysis else { return [:] }
        var calls: [String: [String: GenotypeHaplotypeLocusCall]] = [:]
        for sample in analysis.samples {
            for call in sample.calls {
                calls[sample.sample, default: [:]][call.locus] = call
            }
        }
        return calls
    }

    private static func haplotypeValue(_ call: GenotypeHaplotypeLocusCall?, slot: Int) -> String? {
        guard let call else { return nil }
        let value = slot == 1 ? call.haplotype1 : call.haplotype2
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func haplotypeComments(_ callsByLocus: [String: GenotypeHaplotypeLocusCall]) -> String {
        let comments = callsByLocus
            .values
            .sorted { $0.locus.localizedStandardCompare($1.locus) == .orderedAscending }
            .compactMap { call -> String? in
                guard call.status != .called, call.status != .notAssayed else { return nil }
                let first = call.haplotype1.trimmingCharacters(in: .whitespacesAndNewlines)
                let second = call.haplotype2.trimmingCharacters(in: .whitespacesAndNewlines)
                let label: String
                if first.isEmpty {
                    label = second
                } else if second.isEmpty || first == second {
                    label = first
                } else {
                    label = "\(first)/\(second)"
                }
                return label.isEmpty ? "\(call.locus): \(call.status.rawValue)" : "\(call.locus): \(label)"
            }
        return comments.joined(separator: "; ")
    }

    private static func alleleRow(
        _ allele: String,
        sampleNames: [String],
        countsBySampleAllele: [String: [String: Int]]
    ) -> [String] {
        let counts = countsBySampleAllele[allele] ?? [:]
        let perSample = sampleNames.map { sample in counts[sample] ?? 0 }
        let subtotal = perSample.reduce(0, +)
        let observed = perSample.filter { $0 > 0 }.count
        return [
            allele,
            subtotal > 0 ? formatNumber(subtotal) : "",
            observed > 0 ? formatNumber(observed) : "",
        ] + perSample.map { $0 > 0 ? formatNumber($0) : "" }
    }

    private static func sectionLabel(for allele: String, speciesPrefix: String) -> String {
        let trimmed = allele.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("01_") { return speciesPrefix + "-F alleles" }
        if trimmed.hasPrefix("02_") { return speciesPrefix + "-G alleles" }
        if trimmed.hasPrefix("04_") || trimmed.hasPrefix("AG_") { return speciesPrefix + "-AG alleles" }
        if trimmed.hasPrefix("05_") { return speciesPrefix + "-A major alleles" }
        if trimmed.hasPrefix("06_") { return speciesPrefix + "-A minor alleles" }
        if trimmed.hasPrefix("07_") { return speciesPrefix + "-70 alleles" }
        if trimmed.hasPrefix("10_") { return speciesPrefix + "-L alleles" }
        if trimmed.hasPrefix("11_") || trimmed.hasPrefix("E_") { return speciesPrefix + "-E alleles" }
        if trimmed.hasPrefix("12_") || trimmed.hasPrefix("B") || trimmed.hasPrefix("I_") {
            return speciesPrefix + "-B alleles"
        }
        if trimmed.hasPrefix("13_") { return speciesPrefix + "-DRB alleles" }
        if trimmed.hasPrefix("14_") { return speciesPrefix + "-DQA/DQB alleles" }
        if trimmed.hasPrefix("15_") { return speciesPrefix + "-DPA/DPB alleles" }

        let gene = alleleGeneToken(trimmed)
        if gene == "F" { return speciesPrefix + "-F alleles" }
        if gene == "G" { return speciesPrefix + "-G alleles" }
        if gene == "AG" { return speciesPrefix + "-AG alleles" }
        if gene == "A1" { return speciesPrefix + "-A major alleles" }
        if gene.hasPrefix("A") { return speciesPrefix + "-A minor alleles" }
        if gene == "L" { return speciesPrefix + "-L alleles" }
        if gene == "E" { return speciesPrefix + "-E alleles" }
        if gene.hasPrefix("B") || gene == "I" { return speciesPrefix + "-B alleles" }
        if gene.hasPrefix("DRB") { return speciesPrefix + "-DRB alleles" }
        if gene.hasPrefix("DQA") || gene.hasPrefix("DQB") { return speciesPrefix + "-DQA/DQB alleles" }
        if gene.hasPrefix("DPA") || gene.hasPrefix("DPB") { return speciesPrefix + "-DPA/DPB alleles" }
        return "Other alleles"
    }

    private static func alleleGeneToken(_ allele: String) -> String {
        let name = allele.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? allele
        let afterSpecies = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? name
        let beforeStar = afterSpecies.split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? afterSpecies
        let beforeColon = beforeStar.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? beforeStar
        return beforeColon.uppercased()
    }

    private static func inferSpeciesPrefix(
        reportRows: [FullLengthONTMHCReportRow],
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?
    ) -> String {
        for genotype in reportRows.map(\.genotype) {
            let prefix = genotype.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if prefix.count == 4, prefix.allSatisfy(\.isLetter) {
                return prefix
            }
        }
        let speciesName = haplotypeAnalysis?.speciesName.lowercased() ?? ""
        if speciesName.contains("fascicularis") { return "Mafa" }
        if speciesName.contains("mulatta") { return "Mamu" }
        if speciesName.contains("nemestrina") { return "Mane" }
        if speciesName.contains("fuscata") { return "Mafu" }
        if speciesName.contains("tonkeana") { return "Mato" }
        if speciesName.contains("leonina") { return "Male" }
        if speciesName.contains("thibetana") { return "Math" }
        return "Mafa"
    }

    private static func average(_ values: [Int?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return Double(present.reduce(0, +)) / Double(present.count)
    }

    private static func formatNumber(_ value: Int?) -> String {
        value.map { String($0) } ?? ""
    }

    private static func formatNumber(_ value: Int) -> String {
        String(value)
    }

    private static func formatNumber(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.1f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}
