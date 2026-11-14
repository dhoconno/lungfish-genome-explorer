// SequencerInstrumentScan.swift - Reads the instrument facts out of read names, one name at a time
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension SequencerInstrument {

    /// The facts one read name carries. `keyLength` is the UTF-8 length of the head of the facts token that decides
    /// them, with the byte after the lane, so a later name with the same head carries the same facts.
    struct NameFacts {
        var form: NameForm
        var instrumentID: String?
        var run: Int?
        var flowcell: String?
        var lane: Int
        var keyLength: Int
    }

    /// The token of a header that holds the facts. After an ENA or SRA accession it is the second token.
    static func factsToken(in header: String) -> Substring {
        guard let space = header.utf8.firstIndex(of: 0x20) else { return header[...] }
        let first = header[..<space]
        if first.utf8.contains(0x3A) { return first }
        let rest = header[header.index(after: space)...]
        if let next = rest.utf8.firstIndex(of: 0x20) { return rest[..<next] }
        return rest
    }

    static func parse(token: Substring) -> NameFacts? {
        guard token.utf8.contains(0x3A) else { return mgi(token) }
        let fields = token.split(separator: ":", omittingEmptySubsequences: false)
        if fields.count >= 7 { return casava18(fields) }
        if fields.count == 5 { return beforeCasava18(fields) }
        return nil
    }

    /// `Swift.Sequence` is named in full, since LungfishCore declares a `Sequence` type of its own.
    private static func isDigits<S: Swift.Sequence>(_ text: S) -> Bool where S.Element == UInt8 {
        var seen = false
        for byte in text {
            guard byte >= 0x30, byte <= 0x39 else { return false }
            seen = true
        }
        return seen
    }

    /// A word of letters, digits, dashes and underscores. An instrument id starts with a letter.
    private static func isWord(_ text: Substring, startsWithLetter: Bool) -> Bool {
        guard let first = text.utf8.first else { return false }
        if startsWithLetter, !((first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A)) { return false }
        return text.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    /// The digits at the head of a last field, before `/1` or `#index`.
    private static func headDigits(_ field: Substring) -> Bool {
        isDigits(field.utf8.prefix { $0 != 0x2F && $0 != 0x23 })
    }

    private static func casava18(_ f: [Substring]) -> NameFacts? {
        guard isWord(f[0], startsWithLetter: true), isDigits(f[1].utf8), isWord(f[2], startsWithLetter: false),
              isDigits(f[3].utf8), isDigits(f[4].utf8), isDigits(f[5].utf8), headDigits(f[6]),
              let run = Int(f[1]), let lane = Int(f[3]) else { return nil }
        let key = f[0].utf8.count + f[1].utf8.count + f[2].utf8.count + f[3].utf8.count + 4
        return NameFacts(form: .casava18, instrumentID: String(f[0]), run: run, flowcell: String(f[2]), lane: lane, keyLength: key)
    }

    private static func beforeCasava18(_ f: [Substring]) -> NameFacts? {
        guard isWord(f[0], startsWithLetter: true), isDigits(f[1].utf8), isDigits(f[2].utf8), isDigits(f[3].utf8),
              headDigits(f[4]), let lane = Int(f[1]) else { return nil }
        return NameFacts(
            form: .illuminaBeforeCasava18, instrumentID: String(f[0]), run: nil, flowcell: nil, lane: lane,
            keyLength: f[0].utf8.count + f[1].utf8.count + 2
        )
    }

    /// `FLOWCELL` `L` lane `C` column `R` row and the read number, as in `V300012345L1C001R001000001/1`. A flow cell id
    /// can hold an `L` (`CL100074567`), so every `L` is tried until the whole pattern fits.
    private static func mgi(_ token: Substring) -> NameFacts? {
        let bytes = Array(token.utf8)
        guard bytes.count > 8, bytes[0] >= 0x41, bytes[0] <= 0x5A else { return nil }
        func digitsEnd(_ start: Int) -> Int {
            var end = start
            while end < bytes.count, bytes[end] >= 0x30, bytes[end] <= 0x39 { end += 1 }
            return end
        }
        for l in 1..<bytes.count where bytes[l] == 0x4C {
            let laneEnd = digitsEnd(l + 1)
            guard laneEnd > l + 1, laneEnd < bytes.count, bytes[laneEnd] == 0x43 else { continue }
            let columnEnd = digitsEnd(laneEnd + 1)
            guard columnEnd > laneEnd + 1, columnEnd + 1 < bytes.count, bytes[columnEnd] == 0x52,
                  bytes[columnEnd + 1] >= 0x30, bytes[columnEnd + 1] <= 0x39 else { continue }
            let flowcell = String(decoding: bytes[0..<l], as: UTF8.self)
            guard isWord(Substring(flowcell), startsWithLetter: true),
                  let lane = Int(String(decoding: bytes[(l + 1)..<laneEnd], as: UTF8.self)) else { continue }
            return NameFacts(form: .mgi, instrumentID: nil, run: nil, flowcell: flowcell, lane: lane, keyLength: laneEnd + 1)
        }
        return nil
    }
}

/// Collects the instrument facts of every read name of a scan. A name whose head equals the last name's head is not
/// parsed again, so a file whose names change only after the lane costs a byte compare a read.
public struct SequencerInstrumentScan: Sendable {
    private var forms: [SequencerInstrument.NameForm] = []
    private var instrumentIDs: [String] = []
    private var runNumbers: [Int] = []
    private var flowcells: [String] = []
    private var lanes: [Int] = []
    private var named = 0
    private var unnamed = 0
    private var truncated = false
    private var lastToken = ""
    private var lastKeyLength = 0

    public init() {}

    /// Takes one header, with or without its leading `@`.
    public mutating func observe(header: String) {
        let token = SequencerInstrument.factsToken(in: header)
        if lastKeyLength > 0, token.utf8.starts(with: lastToken.utf8.prefix(lastKeyLength)) {
            named += 1
            return
        }
        guard let facts = SequencerInstrument.parse(token: token) else {
            unnamed += 1
            return
        }
        named += 1
        if !forms.contains(facts.form) { forms.append(facts.form) }
        if let id = facts.instrumentID, Self.add(id, to: &instrumentIDs) { truncated = true }
        if let run = facts.run, Self.add(run, to: &runNumbers) { truncated = true }
        if let flowcell = facts.flowcell, Self.add(flowcell, to: &flowcells) { truncated = true }
        if Self.add(facts.lane, to: &lanes) { truncated = true }
        lastToken = String(token)
        lastKeyLength = facts.keyLength
    }

    /// Adds a new value. True when the list is full and the value was left out.
    private static func add<Value: Equatable>(_ value: Value, to list: inout [Value]) -> Bool {
        guard !list.contains(value) else { return false }
        guard list.count < SequencerInstrument.listLimit else { return true }
        list.append(value)
        return false
    }

    public func result() -> SequencerInstrument {
        let models = instrumentIDs.map { SequencerInstrumentModels.model(forInstrumentID: $0) ?? SequencerInstrument.unknownModel }
        return SequencerInstrument(
            nameForm: named > 0 ? (forms.first ?? .notRecorded) : .notRecorded,
            instrumentIDs: instrumentIDs, runNumbers: runNumbers, flowcells: flowcells, lanes: lanes.sorted(),
            models: models, modelsAreInferred: true, modelSource: instrumentIDs.isEmpty ? "" : SequencerInstrumentModels.source,
            namedRecords: named, unnamedRecords: unnamed, listsTruncated: truncated
        )
    }
}
