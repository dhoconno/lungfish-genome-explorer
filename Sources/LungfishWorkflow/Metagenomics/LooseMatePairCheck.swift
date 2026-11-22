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
/// `.lungfishfastq` bundle had its mates checked when it was imported, so it is not read again. Two
/// loose FASTA files have their `>` records counted and each pair's names compared, and a loose pair
/// that is neither FASTQ nor FASTA by name is refused (BIO-ROUTES-2 items 3 and 4).
package enum LooseMatePairCheck {

    /// The words that refuse `r1` and `r2` as one pair, or nil when every pair of records is mates by
    /// name and both files hold the same number of whole records, or when they are not two loose files.
    /// Mates out of step take the run words of
    /// ``runOutOfStepWords(recordNumber:r1File:r1Name:r2File:r2Name:)`` and a count mismatch those of
    /// ``runMismatchWords(r1File:r1Records:r2File:r2Records:)``, because the import's words end "so
    /// nothing was written." and "Nothing was imported.". A record or a gzip that cannot be read keeps
    /// the reader's words. A cancel and a gzip that cannot start are thrown as they are. `workflow run
    /// nf-core/viralrecon` calls it from the CLI on each samplesheet row of two files (BIO-ROUTES item 3).
    /// Two loose files of which one is not FASTQ or FASTA by name (`.bz2`, `.xz`, no extension) take
    /// ``formatWords(file:)``, and two loose FASTA files ``fastaRefusal(r1:r2:)`` (BIO-ROUTES-2).
    package static func refusal(r1: URL, r2: URL) throws -> String? {
        guard isLoose(r1), isLoose(r2) else { return nil }
        let formats = (SequenceFormat.from(url: r1), SequenceFormat.from(url: r2))
        if formats.0 == nil { return formatWords(file: r1.lastPathComponent) }
        if formats.1 == nil { return formatWords(file: r2.lastPathComponent) }
        if formats == (.fasta, .fasta) { return try fastaRefusal(r1: r1, r2: r2) }
        guard formats == (.fastq, .fastq) else { return nil }
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

    /// The words of a run refused because one of its two loose files is not FASTQ or FASTA by name
    /// (BIO-ROUTES-2 item 6, Sol's decided R2-5).
    static func formatWords(file: String) -> String {
        "Paired reads need FASTQ files (.fastq or .fq) or FASTA files (.fasta, .fa, .fna or .fsa), with or without .gz. \(file) has an unsupported name. Nothing ran. Decompress or rename it, or run each file as single reads."
    }

    /// The words of a run refused because its two FASTA mate files hold different numbers of records
    /// (B1 with "FASTA", BIO-ROUTES-2 item 6, draft).
    static func fastaMismatchWords(r1File: String, r1Records: Int, r2File: String, r2Records: Int) -> String {
        "Paired FASTA mates do not match. \(r1File) has \(r1Records) reads, but \(r2File) has \(r2Records). Nothing ran. Check that both files are complete or run each as single reads."
    }

    /// The words of a run refused because the names of its two FASTA mate files are out of step (B2 with
    /// "FASTA", BIO-ROUTES-2 item 6, draft).
    static func fastaOutOfStepWords(recordNumber: Int, r1File: String, r1Name: String, r2File: String, r2Name: String) -> String {
        "Paired FASTA mates are out of step at read \(recordNumber). \(r1File) has '\(r1Name)', but \(r2File) has '\(r2Name)'. Nothing ran. Check that both files are from the same run and neither was sorted or subsampled on its own, or run each file as single reads."
    }

    /// The words of `fastq interleave` refused because its two files hold different numbers of reads
    /// (BIO-ROUTES-2 item 6, draft).
    static func interleaveMismatchWords(r1File: String, r1Records: Int, r2File: String, r2Records: Int) -> String {
        "Paired FASTQ mates do not match. \(r1File) has \(r1Records) reads, but \(r2File) has \(r2Records). Nothing was written. Check that both files are complete."
    }

    /// The words of `fastq interleave` refused because its two files are out of step at read
    /// `recordNumber` (BIO-ROUTES-2 item 6, draft).
    static func interleaveOutOfStepWords(recordNumber: Int, r1File: String, r1Name: String, r2File: String, r2Name: String) -> String {
        "Paired FASTQ mates are out of step at read \(recordNumber). \(r1File) has '\(r1Name)', but \(r2File) has '\(r2Name)'. Nothing was written. Check that both files are from the same run and neither was sorted or subsampled on its own."
    }

    /// Reads both files of `pair` whole before the first step of an import, with a recipe or without one, and
    /// throws the import's own words ("... Nothing was imported." and "... so nothing was written.") for a cut
    /// or out-of-step pair (BIO-ROUTES-2 item 1, BIO-ROUTES-3 item 1). A recipe's first step (`FastpTrimStep`,
    /// `FastpDedupStep`, the old-format paired trims) hands the pair to fastp, and every storage route (the Swift
    /// join, clumpify, reformat and Trim Galore) pairs two files by position as well. After any of them both
    /// outputs hold equal counts, so no later check can see the lost reads. The progress line is the storage
    /// step's own text.
    static func verifyBeforeAnyStep(_ pair: SamplePair) throws {
        guard let r2 = pair.r2 else { return }
        FASTQBatchImporter.printProgress("  \u{2192} Checking which reads are mates...")
        _ = try FASTQPairInterleaver.verifyMates(r1: pair.r1, r2: r2, launcher: ToolProcessChildLauncher())
    }

    /// The words that refuse `r1` and `r2` before `fastq interleave` joins them, or nil when every pair
    /// of records is mates by name and both files hold the same number of records (BIO-ROUTES-2 item 2).
    /// BBTools reformat pairs two files by position, so files out of step came out as a file of wrong
    /// pairs with exit 0. Only the two mate refusals are the command's: a record or a gzip that cannot
    /// be read is left to reformat, as before. A cancel is thrown as it is.
    package static func interleaveRefusal(r1: URL, r2: URL) throws -> String? {
        do {
            _ = try FASTQPairInterleaver.verifyMates(r1: r1, r2: r2, launcher: ToolProcessChildLauncher())
            return nil
        } catch FASTQPairInterleaver.InterleaveError.mateNameMismatch(let recordNumber, let r1File, let r1Name, let r2File, let r2Name) {
            return interleaveOutOfStepWords(recordNumber: recordNumber, r1File: r1File, r1Name: r1Name, r2File: r2File, r2Name: r2Name)
        } catch FASTQPairInterleaver.InterleaveError.mateCountMismatch(let r1File, let r1Records, let r2File, let r2Records) {
            return interleaveMismatchWords(r1File: r1File, r1Records: r1Records, r2File: r2File, r2Records: r2Records)
        } catch is FASTQPairInterleaver.InterleaveError {
            return nil
        }
    }

    /// The words that refuse two loose FASTA files as one pair, or nil when both hold the same number of
    /// `>` records and each pair's names are mates (``FASTQPairInterleaver/recordedMates(_:_:)``, which
    /// takes the first word with `/1` and `/2`, Casava comments and SRA serials). Plain or gzip. The
    /// first pair out of step is refused at once, and a count mismatch once both files are read. A gzip
    /// that does not decompress whole keeps the reader's words (BIO-ROUTES-2 item 3).
    static func fastaRefusal(r1: URL, r2: URL) throws -> String? {
        do {
            let launcher = ToolProcessChildLauncher()
            let reader1 = try FASTQRawLineReader(url: r1, launcher: launcher)
            defer { reader1.close() }
            let reader2 = try FASTQRawLineReader(url: r2, launcher: launcher)
            defer { reader2.close() }
            func nextName(_ reader: FASTQRawLineReader) throws -> String? {
                while let line = try reader.nextLine() {
                    if line.first == UInt8(ascii: ">") { return FASTQPairInterleaver.headerText(line) }
                }
                return nil
            }
            var (count1, count2) = (0, 0)
            while true {
                let name1 = try nextName(reader1)
                let name2 = try nextName(reader2)
                if name1 != nil { count1 += 1 }
                if name2 != nil { count2 += 1 }
                if count1 & 0x3FFF == 0 { try Task.checkCancellation() }
                guard let name1, let name2 else {
                    if name1 == nil, name2 == nil { break }
                    continue
                }
                if FASTQPairInterleaver.recordedMates(name1, name2) != .mates {
                    return fastaOutOfStepWords(
                        recordNumber: count1, r1File: r1.lastPathComponent, r1Name: name1, r2File: r2.lastPathComponent, r2Name: name2)
                }
            }
            guard count1 == count2 else {
                return fastaMismatchWords(r1File: r1.lastPathComponent, r1Records: count1, r2File: r2.lastPathComponent, r2Records: count2)
            }
            return nil
        } catch let error as FASTQPairInterleaver.InterleaveError {
            return error.localizedDescription
        }
    }

    /// Whether `url` names a file that exists and lies in no `.lungfishfastq` bundle. A missing file
    /// keeps the refusal its route already gives it.
    static func isLoose(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && SequenceInputResolver.enclosingFASTQBundleURL(for: url) == nil
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
