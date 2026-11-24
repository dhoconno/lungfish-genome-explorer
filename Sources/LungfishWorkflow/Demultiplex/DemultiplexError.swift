// DemultiplexError.swift - Errors thrown by the demultiplexing pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

// MARK: - Demultiplex Error

public enum DemultiplexError: Error, LocalizedError, Sendable {
    case inputFileNotFound(URL)
    case cutadaptFailed(exitCode: Int32, stderr: String)
    case noBarcodes
    case combinatorialRequiresSampleAssignments
    case outputParsingFailed(String)
    case bundleCreationFailed(barcode: String, underlying: String)
    case noOutputResults
    case emptyAdapterSequences(kitName: String)
    case ambiguousAdapterSequences(kitName: String)
    case kitSequencesUnderCheck(kitName: String)
    /// A custom definition names a built-in kit whose sequences are being checked in its `# kit:` line and holds a pair
    /// of that kit's table, as the Demux tab's Demultiplex button wrote it in builds 2026.11.3 to 2026.11.7.
    case definitionHoldsKitSequencesUnderCheck(kitName: String)
    /// A search of the read bases at 5' End or 3' End with a dual kit and no sample sheet, or with a dual Illumina-family
    /// kit, which leaves one barcode of each pair free (BIO-BARE-REVERSE item 1). The words of a kit that is not built in,
    /// a custom definition, also name the 5' and 3' distances.
    case dualKitNeedsBothEnds(kitName: String)
    case binCountExceeded(count: Int, limit: Int)
    case exactBareBarcodeUnsupported
    case fileSetNeedsInterleaving(bundleName: String, fileNames: [String])
    /// ``DemultiplexSearchRouteOwner`` refused the run, for the reason the words give.
    case searchRouteRefused(String)
    /// No barcode of a search of the read bases beat BIO's chance floor (L5, 3.3 tally).
    /// On the route that reads a custom dual-index definition's secondary sequence both ways, the words say the way the
    /// column is written is not the cause (DEMUX-DUAL-FORM, UX-WORDS-2 section 3 (b)).
    case noBarcodeAboveChance(kitName: String, readsSecondaryBothWays: Bool = false)
    /// A search of the read bases with a kit whose barcodes are so short that half of all reads or more match one by
    /// chance, which the floor cannot tell from reads with no barcode, and no opt-in (DEMUX-FLOOR-SATURATED-KIT).
    case chanceCheckCannotJudgeKit(kitName: String)
    /// The same refusal for a kit whose cutadapt lines have no side anchored with `^` or `$`, such as the built-in Fluidigm
    /// Access Array kit. Cutadapt searches its barcodes anywhere in the read, so nearly every read matches one, and the words
    /// name the routes made for such a kit (BIO-SATKIT-FLUIDIGM item 4).
    case chanceCheckCannotJudgeKitSearchedAnywhere(kitName: String)
    /// The same refusal for a kit searched as linked pairs with neither side anchored, the lines of a dual kit with a sample
    /// sheet in the bare context (BIO-DUAL-ANCHOR item 8). A custom dual-index definition at Both Ends with no sample sheet
    /// wrote such lines until BIO-DUAL-ANCHOR anchored them. Cutadapt searches each side anywhere in the read and also
    /// counts 3 bases of a side at a read end, so reads that carry no barcode match a pair by chance (BIO-SATKIT-ANYWHERE
    /// items 3 and 4). The words name no Fluidigm route, and no sample-sheet route, which BIO did not check.
    case chanceCheckCannotJudgeKitPairsSearchedAnywhere(kitName: String)
    /// A dual-index run at Both Ends with no sample sheet, a custom definition or a built-in dual kit, whose pairs, strands
    /// and 5' and 3' distances give cutadapt more than ``DemultiplexingPipeline/observedPairLineCap`` lines. Cutadapt spends a
    /// fixed time a run that grows with its lines before it reads the first read, about 29 ms a line, so such a run is
    /// refused before it starts (BIO-DUAL-ANCHOR item 5, DEMUX-BUILTIN-DUAL-LINES).
    case tooManySearchLines(kitName: String, pairs: Int, maxDistanceFrom5Prime: Int, maxDistanceFrom3Prime: Int, lines: Int)
    /// An Exact Bare Barcode run whose first read names carry `present` of the kit's barcodes, two or more, so the barcodes
    /// were read as an index and the search of the read sequences finds them there only by chance (DEMUX-EXACT-BARE-NO-FLOOR,
    /// BIO-DEMUX-THREE item 7). The words name the split by the read names and the opt-in.
    case exactBareBarcodesInReadNames(kitName: String, present: Int)
    /// The split by the read names read reads and found an index of the kit in none of their names (UX SF3).
    case noReadNameIndex(kitName: String)
    /// Detect Barcodes read the first read names of a file for an Illumina or Element kit and found no index (L9).
    case readNamesCarryNoIndex(kitName: String, namesRead: Int)
    /// A custom dual-index definition at Both Ends with no sample sheet whose first reads fit its rows both with the
    /// secondary sequence as written and reverse complemented, in different rows, while no row carries a form
    /// (DEMUX-DUAL-FORM, BIO-DUAL-FORM item 2). `rows` are the rows of those reads in the definition's order.
    case dualFormUndecided(kitName: String, rows: [String])
    /// The same definition whose rows carry the secondary sequence in both forms. The rows of the form fewer rows carry are
    /// named in the list of that form and the other list is empty, and both lists are named on a tie (UX-WORDS-2 section 3).
    case dualFormMixed(kitName: String, asWritten: [String], reverseComplemented: [String])

    public var errorDescription: String? {
        switch self {
        case .dualFormUndecided(let kitName, let rows):
            let named = "The rows \(Self.list(rows)) of \"\(kitName)\""
            let match = "first barcodes that match and secondary sequences that are reverse complements of each other, each "
                + "within the error rate."
            let fit = " The first reads fit these rows both ways, with the secondary sequence as it appears at the end of the "
                + "read and as the i5 primer's barcode, so Demultiplex Barcodes cannot tell which sample each read belongs to, "
                + "and nothing was run."
            guard rows.count > 2 else {
                return named + " have " + match + fit
                    + " If one of these rows is not in this pool, remove it from the definition and run again."
            }
            return named + " come in pairs, and the two rows of each pair have " + match + fit
                + " If one row of a pair is not in this pool, remove it from the definition and run again."
        case .dualFormMixed(let kitName, let asWritten, let reverseComplemented):
            func rows(_ names: [String]) -> String { names.count == 1 ? "the row \(names[0])" : "the rows \(Self.list(names))" }
            func carry(_ names: [String]) -> String { names.count == 1 ? "carries" : "carry" }
            let advice = " Write the secondary sequence of every row the same way, either as it appears at the end of the "
                + "read or as the i5 primer's barcode, and run again."
            if asWritten.isEmpty {
                return "In the first reads, most rows of \"\(kitName)\" carry the secondary sequence as written, but "
                    + "\(rows(reverseComplemented)) \(carry(reverseComplemented)) it reverse complemented, so nothing was run."
                    + advice
            }
            if reverseComplemented.isEmpty {
                return "In the first reads, most rows of \"\(kitName)\" carry the secondary sequence reverse complemented, "
                    + "but \(rows(asWritten)) \(carry(asWritten)) it as written, so nothing was run." + advice
            }
            // The rows that carry it reverse complemented come first, so a run of the same file gives the same words.
            return "In the first reads, \(rows(reverseComplemented)) of \"\(kitName)\" \(carry(reverseComplemented)) the "
                + "secondary sequence reverse complemented and \(rows(asWritten)) \(carry(asWritten)) it as written, so "
                + "nothing was run." + advice
        case .readNamesCarryNoIndex(let kitName, let namesRead):
            return "Detect Barcodes read the first \(namesRead) read names and found no index in them, so it counted no barcode of \(kitName). It counts Illumina and Element kits from the index that bcl2fastq or BCL Convert writes in each read name, and names such as those SRA gives by default carry none. For barcodes inside the reads, run Demultiplex Barcodes with a Custom Definition of their sequences (on the command line, fastq demultiplex --kit with your barcode file)."
        case .noReadNameIndex(let kitName):
            return "No read name carried an index of \(kitName), so Demultiplex Barcodes made no sample files. The reads may carry no index in their names, the index may belong to another kit, or the reads may already be split into one file per sample. Choose the kit the library was made with, search the read sequences with Cutadapt, or import this file as one sample."
        case .noBarcodeAboveChance(let kitName, let readsSecondaryBothWays):
            let form = readsSecondaryBothWays
                ? " The run looked for the secondary sequence of each row both as written and reverse complemented, so the way the secondary sequences are written is not the cause. If your barcodes sit some bases in from the read ends, set 5' Distance and 3' Distance to that many bases (on the command line, --max-distance-5prime and --max-distance-3prime)." : ""
            return "No barcode of \(kitName) matched more reads than chance alone gives, so Demultiplex Barcodes made no sample files. The index in the read names may match no barcode of this kit, the index may sit in index reads that are not in this file, the reads may already be split into one file per sample, or a barcode may be on too few reads to stand above chance.\(form) Choose the kit the library was made with, check the barcode sequences and the end of the read you chose for a Custom Definition, or import this file as one sample."
        case .chanceCheckCannotJudgeKit(let kitName):
            return "The barcodes of the kit \"\(kitName)\" are so short that about half of all reads or more match one of them by chance, so the check for chance matches cannot tell this pool from reads that carry no barcode, and nothing was run. If the reads carry these barcodes, run it again with Keep Unchecked Samples (on the command line, --keep-unchecked-samples), then check each sample against your sample sheet."
        case .chanceCheckCannotJudgeKitSearchedAnywhere(let kitName):
            return "Cutadapt searches each barcode of the kit \"\(kitName)\" anywhere in the read, so about half of all reads or more match one of them by chance. The check for chance matches cannot tell this pool from reads that carry no barcode, and nothing was run. For Fluidigm barcodes in ONT reads, use ONT Fluidigm Sample Split (on the command line, fastq ont-fluidigm-samples). For reads whose index is in the read names, choose the engine Read Names (on the command line, --engine header-index). To run this search anyway, run it again with Keep Unchecked Samples (on the command line, --keep-unchecked-samples), then check each sample against your sample sheet."
        case .chanceCheckCannotJudgeKitPairsSearchedAnywhere(let kitName):
            return "Cutadapt searches each pair of barcodes of the kit \"\(kitName)\" anywhere in the read. A few bases of a barcode at the start or end of a read also count as a match, so many reads that carry no barcode match a pair by chance. The check for chance matches cannot tell these reads from reads that carry the barcodes, and nothing was run. If the indexes are in the read names, choose the engine Read Names (on the command line, --engine header-index). To run this search anyway, run it again with Keep Unchecked Samples (on the command line, --keep-unchecked-samples), then check that each sample holds the reads you expect."
        case .tooManySearchLines(let kitName, let pairs, let fivePrime, let threePrime, let lines):
            let searched = pairs == 1
                ? "the barcode pair of \"\(kitName)\"" : "the \(Self.grouped(pairs)) barcode pairs of \"\(kitName)\""
            return "Searching \(searched) up to \(fivePrime) bases from the start of the read and up to \(threePrime) bases from the end takes \(Self.grouped(lines)) Cutadapt search lines, one for each pair, strand and combination of start and end distance. That is more than the \(Self.grouped(DemultiplexingPipeline.observedPairLineCap)) a run can take, since Cutadapt spends time on every line before it reads the first read, so nothing was run. If the barcodes sit inside a known adapter sequence, trim that sequence from the reads first and run again with both distances at 0, or lower the 5' Distance and 3' Distance until the lines fit (on the command line, --max-distance-5prime and --max-distance-3prime)."
        case .exactBareBarcodesInReadNames(let kitName, let present):
            return "The read names carry \(present) of the barcodes of the kit \"\(kitName)\", so these barcodes were read as an index. Exact Bare Barcode searches the read sequences, where it would find them only by chance, so nothing was run. To split the reads by the barcodes in their names, choose the engine Read Names (on the command line, --engine header-index). If the read sequences carry these barcodes too, run it again with Keep Unchecked Samples (on the command line, --keep-unchecked-samples), then check each sample against your sample sheet."
        case .searchRouteRefused(let words):
            return words
        case .inputFileNotFound(let url):
            return "Input FASTQ not found: \(url.lastPathComponent)"
        case .cutadaptFailed(let code, let stderr):
            return "cutadapt failed (exit \(code)): \(String(stderr.suffix(500)))"
        case .noBarcodes:
            return "Barcode kit has no barcodes defined"
        case .combinatorialRequiresSampleAssignments:
            return "Combinatorial kits require explicit sample barcode assignments."
        case .outputParsingFailed(let msg):
            return "Failed to parse cutadapt output: \(msg)"
        case .bundleCreationFailed(let barcode, let error):
            return "Failed to create bundle for \(barcode): \(error)"
        case .noOutputResults:
            return "Multi-step demultiplexing produced no output results."
        case .emptyAdapterSequences(let kitName):
            return "No barcode sequences could be built for the kit \"\(kitName)\", so nothing was run and no files changed. Choose Custom Definition (on the command line, pass --kit with your own barcode file) and enter the barcode sequences from your index sheet, or choose the kit named in your library preparation record."
        case .ambiguousAdapterSequences(let kitName):
            return "Two barcodes in the kit \"\(kitName)\" give the same search sequence, so their reads could not be told apart and nothing was run. Choose Custom Definition and enter the barcodes from your index sheet."
        case .kitSequencesUnderCheck(let kitName):
            return "The built-in sequences for \"\(kitName)\" are being checked, so this kit is off for now and nothing was run. Choose Custom Definition (on the command line, pass --kit with your own barcode file) and enter the i7 and i5 sequences from your index sheet."
        case .definitionHoldsKitSequencesUnderCheck(let kitName):
            return "This definition holds LGE's built-in sequences for \"\(kitName)\", which are being checked, so nothing was run. Enter the i7 and i5 sequences from your index sheet in a Custom Definition (on the command line, pass --kit with your own barcode file)."
        case .dualKitNeedsBothEnds(let kitName):
            let words = "The kit \"\(kitName)\" has its first index at the start of a read and its second at the end, so it can be searched only at Both Ends, and nothing was run. Choose Both Ends (on the command line, --location bothends) and run it again."
            // A built-in kit's indexes sit at the read ends. The barcodes of a definition the person wrote can sit some
            // bases in, which the two distances name at Both Ends (BIO-BARE-REVERSE item 1, UX).
            guard !BarcodeKitRegistry.builtinKits().contains(where: { $0.displayName == kitName }) else { return words }
            return words + " If your barcodes sit some bases in from the read ends, also set 5' Distance and 3' Distance to that many bases (on the command line, --max-distance-5prime and --max-distance-3prime)."
        case .binCountExceeded(let count, let limit):
            return "Bin count (\(count)) exceeds maximum (\(limit)). Reduce the number of barcode combinations or use fewer demux steps."
        case .exactBareBarcodeUnsupported:
            return "Nothing was run. Exact Bare Barcode accepts only the built-in Fluidigm Access Array kit or a Custom Definition with one barcode of 1 to 31 A, C, G or T letters per row and either no kit line or a kit line naming the Fluidigm Access Array kit. Choose Cutadapt (on the command line, --engine cutadapt)."
        case .fileSetNeedsInterleaving(let bundleName, let fileNames):
            return "The bundle \"\(bundleName)\" holds \(fileNames.count) FASTQ files (\(fileNames.joined(separator: ", "))) and no source-files.json, so they are the R1 and R2 of one sample. Exact-barcode demultiplexing calls every read on its own, so the two mates of a pair would not follow one call, and nothing was run. Make one interleaved FASTQ file of the pair (lungfish-cli fastq interleave), then demultiplex that file."
        }
    }

    /// `value` with a comma between each group of three digits, as the words write counts.
    /// `items` joined as the words list rows, "X and Y" for two and "A, B, C and D" for more.
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value))
        var text = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, digit.isNumber, (digits.count - index) % 3 == 0 { text.append(",") }
            text.append(digit)
        }
        return text
    }
}
