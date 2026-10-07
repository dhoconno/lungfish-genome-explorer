// DemultiplexingPipeline+MateAssignment.swift - Both mates of a fragment follow the fragment's barcode call
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// The fragment a listed read ID belongs to, the ID without a `/1` or
    /// `/2` mate suffix, which is the key `detectMate` gives a root record.
    /// seqkit lists a mate named with /1 /2 by its whole ID.
    static func fragmentID(ofListedID listedID: String) -> String {
        if listedID.hasSuffix("/1") || listedID.hasSuffix("/2") {
            return String(listedID.dropLast(2))
        }
        return listedID
    }

    /// How the records of a run's input are laid out for the mate rule.
    ///
    /// FASTA records are single, and so are the reads of a long-read kit,
    /// because READ-PAIRING.md never pairs Oxford Nanopore or PacBio reads.
    /// Anything else is read by name, the rule `fastq primer-remove` and
    /// `fastq deduplicate` use. A bounded scan reads the bundle's metadata as
    /// a hint, and every record is counted when the scan finds mates.
    func demultiplexReadLayout(config: DemultiplexConfig, inputFASTQ: URL) throws -> FastpReadLayoutPlan {
        guard config.inputSequenceFormat != .fasta,
              !config.barcodeKit.platform.readsCanBeReverseComplemented else {
            return .singleEnd
        }
        let decision = FASTQPairingModeResolver.resolvePairing(
            inputURL: inputFASTQ,
            pairsByName: true,
            metadataFrom: config.sourceBundleURL
        )
        return try FastpReadLayoutPlan.resolve(inputURL: inputFASTQ, decision: decision)
    }

    /// Places both mates of each fragment of `inputFASTQ` in cutadapt's
    /// plain outputs in `outputDirectory`. A custom dual kit matched in
    /// either orientation has an output per orientation, read as its
    /// sample's (review A S3).
    func placeMates(of inputFASTQ: URL, in outputDirectory: URL, config: DemultiplexConfig) throws -> DemultiplexMateCalls {
        let orientationOutputs = usesObservedCustomBarcodePairs(config)
        return try DemultiplexMatePass(
            inputFASTQ: inputFASTQ,
            outputDirectory: outputDirectory,
            unassignedName: "unassigned",
            sampleOf: { [self] name in orientationOutputs ? canonicalAdapterName(name) : name }
        ).run().summary
    }
}

/// Rewrites cutadapt's per-barcode outputs so that both mates of a fragment
/// sit in the output of the fragment's call (A9, D6).
///
/// cutadapt reads an interleaved file as single reads and writes each
/// record to the output of the barcode it matched, or to unassigned. Every
/// output keeps the input's order, so one pass over the input beside every
/// output finds the output each record went to. Adjacent records that are
/// mates by name (`FASTQReadLayoutClassifier.areMates`, the rule
/// `FASTQPairInterleaver.partitionMixed` splits by) are one fragment, and
/// `DemultiplexFragmentCall` decides where both go. A mate already in that
/// output keeps cutadapt's record, trimmed as cutadapt trimmed it. A mate
/// that comes from unassigned keeps cutadapt's record too, which no barcode
/// trimmed. The mates of a pair whose calls disagree go to unassigned as
/// the input holds them. Every output is rewritten in input order, so the
/// mates of a pair stay adjacent.
///
/// Each output is read through a window that reopens the file and written
/// through a buffer that reopens it, so a kit of hundreds of barcodes holds
/// a few file descriptors at a time and memory does not grow with the reads.
struct DemultiplexMatePass {
    /// The file cutadapt read, plain or gzip.
    let inputFASTQ: URL
    /// cutadapt's plain `<name>.fastq` outputs.
    let outputDirectory: URL
    /// The output name of reads without a barcode.
    let unassignedName: String
    /// The sample an output holds reads of. A custom dual kit matched in
    /// either orientation writes each orientation to its own output, and
    /// this pass places both into the sample's output in input order. The
    /// two used to be joined one after the other first, so the pass found
    /// read 2 out of order and failed the run (review A S3).
    var sampleOf: (String) -> String = { $0 }

    /// Places every fragment and returns how the mates were called.
    func run() throws -> DemultiplexMateCallCounter {
        let fm = FileManager.default
        let outputURLs = try fm.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "fastq" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let cursors = try outputURLs.map {
            try OrderedOutputCursor(name: $0.deletingPathExtension().lastPathComponent, url: $0)
        }
        var heads: [String: [Int]] = [:]
        for (index, cursor) in cursors.enumerated() {
            if let key = cursor.head.map(Self.matchKey) {
                heads[key, default: []].append(index)
            }
        }

        let rewriteDirectory = outputDirectory.appendingPathComponent(".mate-pass", isDirectory: true)
        try? fm.removeItem(at: rewriteDirectory)
        try fm.createDirectory(at: rewriteDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rewriteDirectory) }
        let names = Set(cursors.map { sampleOf($0.name) }).union([unassignedName])
        let flushThreshold = max(65_536, min(262_144, 33_554_432 / max(1, names.count)))
        var sinks: [String: AppendingFASTQSink] = [:]
        for name in names {
            sinks[name] = AppendingFASTQSink(url: rewriteDirectory.appendingPathComponent("\(name).fastq"))
        }

        var calls = DemultiplexMateCallCounter()
        var written = 0
        func write(_ record: RawFASTQRecord, to name: String) throws {
            try sinks[name]!.append(record, flushThreshold: flushThreshold)
            written += 1
        }
        func placeSingle(_ read: PlacedRead) throws {
            try write(read.output, to: read.outputName)
            calls.countSingleRead()
        }
        func placePair(_ first: PlacedRead, _ second: PlacedRead) throws {
            let decision = DemultiplexFragmentCall.call(call(of: first), call(of: second))
            let target = decision.call ?? unassignedName
            for mate in [first, second] {
                if mate.outputName == target || mate.outputName == unassignedName {
                    try write(mate.output, to: target)
                } else {
                    try write(mate.input, to: target)
                }
            }
            calls.count(decision.outcome)
        }

        let reader = try FASTQRawLineReader(url: inputFASTQ)
        defer { reader.close() }
        var inputRecords = 0
        var pending: PlacedRead?
        while let input = try Self.readRecord(from: reader, file: inputFASTQ.lastPathComponent, number: inputRecords + 1) {
            inputRecords += 1
            if inputRecords & 0x3FFF == 0 { try Task.checkCancellation() }
            let key = Self.matchKey(input)
            guard let index = Self.cursorIndex(for: input, key: key, heads: heads, cursors: cursors) else {
                throw DemultiplexError.outputParsingFailed(
                    "cutadapt's outputs do not hold input record \(inputRecords) (\(key)) in input order, so its mate could not be placed"
                )
            }
            let cursor = cursors[index]
            let output = cursor.head!
            heads[key]?.removeAll { $0 == index }
            if heads[key]?.isEmpty == true { heads[key] = nil }
            try cursor.advance()
            if let next = cursor.head {
                heads[Self.matchKey(next), default: []].append(index)
            }
            let placed = PlacedRead(input: input, output: output, outputName: sampleOf(cursor.name))
            if let previous = pending,
               FASTQReadLayoutClassifier.areMates(previous.input.headerText, input.headerText) {
                try placePair(previous, placed)
                pending = nil
            } else {
                if let previous = pending { try placeSingle(previous) }
                pending = placed
            }
        }
        if let previous = pending { try placeSingle(previous) }
        try Task.checkCancellation()
        if let leftover = cursors.first(where: { $0.head != nil }) {
            throw DemultiplexError.outputParsingFailed(
                "cutadapt's \(leftover.name) output holds records that the input does not, after \(inputRecords) input records"
            )
        }
        guard written == inputRecords else {
            throw DemultiplexError.outputParsingFailed(
                "placing mates wrote \(written) records where the input holds \(inputRecords)"
            )
        }

        for name in names {
            try sinks[name]!.flush()
            let original = outputDirectory.appendingPathComponent("\(name).fastq")
            let rewritten = rewriteDirectory.appendingPathComponent("\(name).fastq")
            if fm.fileExists(atPath: original.path) {
                try fm.removeItem(at: original)
            }
            if fm.fileExists(atPath: rewritten.path) {
                try fm.moveItem(at: rewritten, to: original)
            }
        }
        for cursor in cursors where sampleOf(cursor.name) != cursor.name {
            try fm.removeItem(at: cursor.url)
        }
        return calls
    }

    private func call(of read: PlacedRead) -> String? {
        read.outputName == unassignedName ? nil : read.outputName
    }

    /// The header a record is matched by, without the ` rc` cutadapt adds to
    /// a read it reverse complements.
    private static func matchKey(_ record: RawFASTQRecord) -> String {
        let header = record.headerText
        return header.hasSuffix(" rc") ? String(header.dropLast(3)) : header
    }

    /// The output whose next record is `input`. Records of the same header
    /// in several outputs are told apart by sequence.
    private static func cursorIndex(
        for input: RawFASTQRecord,
        key: String,
        heads: [String: [Int]],
        cursors: [OrderedOutputCursor]
    ) -> Int? {
        guard let candidates = heads[key], !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0] }
        let sequence = input.sequence
        if let exact = candidates.first(where: { cursors[$0].head?.sequence == sequence }) {
            return exact
        }
        // A trimmed record lies inside its input as sequenced, so every output
        // is tried that way before any is tried reversed. Read 2 of a fully
        // overlapping pair holds read 1 reversed, and mates named by one read
        // ID were written read 2 first when read 2's output came first
        // (review A S4).
        let heads = candidates.compactMap { index in
            cursors[index].head.map { (index: index, text: String(decoding: $0.sequence, as: UTF8.self)) }
        }
        let inputText = String(decoding: sequence, as: UTF8.self)
        if let forward = heads.first(where: { inputText.contains($0.text) }) {
            return forward.index
        }
        let inputReverse = String(decoding: RawFASTQRecord.reverseComplement(sequence), as: UTF8.self)
        if let reversed = heads.first(where: { inputReverse.contains($0.text) }) {
            return reversed.index
        }
        return candidates.min()
    }

    private static func readRecord(from reader: FASTQRawLineReader, file: String, number: Int) throws -> RawFASTQRecord? {
        guard let header = try reader.nextLine() else { return nil }
        guard let sequence = try reader.nextLine(),
              let plus = try reader.nextLine(),
              let quality = try reader.nextLine() else {
            throw DemultiplexError.outputParsingFailed("\(file) ends inside record \(number)")
        }
        return try RawFASTQRecord(lines: [header, sequence, plus, quality], file: file, number: number)
    }
}

/// One record of a mate-aware run as the input holds it, as cutadapt wrote
/// it, and the output cutadapt wrote it to.
private struct PlacedRead {
    let input: RawFASTQRecord
    let output: RawFASTQRecord
    let outputName: String
}

/// One FASTQ record's four lines, without their line ends.
struct RawFASTQRecord: Equatable {
    /// The header line without its leading `@`.
    let header: [UInt8]
    let sequence: [UInt8]
    /// The separator line, `+` and anything after it.
    let separator: [UInt8]
    let quality: [UInt8]

    init(lines: [[UInt8]], file: String, number: Int) throws {
        let lines = lines.map { $0.last == 0x0D ? Array($0.dropLast()) : $0 }
        guard lines[0].first == UInt8(ascii: "@"), lines[2].first == UInt8(ascii: "+") else {
            throw DemultiplexError.outputParsingFailed("record \(number) of \(file) is not a FASTQ record")
        }
        header = Array(lines[0].dropFirst())
        sequence = lines[1]
        separator = lines[2]
        quality = lines[3]
    }

    var headerText: String { String(decoding: header, as: UTF8.self) }

    var bytes: [UInt8] {
        [UInt8(ascii: "@")] + header + [0x0A] + sequence + [0x0A] + separator + [0x0A] + quality + [0x0A]
    }

    static func reverseComplement(_ sequence: [UInt8]) -> [UInt8] {
        sequence.reversed().map { base in
            switch base {
            case UInt8(ascii: "A"): return UInt8(ascii: "T")
            case UInt8(ascii: "T"): return UInt8(ascii: "A")
            case UInt8(ascii: "C"): return UInt8(ascii: "G")
            case UInt8(ascii: "G"): return UInt8(ascii: "C")
            case UInt8(ascii: "a"): return UInt8(ascii: "t")
            case UInt8(ascii: "t"): return UInt8(ascii: "a")
            case UInt8(ascii: "c"): return UInt8(ascii: "g")
            case UInt8(ascii: "g"): return UInt8(ascii: "c")
            default: return base
            }
        }
    }
}

/// Reads one cutadapt output record by record through a 64 KB window,
/// opening the file only to refill the window.
private final class OrderedOutputCursor {
    let name: String
    let url: URL
    /// The record the output holds next, or nil at its end.
    private(set) var head: RawFASTQRecord?
    private var offset: UInt64 = 0
    private var buffer: [UInt8] = []
    private var position = 0
    private var reachedEnd = false
    private var recordsRead = 0
    private static let windowSize = 65_536

    init(name: String, url: URL) throws {
        self.name = name
        self.url = url
        try advance()
    }

    func advance() throws {
        guard let header = try nextLine() else {
            head = nil
            return
        }
        guard let sequence = try nextLine(), let separator = try nextLine(), let quality = try nextLine() else {
            throw DemultiplexError.outputParsingFailed("cutadapt's \(name) output ends inside record \(recordsRead + 1)")
        }
        recordsRead += 1
        head = try RawFASTQRecord(lines: [header, sequence, separator, quality], file: url.lastPathComponent, number: recordsRead)
    }

    private func nextLine() throws -> [UInt8]? {
        while true {
            if let newline = buffer[position...].firstIndex(of: 0x0A) {
                let line = Array(buffer[position..<newline])
                position = newline + 1
                return line
            }
            if reachedEnd {
                guard position < buffer.count else { return nil }
                let line = Array(buffer[position...])
                position = buffer.count
                return line
            }
            try fill()
        }
    }

    private func fill() throws {
        if position > 0 {
            buffer.removeFirst(position)
            position = 0
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Self.windowSize) ?? Data()
        if data.isEmpty {
            reachedEnd = true
            return
        }
        offset += UInt64(data.count)
        buffer.append(contentsOf: data)
    }
}

/// Appends raw records to one file through a buffer, with the file closed
/// between flushes, as the statistics sink of the root rebuild does.
private struct AppendingFASTQSink {
    let url: URL
    private var buffer: [UInt8] = []
    private var created = false

    init(url: URL) {
        self.url = url
    }

    mutating func append(_ record: RawFASTQRecord, flushThreshold: Int) throws {
        buffer.append(contentsOf: record.bytes)
        if buffer.count >= flushThreshold {
            try flush()
        }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        if !created {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            created = true
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
