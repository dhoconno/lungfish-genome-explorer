// IQTreeOptionRules.swift - IQ-TREE option rules shared by lungfish-cli and the Build Tree dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The curated option that already sets an IQ-TREE flag (ruling C6).
public enum IQTreeCuratedOption: String, Sendable, CaseIterable {
    case alignment
    case output
    case model
    case threads
    case seed
    case ufBoot
    case shALRT
    case outgroup
    case sequenceType

    /// How `lungfish-cli tree infer iqtree` names the option in an error message.
    public var cliName: String {
        switch self {
        case .alignment: return "the input bundle argument"
        case .output: return "--output"
        case .model: return "--model"
        case .threads: return "--threads"
        case .seed: return "--seed"
        case .ufBoot: return "--bootstrap"
        case .shALRT: return "--alrt"
        case .outgroup: return "--outgroup"
        case .sequenceType: return "--sequence-type"
        }
    }

    /// How the Build Tree dialog names the control in its readiness line.
    public var dialogName: String {
        switch self {
        case .alignment: return "the alignment"
        case .output: return "Output name"
        case .model: return "Model"
        case .threads: return "Threads"
        case .seed: return "Seed"
        case .ufBoot: return "UFBoot"
        case .shALRT: return "SH-aLRT"
        case .outgroup: return "Outgroup"
        case .sequenceType: return "Sequence type"
        }
    }
}

/// IQ-TREE option rules that the CLI and the Build Tree dialog must apply the same way.
public enum IQTreeOptionRules {
    /// Every IQ-TREE 3.1.3 spelling of a flag that a curated option sets. Extra arguments that
    /// repeat one would silently override the curated value. The long forms were checked by
    /// running iqtree3 3.1.3, which accepts --msa, --aln, --model, --threads and --modelomatic
    /// and rejects --outgroup, --out-group, -model, -threads, -prefix and -seqtype.
    /// --modelomatic replaces the -m model, so it maps to the model option.
    public static let reservedFlags: [String: IQTreeCuratedOption] = [
        "-s": .alignment,
        "--msa": .alignment,
        "--aln": .alignment,
        "--prefix": .output,
        "-pre": .output,
        "-m": .model,
        "--model": .model,
        "--modelomatic": .model,
        "-T": .threads,
        "--threads": .threads,
        "-nt": .threads,
        "--seed": .seed,
        "-seed": .seed,
        "-B": .ufBoot,
        "-bb": .ufBoot,
        "--ufboot": .ufBoot,
        "--alrt": .shALRT,
        "-alrt": .shALRT,
        "-o": .outgroup,
        "-st": .sequenceType,
        "--seqtype": .sequenceType,
    ]

    /// The first reserved flag in parsed extra arguments, in argument order. A `flag=value`
    /// argument is read by the part before "=".
    public static func firstReservedFlag(in arguments: [String]) -> (flag: String, option: IQTreeCuratedOption)? {
        for argument in arguments {
            let flag = flagName(argument)
            if let option = reservedFlags[flag] {
                return (flag, option)
            }
        }
        return nil
    }

    /// True for a model that selects a model and builds no tree: MF, TESTONLY and any preset
    /// ending in ONLY. The base is the part before the first "+" (ruling C5).
    public static func isModelSelectionOnly(_ model: String) -> Bool {
        let base = model.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "+", maxSplits: 1)
            .first
            .map { $0.uppercased() } ?? ""
        return base == "MF" || base.hasSuffix("ONLY")
    }

    /// Standard bootstrap (-b or --boot) and local bootstrap (--lbp or -lbp) add support values
    /// to the node labels in an order LGE does not know.
    public static let unorderedSupportFlags: Set<String> = ["-b", "--boot", "--lbp", "-lbp"]

    public static let unorderedSupportWarning =
        "Support labels were not recorded because -b/--lbp adds values in an order LGE does not know."

    /// True when the extra arguments ask for a support test whose label order is unknown.
    public static func addsUnorderedSupport(_ arguments: [String]) -> Bool {
        arguments.contains { unorderedSupportFlags.contains(flagName($0)) }
    }

    /// The message for a codon sequence type whose in-scope columns break the reading frame,
    /// or nil when every range starts on a codon boundary and spans whole codons. Ranges are
    /// 1-based and inclusive. The whole alignment counts as one range from column 1.
    public static func codonFrameMessage(columnRanges: [ClosedRange<Int>]) -> String? {
        guard let broken = columnRanges.first(where: { ($0.lowerBound - 1) % 3 != 0 || $0.count % 3 != 0 }) else {
            return nil
        }
        let rangeText = broken.lowerBound == broken.upperBound
            ? "\(broken.lowerBound)"
            : "\(broken.lowerBound)-\(broken.upperBound)"
        return "Codon sequence types need whole codons. Each column range must start at column 1, 4, 7 and so on "
            + "and span a multiple of 3 columns, but \(rangeText) does not."
    }

    /// The 1-based ranges named by column text such as "10-40,55", in the order written. Blank
    /// text means the whole alignment. Nil when a part cannot be read or falls outside it.
    public static func columnRanges(_ text: String?, alignedLength: Int) -> [ClosedRange<Int>]? {
        let tokens = (text ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard tokens.isEmpty == false else {
            return alignedLength > 0 ? [1...alignedLength] : nil
        }
        var ranges: [ClosedRange<Int>] = []
        for token in tokens {
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 1 || bounds.count == 2,
                  let lower = bounds.first ?? nil,
                  let upper = bounds.last ?? nil,
                  lower >= 1, upper >= lower, upper <= alignedLength else {
                return nil
            }
            ranges.append(lower...upper)
        }
        return ranges
    }

    private static func flagName(_ argument: String) -> String {
        String(argument.split(separator: "=", maxSplits: 1).first ?? "")
    }
}
