// BBToolsQualityArguments.swift - The quality flags every BBTools call that reads FASTQ states
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

/// The quality flags of a BBTools call that reads FASTQ (BIO ruling BIN-QIN, row BBTOOLS-QIN).
///
/// bbmap 40.02 runs with `qin=auto`. On a short read with a score of about Q55 or more it switches to ASCII-64 and
/// reads every later score 31 too low. The tool then stores the shifted scores and exits 0, stops with words that blame
/// the reads, or (reformat) never exits. Its called-quality cap, Q41 or Q50 by tool, also lowers every score above the
/// cap on each read it writes. Every modern platform writes Phred+33, which the BBTools usage text also says, so LGE
/// states `qin=33` on every call. It never passes the encoding LGE detects, because LGE's own detector reads a HiFi read
/// as Phred+64.
///
/// Every site that launches a BBTools tool takes its flags from this type and never from a literal. The measurements
/// are in `SCR/lanes/BBTOOLS-QIN`, taken on reads that hold every score from Q0 to Q93.
package enum BBToolsQualityArguments {
    /// `qin=33`, for a call that reads FASTQ and writes none, such as a mapper that writes alignments.
    package static let input = ["qin=33"]

    /// `qin=33 qout=33`, for a call that writes FASTQ with scores the tool computes. bbmerge is the one. It merges the
    /// overlap into new scores under its own cap of Q41, and `maxcalledquality=93` makes it throw an
    /// `ArrayIndexOutOfBoundsException` in a worker thread and write no read.
    package static let readAndWrite = ["qin=33", "qout=33"]

    /// `qin=33 qout=33 maxcalledquality=93`, for a step that passes reads through. A filter, a trim, a dedup, a
    /// subsample, an interleave, a split and a repair are such steps. Without `maxcalledquality=93` each lowers every
    /// score above Q50 to Q50. Whatever the flags, a called Q0 or Q1 comes out as Q2.
    package static let keepEveryScore = ["qin=33", "qout=33", "maxcalledquality=93"]
}
