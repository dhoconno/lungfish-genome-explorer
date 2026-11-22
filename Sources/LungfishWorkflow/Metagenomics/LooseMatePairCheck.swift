// LooseMatePairCheck.swift - The record count of a loose R1 and R2 before a paired run reads them (LOOSE-PAIR-SHORT-MATE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// BIO ruling BIO-REACH, row B. fastp in nf-core/taxtriage, EsViritu's own QC and kraken2 `--paired`
/// pair two files by position, so a short R2 leaves the rest of R1 out of the run with no word. Before
/// `taxtriage run --input --input2`, `esviritu detect` or the Kraken2 classify command runs two loose
/// FASTQ files as one pair, both are read whole as the paired import reads them
/// (`FASTQPairInterleaver.verifyMateCounts(r1:r2:launcher:)`). Files that hold different numbers of
/// records, a record cut short and a gzip that does not decompress whole are refused with the
/// interleaver's words, which name the file and, for a mismatch, both files and both counts. A
/// `.lungfishfastq` bundle had its mates counted when it was imported, and a FASTA pair has no FASTQ
/// records, so neither is read again.
enum LooseMatePairCheck {

    /// The words that refuse `r1` and `r2` as one pair, or nil when they hold the same number of
    /// whole records or are not two loose FASTQ files. A cancel and a gzip that cannot start are
    /// thrown as they are.
    static func refusal(r1: URL, r2: URL) throws -> String? {
        guard isLooseFASTQ(r1), isLooseFASTQ(r2) else { return nil }
        do {
            _ = try FASTQPairInterleaver.verifyMateCounts(r1: r1, r2: r2, launcher: ToolProcessChildLauncher())
            return nil
        } catch let error as FASTQPairInterleaver.InterleaveError {
            return error.localizedDescription
        }
    }

    /// Whether `url` names a FASTQ file, plain or gzip, that exists and lies in no `.lungfishfastq`
    /// bundle. A missing file keeps the refusal its route already gives it.
    static func isLooseFASTQ(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && SequenceInputResolver.enclosingFASTQBundleURL(for: url) == nil
            && SequenceFormat.from(url: url) == .fastq
    }
}
