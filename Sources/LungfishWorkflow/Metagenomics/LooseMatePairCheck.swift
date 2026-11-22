// LooseMatePairCheck.swift - The record counts and mate names of a loose R1 and R2 before a paired run reads them (LOOSE-PAIR-SHORT-MATE, LOOSE-PAIR-OUT-OF-STEP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// BIO ruling BIO-REACH, row B, and BIO's ruling on LOOSE-PAIR-OUT-OF-STEP. fastp in nf-core/taxtriage,
/// EsViritu's own QC and kraken2 `--paired` pair two files by position, so a short R2 leaves the rest of
/// R1 out of the run, and two files out of step join two different fragments in each pair from the first
/// slip on, with no word. Before `taxtriage run` (`--input --input2` or a samplesheet row with
/// `fastq_2`), `esviritu detect` or the Kraken2 classify command runs two loose FASTQ files as one pair,
/// both are read whole as the paired import reads them, and the names of each pair are checked
/// (`FASTQPairInterleaver.verifyMates(r1:r2:launcher:)`). Files whose mates are out of step by name are
/// refused at the first such read, with run words that name both files and both names. Files that hold
/// different numbers of records are refused with run words that name both files and both counts. A
/// record cut short and a gzip that does not decompress whole keep the reader's words. A
/// `.lungfishfastq` bundle had its mates checked when it was imported, and a FASTA pair has no FASTQ
/// records, so neither is read again.
package enum LooseMatePairCheck {

    /// The words that refuse `r1` and `r2` as one pair, or nil when every pair of records is mates by
    /// name and both files hold the same number of whole records, or when they are not two loose FASTQ
    /// files. Mates out of step take the run words of
    /// ``runOutOfStepWords(recordNumber:r1File:r1Name:r2File:r2Name:)`` and a count mismatch those of
    /// ``runMismatchWords(r1File:r1Records:r2File:r2Records:)``, because the import's words end "so
    /// nothing was written." and "Nothing was imported.". A record or a gzip that cannot be read keeps
    /// the reader's words. A cancel and a gzip that cannot start are thrown as they are. `workflow run
    /// nf-core/viralrecon` calls it from the CLI on each samplesheet row of two files (BIO-ROUTES item 3).
    package static func refusal(r1: URL, r2: URL) throws -> String? {
        guard isLooseFASTQ(r1), isLooseFASTQ(r2) else { return nil }
        do {
            _ = try FASTQPairInterleaver.verifyMates(r1: r1, r2: r2, launcher: ToolProcessChildLauncher())
            return nil
        } catch FASTQPairInterleaver.InterleaveError.mateNameMismatch(let recordNumber, let r1File, let r1Name, let r2File, let r2Name) {
            return runOutOfStepWords(recordNumber: recordNumber, r1File: r1File, r1Name: r1Name, r2File: r2File, r2Name: r2Name)
        } catch FASTQPairInterleaver.InterleaveError.mateCountMismatch(let r1File, let r1Records, let r2File, let r2Records) {
            return runMismatchWords(r1File: r1File, r1Records: r1Records, r2File: r2File, r2Records: r2Records)
        } catch let error as FASTQPairInterleaver.InterleaveError {
            return error.localizedDescription
        }
    }

    /// The words of a run refused because its two mate files hold different numbers of reads (Sol,
    /// FIX-B-decided.md row B1).
    static func runMismatchWords(r1File: String, r1Records: Int, r2File: String, r2Records: Int) -> String {
        "Paired FASTQ mates do not match. \(r1File) has \(r1Records) reads, but \(r2File) has \(r2Records). Nothing ran. Check that both files are complete or run each as single reads."
    }

    /// The words of a run refused because the names of its two mate files are out of step at read
    /// `recordNumber` (Sol, FIX-B2-decided.md row B2).
    static func runOutOfStepWords(recordNumber: Int, r1File: String, r1Name: String, r2File: String, r2Name: String) -> String {
        "Paired FASTQ mates are out of step at read \(recordNumber). \(r1File) has '\(r1Name)', but \(r2File) has '\(r2Name)'. Nothing ran. Check that both files are from the same run and neither was sorted or subsampled on its own, or run each file as single reads."
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
