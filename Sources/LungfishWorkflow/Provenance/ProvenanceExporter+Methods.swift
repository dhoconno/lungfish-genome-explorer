// ProvenanceExporter+Methods.swift - The sentence and the key parameters of each tool in the methods export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The methods export writes one sentence for each tool. The first table here gives the sentence its
// subject, what the tool did, and the second lists the parameters worth reporting after "with", each as
// a noun phrase that reads after that word. Both match on the program token, the first word of the
// recorded tool name without its folder, so a step named `samtools sort` reaches the samtools arm.

import Foundation

extension ProvenanceExporter {
    /// The subject of a tool's methods sentence.
    func methodsOperation(tool: String, subcommands: [String]) -> String {
        let verbs = Set(subcommands.map { $0.split(separator: " ").last.map(String.init) ?? "" })
        switch Self.methodsProgram(of: tool) {
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
        case "kraken2": return "Reads were classified taxonomically"
        case "bracken": return "Taxon abundances were re-estimated"
        case "esviritu": return "Viral sequences were detected"
        case "mafft": return "Sequences were aligned"
        case "iqtree", "iqtree2", "iqtree3": return "A phylogeny was inferred"
        case "lofreq":
            // `indelqual` and `index` only prepare the alignment for `call`.
            let calls = verbs.isEmpty || verbs.contains("call") || verbs.contains("call-parallel")
            return calls ? "Variants were called" : "Processing was performed"
        case "ivar":
            // `trim` and `consensus` call no variants.
            return verbs.isEmpty || verbs.contains("variants") ? "Variants were called" : "Processing was performed"
        default: return "Processing was performed"
        }
    }

    /// The parameters worth a methods sentence, from one command, each as a
    /// noun phrase that reads after "with" (`a minimum mapping quality of
    /// 20`, `secondary alignments (flag 256) excluded`).
    func extractKeyParameters(tool: String, argv: [String]) -> [String] {
        let toolName = Self.methodsProgram(of: tool)
        // These tools take flags the general arms below read as another tool's (`-q`, `-l`), so each has
        // its own list.
        switch toolName {
        case "kraken2": return Self.kraken2Parameters(argv)
        case "bracken": return Self.brackenParameters(argv)
        case "esviritu": return Self.esVirituParameters(argv)
        default: break
        }
        var params: [String] = []
        var index = 1
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

    // MARK: - Program token

    /// The program a recorded tool name stands for: its first word without a folder, in lowercase
    /// (`samtools` for `samtools sort`, `esviritu` for `EsViritu`).
    static func methodsProgram(of toolName: String) -> String {
        guard let first = toolName.split(whereSeparator: \.isWhitespace).first else { return "" }
        return methodsExecutableName(String(first))
    }

    /// The tool a command stands for in the methods text. A recorded name that is a program and the
    /// subcommand its command ran, such as `samtools sort`, stands for the program, so the steps of one
    /// program share one sentence and one row of the version table. Any other name stays as recorded,
    /// because a description such as `pysam retained-read demux filter` is not a program and subcommand.
    static func methodsToolName(_ recorded: String, ranAs argv: [String]) -> String {
        let words = recorded.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count == 2, argv.count >= 2, words[1] == argv[1],
              methodsProgram(of: words[0]) == methodsExecutableName(argv[0]) else { return recorded }
        return words[0].split(separator: "/").last.map(String.init) ?? recorded
    }

    /// The file name of an executable's path, in lowercase.
    private static func methodsExecutableName(_ path: String) -> String {
        path.split(separator: "/").last.map { $0.lowercased() } ?? ""
    }

    // MARK: - Classifier parameters

    /// The value of the first of `flags` that `argv` gives one, as `--flag value` or `--flag=value`. The
    /// program at index 0 is not read, and a word that starts with a dash is another flag, not a value.
    private static func methodsFlagValue(_ flags: [String], in argv: [String]) -> String? {
        var index = 1
        while index < argv.count {
            for flag in flags {
                if argv[index] == flag, index + 1 < argv.count, !argv[index + 1].hasPrefix("-") {
                    return argv[index + 1]
                }
                if flag.hasPrefix("--"), argv[index].hasPrefix(flag + "=") {
                    let value = String(argv[index].dropFirst(flag.count + 1))
                    if !value.isEmpty { return value }
                }
            }
            index += 1
        }
        return nil
    }

    /// Kraken2's confidence threshold, minimum hit groups and paired-end mode.
    private static func kraken2Parameters(_ argv: [String]) -> [String] {
        var params: [String] = []
        if let confidence = methodsFlagValue(["--confidence"], in: argv), Double(confidence)?.isFinite == true {
            params.append("a confidence threshold of \(confidence)")
        }
        if let groups = methodsFlagValue(["--minimum-hit-groups"], in: argv), let count = Int(groups) {
            params.append("a minimum of \(groups) hit group\(count == 1 ? "" : "s")")
        }
        if argv.dropFirst().contains("--paired") {
            params.append("paired-end mode")
        }
        return params
    }

    /// The taxonomic level each Bracken `-l` code names.
    private static let brackenLevels: [String: String] = [
        "D": "domain", "K": "kingdom", "P": "phylum", "C": "class", "O": "order",
        "F": "family", "G": "genus", "S": "species",
    ]

    /// Bracken's read length, taxonomic level and minimum read count.
    private static func brackenParameters(_ argv: [String]) -> [String] {
        var params: [String] = []
        // The driver takes the read length as `-r`. The inner script takes the distribution file that the
        // read length chose as `-k`, and the name of that file holds it.
        let readLength = methodsFlagValue(["-r"], in: argv).flatMap { Int($0) }
            ?? methodsFlagValue(["-k"], in: argv).flatMap {
                BrackenInvocation.readLength(fromDistributionFilename: URL(fileURLWithPath: $0).lastPathComponent)
            }
        if let readLength {
            params.append("a read length of \(readLength)")
        }
        if let code = methodsFlagValue(["-l"], in: argv)?.uppercased() {
            params.append(brackenLevels[code].map { "the \(code) (\($0)) level" } ?? "the \(code) level")
        }
        if let threshold = methodsFlagValue(["-t"], in: argv), let count = Int(threshold) {
            params.append("a minimum of \(threshold) read\(count == 1 ? "" : "s")")
        }
        return params
    }

    /// EsViritu's quality filtering (`-q True`) and read layout (`-p paired`).
    private static func esVirituParameters(_ argv: [String]) -> [String] {
        var params: [String] = []
        switch methodsFlagValue(["-q"], in: argv)?.lowercased() {
        case "true": params.append("quality filtering")
        case "false": params.append("no quality filtering")
        default: break
        }
        if let layout = methodsFlagValue(["-p"], in: argv)?.lowercased(),
           ["paired", "unpaired", "interleaved"].contains(layout) {
            params.append("the \(layout) read layout")
        }
        return params
    }
}
