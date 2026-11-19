// DemultiplexingPipeline+OffsetShift.swift - A placed read goes to the one row whose anchored lines fit it at the fewest errors
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// What the check of placed reads did to a run (DEMUX-DUAL-OFFSET-SHIFT, BIO-OFFSET-SHIFT item 2).
    struct OffsetShiftCounts: Sendable, Equatable {
        /// The placed reads the check read.
        var checked = 0
        /// The placed reads that one other row fits at fewer errors, which went to that row.
        var moved = 0
        /// The placed reads that two or more rows fit at their fewest errors, which went to Unassigned whole. The record
        /// names them as `ambiguousReads`, and the Unassigned count holds them.
        var ambiguous = 0
        /// The ends the run's lines search, which name the distances in the words of ``ambiguousReadsLine(_:ends:)``.
        var ends: SearchedEnds = .both
        /// Each read the check moved or sent to Unassigned, by `readID` and `mate` as the info file names them, kept only
        /// for a run that keeps trim positions, which reads its rows from the info file.
        var corrections: [String: TrimCorrection] = [:]
    }

    /// The ends of a read that a run's anchored lines search for barcodes: both (dual and linked lines), the start only
    /// (5' lines) or the end only (3' lines). The record names it as `ambiguousReadsEnds` when it is not both.
    public enum SearchedEnds: String, Sendable, Equatable {
        case both
        case fivePrime
        case threePrime
    }

    /// A read the check moved or sent to Unassigned, as a run that keeps trim positions corrects them.
    struct TrimCorrection: Sendable, Equatable {
        /// The row Cutadapt placed the read in.
        let from: String
        /// The row the read went to, or nil for Unassigned.
        let to: String?
        let trim5p: Int
        /// The bases trimmed from the read's end.
        let trim3p: Int
        let readLength: Int
    }

    /// `trims` as the info file gives them, with each read the check moved under its new row and trimmed as that row's
    /// line trims it, and each read it sent to Unassigned taken out of its row.
    func correctingTrims(_ trims: [String: [DemuxTrimEntry]], by counts: OffsetShiftCounts) -> [String: [DemuxTrimEntry]] {
        guard !counts.corrections.isEmpty else { return trims }
        var result = trims.mapValues { entries in entries.filter { counts.corrections["\($0.readID)\t\($0.mate)"] == nil } }
        for (key, correction) in counts.corrections.sorted(by: { $0.key < $1.key }) {
            guard let row = correction.to else { continue }
            let parts = key.split(separator: "\t", omittingEmptySubsequences: false)
            result[row, default: []].append(DemuxTrimEntry(
                readID: String(parts[0]), mate: parts.count > 1 ? Int(parts[1]) ?? 0 : 0,
                trim5p: correction.trim5p, trim3p: correction.trim3p, rootReadLength: correction.readLength
            ))
        }
        return result
    }

    /// The words that stand between the count and the rest of ``ambiguousReadsLine(_:ends:)``. No other line of the window
    /// holds them, so the window finds the line by them.
    public static let ambiguousReadsMarker = " went to Unassigned because "

    /// The words after the verb of ``ambiguousReadsLine(_:ends:)`` for lines that search both ends, BIO-OFFSET-SHIFT item 4
    /// as the UX review of DEMUX-DUAL-OFFSET-SHIFT words it.
    public static let ambiguousReadsWords = " the barcodes of two or more samples equally well within the 5' and 3' Distance. "
        + "Set each distance only as far as your barcodes sit in from the read ends."

    /// The words after the verb for the ends a run's lines search: both, the 5' Distance only or the 3' Distance only
    /// (UX review of DEMUX-DUAL-OFFSET-SHIFT, ruling 4, whose second sentences are BIO-SINGLE-OFFSET item 4's).
    public static func ambiguousReadsEndWords(_ ends: SearchedEnds) -> String {
        switch ends {
        case .both:
            return ambiguousReadsWords
        case .fivePrime:
            return " the barcodes of two or more samples equally well within the 5' Distance. "
                + "Set the distance only as far as your barcodes sit in from the start of the read."
        case .threePrime:
            return " the barcodes of two or more samples equally well within the 3' Distance. "
                + "Set the distance only as far as your barcodes sit in from the end of the read."
        }
    }

    /// The line of the Operations Panel row, its Log and the command's summary for a run that sent `count` reads that two
    /// rows fit to Unassigned, a line of information, or nil for none. The count is grouped, as in "1,204", and the verb
    /// agrees with it.
    public static func ambiguousReadsLine(_ count: Int, ends: SearchedEnds = .both) -> String? {
        guard count > 0 else { return nil }
        let reads = count == 1 ? "1 read" : "\(DemultiplexError.grouped(count)) reads"
        return reads + ambiguousReadsMarker + (count == 1 ? "it fits" : "they fit") + ambiguousReadsEndWords(ends)
    }

    /// Whether a run checks each placed read against the lines of every row: a Custom Definition of dual indexes at Both
    /// Ends with no sample sheet and a 5' or 3' Distance above 0 (BIO-OFFSET-SHIFT items 1 and 2). At 0/0 no line holds
    /// an N, so Cutadapt's rank by score is a rank by errors, and the run stays as it was byte for byte. Cutadapt trims
    /// poly-G before it searches, so a run that trims poly-G placed reads that are not the reads the check would read.
    func checksPlacedReadsByFewestErrors(_ config: DemultiplexConfig) -> Bool {
        usesObservedCustomBarcodePairs(config)
            && (config.maxDistanceFrom5Prime > 0 || config.maxDistanceFrom3Prime > 0)
            && config.polyGTrimQuality == nil
    }

    /// Puts each read Cutadapt placed in `outputDirectory` in the one row whose lines in `adapterFASTA` fit it at the
    /// fewest errors, and a read that two rows fit equally in Unassigned (BIO-OFFSET-SHIFT item 2). It runs on Cutadapt's
    /// plain outputs, before the outputs of the two strands of a row are joined, while each output keeps the input's order.
    func placeReadsByFewestErrors(
        of inputFASTQ: URL, in outputDirectory: URL, adapterFASTA: URL, config: DemultiplexConfig, keepsTrimPositions: Bool
    ) throws -> OffsetShiftCounts {
        let lines = try String(contentsOf: adapterFASTA, encoding: .utf8)
        guard let fit = AnchoredOffsetFit(
            adapterFASTA: lines, rowOf: { [self] in canonicalAdapterName($0) },
            errorRate: config.effectiveErrorRate, indels: !config.useNoIndels
        ) else {
            throw DemultiplexError.outputParsingFailed("the run's lines are not anchored at the read ends, so its placed reads could not be checked")
        }
        return try DemultiplexOffsetShiftPass(
            inputFASTQ: inputFASTQ, outputDirectory: outputDirectory, unassignedName: "unassigned",
            fit: fit, trims: config.trimBarcodes,
            correctionKey: keepsTrimPositions ? { [self] header in
                let name = detectMate(rawReadName: header)
                return "\(name.readID)\t\(name.mate)"
            } : nil
        ).run()
    }
}

/// The fewest errors at which the anchored lines of each row fit a read (BIO-OFFSET-SHIFT item 2, BIO-SINGLE-OFFSET
/// item 2), for any writer of anchored lines with offsets.
///
/// It reads the lines as a writer wrote them for Cutadapt: `^N{a}F...BN{b}$` (linked), `^N{a}F` (5') and `BN{b}$` (3').
/// The lines of one output with the same barcodes are one shape, searched at every offset from 0 to the largest `a` and
/// the largest `b` they carry. A barcode fits with at most floor(error rate x its bases that are not N) errors
/// (``DemultiplexingPipeline/barcodeErrorBudget(_:errorRate:)``, the budget of the choice of form), with an N of the
/// barcode or of the offset matching any base, an N of the read matching no base, and indels counted as Cutadapt counts
/// them when the run allows them. A linked shape fits when its front fits and its back fits in the rest of the read
/// after the front, as Cutadapt searches a linked line, at the sum of the two errors. Cutadapt ranks the lines that match
/// a read by score, and each N of an offset scores as a matched base, so a line further in can beat the right row's line
/// by its N's (BIO-OFFSET-SHIFT Q1). This ranks the rows by errors alone.
struct AnchoredOffsetFit {
    /// One output's lines with the same barcodes.
    struct Shape: Equatable {
        let output: String
        let row: Int
        /// The index in `fronts` of the barcode at the read's start.
        let front: Int?
        /// The index in `backs` of the barcode at the read's end.
        let back: Int?
    }

    /// A barcode searched at offsets 0 to `maxOffset` from one end of the read, its bases read from that end.
    struct Probe: Hashable {
        let bases: [UInt8]
        let budget: Int
        let maxOffset: Int
    }

    /// Where a barcode fits, at its fewest errors: for a front the read position after its match, for a back the count
    /// of bases from its match's start to the read's end.
    struct Fit: Equatable {
        let errors: Int
        let position: Int
    }

    enum Call: Equatable {
        /// No row's lines fit the read.
        case none
        /// One row fits the read at its fewest errors, by `shape`, whose line keeps the read's bases `keep`.
        case one(shape: Int, errors: Int, keep: Range<Int>)
        /// Two or more rows fit the read at its fewest errors.
        case tied(errors: Int)
    }

    let rows: [String]
    let shapes: [Shape]
    let fronts: [Probe]
    let backs: [Probe]
    let indels: Bool
    private let rowOfOutput: [String: Int]

    /// The ends the lines search.
    var ends: DemultiplexingPipeline.SearchedEnds {
        fronts.isEmpty ? .threePrime : backs.isEmpty ? .fivePrime : .both
    }

    /// The lines of `adapterFASTA`, each output's row named by `rowOf`, or nil when a line is not anchored at the ends it
    /// searches or the file holds no line.
    init?(adapterFASTA text: String, rowOf: (String) -> String, errorRate: Double, indels: Bool) {
        typealias Found = (output: String, front: String?, back: String?, a: Int, b: Int)
        var order: [String] = []
        var found: [String: Found] = [:]
        var name: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                name = String(line.dropFirst())
                continue
            }
            guard let output = name, let spec = Self.parse(line) else { return nil }
            name = nil
            let key = [output, spec.front ?? "", spec.back ?? ""].joined(separator: "\t")
            if var known = found[key] {
                known.a = max(known.a, spec.a)
                known.b = max(known.b, spec.b)
                found[key] = known
            } else {
                found[key] = (output, spec.front, spec.back, spec.a, spec.b)
                order.append(key)
            }
        }
        guard !order.isEmpty else { return nil }

        var rows: [String] = []
        var rowIndex: [String: Int] = [:]
        var rowOfOutput: [String: Int] = [:]
        var shapes: [Shape] = []
        var fronts: [Probe] = [], backs: [Probe] = []
        var frontIndex: [Probe: Int] = [:], backIndex: [Probe: Int] = [:]
        func probe(_ bases: String, _ maxOffset: Int, reversed: Bool) -> Probe {
            let bytes = Array(bases.utf8)
            return Probe(
                bases: reversed ? bytes.reversed() : bytes,
                budget: DemultiplexingPipeline.barcodeErrorBudget(bases, errorRate: errorRate),
                maxOffset: maxOffset
            )
        }
        func index(_ probe: Probe, _ list: inout [Probe], _ known: inout [Probe: Int]) -> Int {
            if let index = known[probe] { return index }
            list.append(probe)
            known[probe] = list.count - 1
            return list.count - 1
        }
        for key in order {
            guard let item = found[key] else { continue }
            let rowName = rowOf(item.output)
            let row: Int
            if let known = rowIndex[rowName] {
                row = known
            } else {
                rows.append(rowName)
                row = rows.count - 1
                rowIndex[rowName] = row
            }
            rowOfOutput[item.output] = row
            shapes.append(Shape(
                output: item.output, row: row,
                front: item.front.map { index(probe($0, item.a, reversed: false), &fronts, &frontIndex) },
                back: item.back.map { index(probe($0, item.b, reversed: true), &backs, &backIndex) }
            ))
        }
        self.rows = rows
        self.shapes = shapes
        self.fronts = fronts
        self.backs = backs
        self.indels = indels
        self.rowOfOutput = rowOfOutput
    }

    /// The row an output of these lines holds, or nil for an output they do not name.
    func row(ofOutput name: String) -> Int? { rowOfOutput[name] }

    /// The barcodes and offsets of one line, or nil for a line that is not anchored at the ends it searches.
    static func parse(_ spec: String) -> (front: String?, back: String?, a: Int, b: Int)? {
        let parts = spec.components(separatedBy: "...")
        switch parts.count {
        case 1 where spec.hasPrefix("^"):
            guard let front = front(spec) else { return nil }
            return (front.bases, nil, front.offset, 0)
        case 1 where spec.hasSuffix("$"):
            guard let back = back(spec) else { return nil }
            return (nil, back.bases, 0, back.offset)
        case 2:
            guard let front = front(parts[0]), let back = back(parts[1]) else { return nil }
            return (front.bases, back.bases, front.offset, back.offset)
        default:
            return nil
        }
    }

    /// `^N{a}F` as `F` and `a`.
    private static func front(_ part: String) -> (bases: String, offset: Int)? {
        guard part.hasPrefix("^") else { return nil }
        var rest = Substring(part.dropFirst())
        var offset = 0
        if rest.hasPrefix("N{"), let close = rest.firstIndex(of: "}"),
           let count = Int(rest[rest.index(rest.startIndex, offsetBy: 2)..<close]) {
            offset = count
            rest = rest[rest.index(after: close)...]
        }
        guard !rest.isEmpty, rest.allSatisfy(\.isLetter) else { return nil }
        return (rest.uppercased(), offset)
    }

    /// `BN{b}$` as `B` and `b`.
    private static func back(_ part: String) -> (bases: String, offset: Int)? {
        guard part.hasSuffix("$") else { return nil }
        var rest = Substring(part.dropLast())
        var offset = 0
        if rest.hasSuffix("}"), let open = rest.range(of: "N{", options: .backwards),
           let count = Int(rest[open.upperBound..<rest.index(before: rest.endIndex)]) {
            offset = count
            rest = rest[..<open.lowerBound]
        }
        guard !rest.isEmpty, rest.allSatisfy(\.isLetter) else { return nil }
        return (rest.uppercased(), offset)
    }
}

extension AnchoredOffsetFit {
    /// The work of one read, which keeps each barcode's fit for the read so that rows that share a barcode search it once.
    struct Search {
        let lines: AnchoredOffsetFit
        private var frontKnown: [Bool]
        private var frontFits: [Fit?]
        /// The read position each back was searched from, or -1.
        private var backFrom: [Int]
        private var backFits: [Fit?]
        private var reversed: [UInt8] = []
        private var previous: [Int] = []
        private var current: [Int] = []

        init(_ lines: AnchoredOffsetFit) {
            self.lines = lines
            frontKnown = Array(repeating: false, count: lines.fronts.count)
            frontFits = Array(repeating: nil, count: lines.fronts.count)
            backFrom = Array(repeating: -1, count: lines.backs.count)
            backFits = Array(repeating: nil, count: lines.backs.count)
        }

        /// The rows whose lines fit `read`, an uppercase sequence, at its fewest errors.
        mutating func call(_ read: [UInt8]) -> Call {
            for index in frontKnown.indices { frontKnown[index] = false }
            for index in backFrom.indices { backFrom[index] = -1 }
            reversed = Array(read.reversed())
            var best = Int.max, bestRow = -1, bestShape = -1, tied = false
            var keep = 0..<0
            for (index, shape) in lines.shapes.enumerated() {
                var errors = 0, start = 0, end = read.count
                if let front = shape.front {
                    guard let fit = frontFit(front, read) else { continue }
                    errors = fit.errors
                    start = fit.position
                }
                if let back = shape.back {
                    guard let fit = backFit(back, from: start) else { continue }
                    errors += fit.errors
                    end = read.count - fit.position
                }
                if errors < best {
                    (best, bestRow, bestShape, tied, keep) = (errors, shape.row, index, false, start..<end)
                } else if errors == best, shape.row != bestRow {
                    tied = true
                }
            }
            guard bestShape >= 0 else { return .none }
            return tied ? .tied(errors: best) : .one(shape: bestShape, errors: best, keep: keep)
        }

        private mutating func frontFit(_ index: Int, _ read: [UInt8]) -> Fit? {
            if !frontKnown[index] {
                frontFits[index] = fit(lines.fronts[index], in: read, length: read.count)
                frontKnown[index] = true
            }
            return frontFits[index]
        }

        /// A back is searched in the read after the front's match, as Cutadapt searches the back of a linked line.
        private mutating func backFit(_ index: Int, from start: Int) -> Fit? {
            if backFrom[index] != start {
                backFits[index] = fit(lines.backs[index], in: reversed, length: reversed.count - start)
                backFrom[index] = start
            }
            return backFits[index]
        }

        /// The fewest errors of `probe` at the start of the first `length` bases of `text`, at an offset from 0 to its
        /// largest, and the position after its match. Of the matches at those errors it takes the one with the barcode
        /// whole and furthest in, the line with the most N's that Cutadapt's score prefers, then the one ending furthest in.
        private mutating func fit(_ probe: Probe, in text: [UInt8], length: Int) -> Fit? {
            let width = probe.bases.count
            var best: Fit?
            for offset in 0...probe.maxOffset where offset + width <= length {
                var errors = 0
                for (index, base) in probe.bases.enumerated()
                where base != Self.wildcard && text[offset + index] != base {
                    errors += 1
                    if errors > probe.budget { break }
                }
                if errors <= probe.budget, errors <= (best?.errors ?? Int.max) {
                    best = Fit(errors: errors, position: offset + width)
                }
            }
            guard lines.indels, probe.budget > 0, best?.errors != 0 else { return best }
            guard let edited = editFit(probe, in: text, length: length) else { return best }
            return edited.errors < (best?.errors ?? Int.max) ? edited : best
        }

        /// The fewest errors of `probe` with indels, the N's of the offset at the start included: an alignment of
        /// `N{a}` + the barcode to the start of the text, the text's end free, with `a` from 0 to the largest offset.
        private mutating func editFit(_ probe: Probe, in text: [UInt8], length: Int) -> Fit? {
            let columns = min(length, probe.maxOffset + probe.bases.count + probe.budget)
            guard columns > 0 else { return nil }
            if previous.count < columns + 1 {
                previous = Array(repeating: 0, count: columns + 1)
                current = Array(repeating: 0, count: columns + 1)
            }
            // Before the barcode, `a` N's match any `a` bases, and each base past the largest offset is an insertion.
            for column in 0...columns { previous[column] = max(0, column - probe.maxOffset) }
            for (row, base) in probe.bases.enumerated() {
                current[0] = row + 1
                var least = current[0]
                for column in 1...columns {
                    let substitution = previous[column - 1] + (base == Self.wildcard || text[column - 1] == base ? 0 : 1)
                    let value = min(substitution, previous[column] + 1, current[column - 1] + 1)
                    current[column] = value
                    least = min(least, value)
                }
                if least > probe.budget { return nil }
                swap(&previous, &current)
            }
            var best: Fit?
            for column in 0...columns where previous[column] <= probe.budget && previous[column] <= (best?.errors ?? Int.max) {
                best = Fit(errors: previous[column], position: column)
            }
            return best
        }

        private static let wildcard = UInt8(ascii: "N")
    }
}

/// Rewrites Cutadapt's outputs so that each placed read sits in the one row whose lines fit it at the fewest errors, and a
/// read that two rows fit equally sits in Unassigned (BIO-OFFSET-SHIFT item 2).
///
/// Every output keeps the input's order, so one pass over the input beside every output finds the output each record went
/// to, as ``DemultiplexMatePass`` finds it. A read that stays keeps Cutadapt's record, trimmed as Cutadapt trimmed it. A
/// read that one other row fits at fewer errors goes to that row's output, trimmed as that row's line trims it. A read that
/// two rows fit equally goes to Unassigned whole, as Cutadapt writes a read that no line matched. A read the lines do not
/// fit keeps Cutadapt's call. The pass holds one record of each output at a time and no list of read names.
struct DemultiplexOffsetShiftPass {
    /// The file Cutadapt read, plain or gzip.
    let inputFASTQ: URL
    /// Cutadapt's plain `<name>.fastq` outputs, one for each strand of a row.
    let outputDirectory: URL
    let unassignedName: String
    let fit: AnchoredOffsetFit
    /// Whether the run trims the barcodes (`--action trim`).
    let trims: Bool
    /// The key the info file gives a read by its header, for a run that keeps trim positions, or nil.
    var correctionKey: ((String) -> String)?

    func run() throws -> DemultiplexingPipeline.OffsetShiftCounts {
        let fm = FileManager.default
        let outputURLs = try fm.contentsOfDirectory(
            at: outputDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "fastq" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let cursors = try outputURLs.map {
            try OrderedOutputCursor(name: $0.deletingPathExtension().lastPathComponent, url: $0)
        }
        var heads: [String: [Int]] = [:]
        for (index, cursor) in cursors.enumerated() {
            if let key = cursor.head.map(DemultiplexMatePass.matchKey) { heads[key, default: []].append(index) }
        }

        let rewriteDirectory = outputDirectory.appendingPathComponent(".offset-pass", isDirectory: true)
        try? fm.removeItem(at: rewriteDirectory)
        try fm.createDirectory(at: rewriteDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rewriteDirectory) }
        let names = Set(cursors.map(\.name)).union(fit.shapes.map(\.output)).union([unassignedName])
        let flushThreshold = max(65_536, min(262_144, 33_554_432 / max(1, names.count)))
        var sinks: [String: AppendingFASTQSink] = [:]
        for name in names {
            sinks[name] = AppendingFASTQSink(url: rewriteDirectory.appendingPathComponent("\(name).fastq"))
        }
        var written = 0
        func write(_ record: RawFASTQRecord, to name: String) throws {
            try sinks[name]!.append(record, flushThreshold: flushThreshold)
            written += 1
        }

        var counts = DemultiplexingPipeline.OffsetShiftCounts()
        counts.ends = fit.ends
        func correct(_ input: RawFASTQRecord, from placed: Int, to row: Int?, keep: Range<Int>) {
            guard let correctionKey else { return }
            let length = input.sequence.count
            counts.corrections[correctionKey(input.headerText)] = DemultiplexingPipeline.TrimCorrection(
                from: fit.rows[placed], to: row.map { fit.rows[$0] },
                trim5p: keep.lowerBound, trim3p: length - keep.upperBound, readLength: length
            )
        }
        var search = AnchoredOffsetFit.Search(fit)
        let reader = try FASTQRawLineReader(url: inputFASTQ)
        defer { reader.close() }
        var inputRecords = 0
        while let input = try DemultiplexMatePass.readRecord(
            from: reader, file: inputFASTQ.lastPathComponent, number: inputRecords + 1
        ) {
            inputRecords += 1
            if inputRecords & 0x3FFF == 0 { try Task.checkCancellation() }
            let key = DemultiplexMatePass.matchKey(input)
            guard let index = DemultiplexMatePass.cursorIndex(for: input, key: key, heads: heads, cursors: cursors) else {
                throw DemultiplexError.outputParsingFailed(
                    "cutadapt's outputs do not hold input record \(inputRecords) (\(key)) in input order, so its row could not be checked"
                )
            }
            let cursor = cursors[index]
            let output = cursor.head!
            heads[key]?.removeAll { $0 == index }
            if heads[key]?.isEmpty == true { heads[key] = nil }
            try cursor.advance()
            if let next = cursor.head { heads[DemultiplexMatePass.matchKey(next), default: []].append(index) }

            guard cursor.name != unassignedName, let placed = fit.row(ofOutput: cursor.name) else {
                try write(output, to: cursor.name)
                continue
            }
            counts.checked += 1
            switch search.call(Self.uppercased(input.sequence)) {
            case .one(let shape, _, let keep) where fit.shapes[shape].row != placed:
                counts.moved += 1
                correct(input, from: placed, to: fit.shapes[shape].row, keep: keep)
                try write(try Self.record(output, input, keeping: trims ? keep : nil), to: fit.shapes[shape].output)
            case .tied:
                counts.ambiguous += 1
                correct(input, from: placed, to: nil, keep: 0..<input.sequence.count)
                try write(try Self.record(output, input, keeping: nil), to: unassignedName)
            default:
                try write(output, to: cursor.name)
            }
        }
        try Task.checkCancellation()
        if let leftover = cursors.first(where: { $0.head != nil }) {
            throw DemultiplexError.outputParsingFailed(
                "cutadapt's \(leftover.name) output holds records that the input does not, after \(inputRecords) input records"
            )
        }
        guard written == inputRecords else {
            throw DemultiplexError.outputParsingFailed(
                "checking the placed reads wrote \(written) records where the input holds \(inputRecords)"
            )
        }

        for name in names {
            try sinks[name]!.flush()
            let original = outputDirectory.appendingPathComponent("\(name).fastq")
            let rewritten = rewriteDirectory.appendingPathComponent("\(name).fastq")
            if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
            if fm.fileExists(atPath: rewritten.path) { try fm.moveItem(at: rewritten, to: original) }
        }
        return counts
    }

    private static func uppercased(_ bases: [UInt8]) -> [UInt8] {
        bases.map { base -> UInt8 in base >= UInt8(ascii: "a") && base <= UInt8(ascii: "z") ? base - 32 : base }
    }

    /// The input's bases `keep`, or all of them, under the header and separator Cutadapt wrote for the read.
    private static func record(_ output: RawFASTQRecord, _ input: RawFASTQRecord, keeping keep: Range<Int>?) throws -> RawFASTQRecord {
        let sequence = keep.map { Array(input.sequence[$0.clamped(to: 0..<input.sequence.count)]) } ?? input.sequence
        let quality = keep.map { Array(input.quality[$0.clamped(to: 0..<input.quality.count)]) } ?? input.quality
        return try RawFASTQRecord(
            lines: [[UInt8(ascii: "@")] + output.header, sequence, output.separator, quality],
            file: "the check of placed reads", number: 0
        )
    }
}
