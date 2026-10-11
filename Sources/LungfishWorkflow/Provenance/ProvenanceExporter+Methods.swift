// ProvenanceExporter+Methods.swift - The sentence and the key parameters of each tool in the methods export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The methods export writes one sentence for each tool. The first table here gives the sentence its
// subject, what the tool did, and the second lists the parameters worth reporting after "with", each as
// a noun phrase that reads after that word.

import Foundation

extension ProvenanceExporter {
    /// The subject of a tool's methods sentence.
    func methodsOperation(tool: String, subcommands: [String]) -> String {
        let verbs = Set(subcommands.map { $0.split(separator: " ").last.map(String.init) ?? "" })
        switch tool.lowercased() {
        case "bcftools":
            if verbs.contains("mpileup") || verbs.contains("call") {
                return verbs.contains("view") || verbs.contains("filter")
                    ? "Variants were called and filtered"
                    : "Variants were called"
            }
            return "Variant files were processed"
        case "samtools":
            if verbs.contains("sort") || verbs.contains("index") { return "Alignments were filtered, sorted and indexed" }
            if verbs.contains("faidx") { return "The reference was indexed" }
            return "Alignments were processed"
        case "bgzip": return "Files were block-compressed"
        case "tabix": return "Compressed files were indexed"
        case "bedtobigbed": return "BED files were converted to BigBed"
        case "bedgraphtobigwig": return "Signal tracks were converted to BigWig"
        case "fastp": return "Reads were quality-filtered and trimmed"
        case "fastqc": return "Read quality was assessed"
        case "multiqc": return "Quality reports were aggregated"
        case "bwa", "bwa-mem2": return "Reads were aligned"
        case "minimap2": return "Reads were mapped to the reference"
        case "spades", "spades.py": return "Reads were assembled de novo"
        case "seqkit": return "Sequences were summarized"
        case "vsearch": return "Sequences were clustered"
        case "cutadapt": return "Adapters were trimmed"
        case "bbduk.sh", "bbduk": return "Reads were quality-filtered and adapters removed"
        case "bbmerge.sh", "bbmerge": return "Paired reads were merged"
        case "clumpify.sh", "clumpify": return "Reads were clumped and deduplicated"
        case "pigz", "gzip": return "Files were compressed"
        default: return "Processing was performed"
        }
    }

    /// The parameters worth a methods sentence, from one command, each as a
    /// noun phrase that reads after "with" (`a minimum mapping quality of
    /// 20`, `secondary alignments (flag 256) excluded`).
    func extractKeyParameters(tool: String, argv: [String]) -> [String] {
        var params: [String] = []
        var index = 1
        let toolName = tool.lowercased()
        while index < argv.count {
            let arg = argv[index]
            let next: String? = index + 1 < argv.count ? argv[index + 1] : nil
            defer { index += 1 }
            guard arg.hasPrefix("-") else { continue }
            switch arg {
            case "-q", "--qualified_quality_phred":
                if toolName == "samtools", let next { params.append("a minimum mapping quality of \(next)") }
                else if let next { params.append("a minimum quality score of \(next)") }
            case "-l", "--length_required":
                if let next { params.append("a minimum length of \(next) bp") }
            case "--memory":
                if let next { params.append("\(next) GB of memory") }
            case "--ploidy":
                if let next { params.append("a ploidy of \(next)") }
            case "-x":
                if toolName == "minimap2", let next { params.append("the \(next) preset") }
            case "-F":
                if toolName == "samtools", let next { params.append(ProvenanceMethodsPhrasing.excludedFlags(next)) }
            case "-f":
                if toolName == "samtools", let next, Int(next) != nil {
                    params.append(ProvenanceMethodsPhrasing.requiredFlags(next))
                }
            case "-i", "--include":
                if toolName == "bcftools", let next { params.append(contentsOf: bcftoolsFilterParameters(next)) }
            case "--isolate", "--meta", "--plasmid", "--rna":
                params.append("\(arg.dropFirst(2)) mode")
            default:
                break
            }
        }
        return params
    }

    /// `(FORMAT/AD[0:1])/(FORMAT/AD[0:0]+FORMAT/AD[0:1])>=0.05 && FORMAT/DP>=10`
    /// as the thresholds a reader wants.
    func bcftoolsFilterParameters(_ expression: String) -> [String] {
        var params: [String] = []
        let clauses = expression.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        for clause in clauses {
            guard let range = clause.range(of: ">=") else { continue }
            let value = String(clause[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let subject = String(clause[..<range.lowerBound])
            if subject.contains("AD[0:1]") && subject.contains("/") {
                params.append("a minimum allele frequency of \(value)")
            } else if subject.contains("DP") {
                params.append("a minimum depth of \(value)")
            }
        }
        return params.isEmpty ? ["the filter expression \(expression)"] : params
    }
}
