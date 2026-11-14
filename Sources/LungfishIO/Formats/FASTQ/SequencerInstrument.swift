// SequencerInstrument.swift - The instrument, run, flow cell and lanes the read names of a FASTQ file carry
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What the read names of a FASTQ file say about the sequencer (row RS-INSTRUMENT).
///
/// Illumina CASAVA 1.8 names (`INSTRUMENT:RUN:FLOWCELL:LANE:TILE:X:Y`, also behind an ENA or SRA accession) give the
/// instrument id, run, flow cell and lane. Names before CASAVA 1.8 give the instrument id and the lane, and MGI names
/// give the flow cell and the lane. A name SRA rewrote gives nothing and reads Not recorded. The model is never read
/// from the run. ``SequencerInstrumentModels`` infers it from the instrument id, so it stays marked inferred, and an id
/// that table does not list reads Unknown.
public struct SequencerInstrument: Codable, Sendable, Equatable {

    /// The name form the facts were read from.
    public enum NameForm: String, Codable, Sendable, CaseIterable {
        case casava18
        case illuminaBeforeCasava18
        case mgi
        case notRecorded

        /// A form a later release recorded decodes as `.notRecorded` instead of failing the whole sidecar.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = NameForm(rawValue: raw) ?? .notRecorded
        }
    }

    public static let unknownModel = "Unknown"
    /// The most distinct values a list keeps. Past it `listsTruncated` is true.
    public static let listLimit = 16

    /// The form of the first name that carried facts. `.notRecorded` when none did.
    public var nameForm: NameForm
    /// Distinct values in order of first appearance. Empty when the names carry none.
    public var instrumentIDs: [String]
    public var runNumbers: [Int]
    public var flowcells: [String]
    /// Distinct lanes, smallest first.
    public var lanes: [Int]
    /// The model of each instrument id, in the same order, or `Unknown`.
    public var models: [String]
    /// Always true, since a model comes from a table keyed on the instrument id and is never read from the run.
    public var modelsAreInferred: Bool
    /// The source the table cites. Empty when no model was looked up.
    public var modelSource: String
    /// Reads whose name carried the facts, and reads whose name did not.
    public var namedRecords: Int
    public var unnamedRecords: Int
    public var listsTruncated: Bool

    /// The words a person reads.
    public var summary: String {
        guard nameForm != .notRecorded else { return "Not recorded" }
        guard !instrumentIDs.isEmpty else { return Self.unknownModel }
        return zip(instrumentIDs, models).map { id, model in
            model == Self.unknownModel ? "Unknown (instrument id \(id))" : "\(model) (inferred from instrument id \(id))"
        }.joined(separator: ", ")
    }
}

/// The model of an instrument, inferred from the serial-number prefix of its id.
///
/// The prefixes are the naming convention that public run records use for Illumina instruments and for the Element
/// AVITI. It is not a vendor table. BIO checks each row against vendor documentation in review (lane RS-INSTRUMENT).
public enum SequencerInstrumentModels {

    public static let source = "Serial-number prefix convention of Illumina instruments and the Element AVITI, as public run "
        + "records use it. A naming convention and not a vendor table, so each model is inferred from the instrument id."

    /// Longer prefixes come first. A row with `digitsOnly` matches an id of the prefix and three or more digits alone,
    /// as PlatformInference+Rules.swift does, so a short lab name reads Unknown.
    private static let rows: [(prefix: String, digitsOnly: Bool, model: String)] = [
        ("HWUSI-", false, "Genome Analyzer"), ("HWI-ST", false, "HiSeq 2000 or 2500"), ("HWI-D", false, "HiSeq 2500"),
        ("SN", true, "HiSeq 2000 or 2500"), ("NS", true, "NextSeq 500"), ("NB", true, "NextSeq 550"),
        ("VH", true, "NextSeq 1000 or 2000"), ("LH", true, "NovaSeq X"), ("FS", true, "iSeq 100"),
        ("MN", true, "MiniSeq"), ("AV", true, "AVITI"), ("M", true, "MiSeq"), ("D", true, "HiSeq 2500"),
        ("J", true, "HiSeq 3000"), ("K", true, "HiSeq 3000 or 4000"), ("E", true, "HiSeq X"), ("A", true, "NovaSeq 6000"),
    ]

    /// The model of `id`, or nil when the table does not list it (read as Unknown).
    public static func model(forInstrumentID id: String) -> String? {
        for row in rows where id.hasPrefix(row.prefix) {
            if !row.digitsOnly { return row.model }
            let rest = id.dropFirst(row.prefix.count)
            if rest.utf8.count >= 3, rest.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) { return row.model }
        }
        return nil
    }
}
