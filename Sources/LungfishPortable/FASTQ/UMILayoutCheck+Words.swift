// UMILayoutCheck+Words.swift - The reasons of a warning or a failure and their words (Phase 5.3 lane EX-UMI,
// BIO-UMI-SHARE items 4, 5, 7 and 8 and its section Words)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension UMILayoutCheck {
    /// Fail when a name differs in any pair, when one mate file ends before the other, when no pair was read, when the
    /// motif within one mismatch is under its bar, or when distinct UMIs are under the failure bar. Warn when the exact
    /// motif is under its bar, or when distinct UMIs are under the warning bar. Each compares counts.
    static func reasons(_ counts: Counts, _ arguments: Arguments) -> [Reason] {
        let pairs = counts.pairsRead
        let (bars, motif, kit, read) = (arguments.bars, arguments.motif, arguments.kit, "Read \(arguments.umiRead)")
        let noCounts = "This sample gets no UMI counts."
        func of(_ count: Int) -> String { "\(grouped(count)) of \(grouped(pairs)) pairs read (\(percent(count, of: pairs))%)" }
        func share(_ count: Int) -> String { "\(grouped(count)) (\(percent(count, of: pairs))%)" }
        var reasons: [Reason] = []
        if counts.namesEqual < pairs {
            reasons.append(Reason(code: .namesDiffer, fails: true, words: "UMI layout check failed: read names differ between Read 1 "
                + "and Read 2 in \(grouped(pairs - counts.namesEqual)) of \(grouped(pairs)) pairs read. The two files are not mates "
                + "in the same order. Try: import the pair again from its source. \(noCounts)"))
        }
        if counts.read1Reads != counts.read2Reads {
            let whole = arguments.choice == .even
                ? "Read 1 holds \(grouped(counts.read1Reads)) reads and Read 2 holds \(grouped(counts.read2Reads))."
                : "Read 1 gave \(grouped(counts.read1Reads)) reads and Read 2 gave \(grouped(counts.read2Reads)) of the "
                    + "\(grouped(counts.pairsRequested)) pairs to read."
            reasons.append(Reason(code: .shortMate, fails: true, words: "UMI layout check failed: \(whole) The two files are not a "
                + "whole pair. \(noCounts)"))
        } else if pairs == 0 {
            reasons.append(Reason(code: .noPairRead, fails: true, words: "UMI layout check failed: Read 1 and Read 2 hold no reads, "
                + "so no pair was read. \(noCounts)"))
        }
        guard pairs > 0 else { return reasons }
        if counts.withinOneMismatch * 100 < bars.withinOneMismatchPass * pairs {
            reasons.append(Reason(code: .withinOneMismatchUnderBar, fails: true, words: "UMI layout check failed: "
                + "\(of(counts.withinOneMismatch)) start within one mismatch of \(motif), under the \(bars.withinOneMismatchPass)% "
                + "the \(kit) preset needs. These reads may come from another kit, or Read 1 and Read 2 may be swapped. Try: check "
                + "the sample sheet's kit column, and that the file named \(read) holds the UMI. \(noCounts)"))
        }
        // The cause of few distinct UMIs (item 8): few pairs carry the exact motif when the UMIs among them are distinct
        // at the warning bar, else the UMIs repeat.
        let causeIsMotif = counts.exact == 0 || counts.distinctUMIs * 100 >= bars.distinctWarn * counts.exact
        let amongExact = percent(counts.distinctUMIs, of: counts.exact)
        let bases = "the \(arguments.umiLength) bases after \(motif)"
        if counts.distinctUMIs * 100 < bars.distinctFail * pairs {
            let why = causeIsMotif
                ? ", because only \(share(counts.exact)) start with \(motif) exactly while \(share(counts.withinOneMismatch)) are "
                    + "within one mismatch. The kit's fixed sequence may differ from the preset's by one base. Try: check that the "
                    + "\(kit) preset matches the kit."
                : ". Among the \(grouped(counts.exact)) pairs with the exact motif, \(amongExact)% of UMIs are distinct, so "
                    + "\(bases) are not a random UMI. Try: check the UMI's position and length in the \(kit) preset."
            reasons.append(Reason(code: .distinctUnderFailBar, fails: true, words: "UMI layout check failed: "
                + "\(of(counts.distinctUMIs)) hold a distinct UMI, under \(bars.distinctFail)%\(why) \(noCounts)"))
        }
        if counts.exact * 100 < bars.exactWarn * pairs {
            reasons.append(Reason(code: .exactUnderBar, fails: false, words: "Warning: \(read) starts with \(motif) exactly in "
                + "\(of(counts.exact)), under \(bars.exactWarn)%. UMI extraction keeps only exact matches, so pairs with a one-base "
                + "error in the motif get no UMI and are left out of the counts. The per-sample report gives the share of the whole "
                + "run that extraction kept."))
        }
        if counts.distinctUMIs * 100 >= bars.distinctFail * pairs, counts.distinctUMIs * 100 < bars.distinctWarn * pairs {
            let why = causeIsMotif
                ? ", because only \(share(counts.exact)) start with \(motif) exactly. Among those, \(amongExact)% of UMIs are distinct."
                : ". Among the \(grouped(counts.exact)) pairs with the exact motif, \(amongExact)% of UMIs are distinct, so many "
                    + "reads share a UMI. The library may hold few molecules, or \(bases) may not be a random UMI. Check the \(kit) "
                    + "preset against the kit's read layout."
            reasons.append(Reason(code: .distinctUnderWarnBar, fails: false, words: "Warning: \(of(counts.distinctUMIs)) hold a "
                + "distinct UMI, under \(bars.distinctWarn)%\(why)"))
        }
        return reasons
    }
}
