// PlatformInference.swift - The one sequencing-platform detector for FASTQ and BAM reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The sequencing platform inferred from a sample of reads, with the evidence.
///
/// This is the only platform detector. `lungfish-cli import fastq`, the Import
/// FASTQ sheet, mapping, assembly, Viral Recon, genotyping and the demultiplex
/// scout all call it, directly or through `SequencingPlatform.detect`.
///
/// It reads a bounded prefix of complete records, lets each record vote from
/// its header (read-name forms, MinKNOW keys, dorado SAM tags, PacBio movie
/// names and tags), and names a platform only when the votes agree. Reads that
/// disagree, short-read headers on long reads, and files with no recognised
/// header all give `.unknown`. Read length alone never names a platform. It is
/// recorded in ``lengthProfile`` so callers can choose length-based defaults.
public struct PlatformInference: Sendable, Equatable, Codable {

    /// How much the evidence supports the platform.
    public enum Confidence: String, Codable, Sendable, CaseIterable {
        case high
        case medium
        case low
        case none

        /// An unrecognised raw value decodes as `.none` instead of failing the
        /// whole sidecar, as ``SequencingPlatform`` does. Evidence of unknown
        /// strength is never acted on.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Confidence(rawValue: raw) ?? Confidence.none
        }
    }

    /// The read-length shape of the sampled reads.
    public enum LengthProfile: String, Codable, Sendable {
        /// Every sampled read is at most 600 bases (covers merged 2 x 300 pairs).
        case short
        /// A read is over 1,000 bases, or the mean is over 500 with a coefficient of variation over 0.3.
        case long
        /// Neither profile applies.
        case intermediate
    }

    /// `.unknown` unless confidence is high or medium.
    public var platform: SequencingPlatform
    /// `ontReads`, `pacBioHiFi`, `illuminaShortReads`, or nil.
    public var readClass: FASTQAssemblyReadType?
    /// Extra vendor detail, such as `ionTorrent` or `pacbioSubreads`.
    public var vendorDetail: String?
    public var confidence: Confidence
    /// Plain sentences shown to the user and stored with the bundle.
    public var evidence: [String]
    public var sampledRecords: Int
    /// The length shape of the sampled reads, nil when no length was seen.
    public var lengthProfile: LengthProfile?
    /// The longest sampled read, nil when no length was seen.
    public var maxSampledReadLength: Int?

    /// Bumped whenever a rule changes what a header infers.
    public static let detectorVersion = 1

    /// Vendor detail for Ion Torrent reads, recorded as an unknown platform.
    public static let ionTorrentDetail = "ionTorrent"
    /// Vendor detail for PacBio subreads (CLR), which have no assembly read type.
    public static let pacbioSubreadsDetail = "pacbioSubreads"

    public init(
        platform: SequencingPlatform,
        readClass: FASTQAssemblyReadType?,
        vendorDetail: String? = nil,
        confidence: Confidence,
        evidence: [String],
        sampledRecords: Int,
        lengthProfile: LengthProfile? = nil,
        maxSampledReadLength: Int? = nil
    ) {
        self.platform = platform
        self.readClass = readClass
        self.vendorDetail = vendorDetail
        self.confidence = confidence
        self.evidence = evidence
        self.sampledRecords = sampledRecords
        self.lengthProfile = lengthProfile
        self.maxSampledReadLength = maxSampledReadLength
    }

    /// Whether callers act on the platform (high or medium confidence, a named platform).
    public var isActionable: Bool {
        platform != .unknown && (confidence == .high || confidence == .medium)
    }

    /// One line for logs and the CLI, such as "Oxford Nanopore (high confidence)".
    public var summary: String {
        if platform == .unknown {
            if vendorDetail == Self.ionTorrentDetail { return "Unknown (Ion Torrent headers)" }
            return "Unknown"
        }
        return "\(platform.displayName) (\(confidence.rawValue) confidence)"
    }

    /// One sampled read: its header line, its length and its quality string.
    public struct Record: Sendable {
        public var header: String
        public var length: Int
        public var qualities: Substring?

        public init(header: String, length: Int, qualities: Substring? = nil) {
            self.header = header
            self.length = length
            self.qualities = qualities
        }
    }

    // MARK: - Entry points

    /// Infers the platform from the first `maxRecords` complete records of a
    /// plain, gzip or BGZF FASTQ file, decoding at most `maxBytes`.
    public static func infer(
        fromFASTQ url: URL,
        maxRecords: Int = 32,
        maxBytes: Int = 262_144
    ) -> PlatformInference {
        guard let data = GzipPrefixDecoder.decodedPrefix(of: url, maxBytes: maxBytes) else {
            return noRecords()
        }
        // Less than the bound means the whole file was read, so a last line
        // without a newline is complete.
        return infer(fromFASTQPrefix: data, maxRecords: maxRecords, isComplete: data.count < maxBytes)
    }

    /// Infers the platform from decoded FASTQ text. A partial last record is
    /// dropped unless `isComplete` says the text is the whole file.
    public static func infer(fromFASTQPrefix data: Data, maxRecords: Int = 32, isComplete: Bool = false) -> PlatformInference {
        let records = parseRecords(data, maxRecords: maxRecords, isComplete: isComplete)
        if records.isEmpty, let header = firstHeaderLine(data) {
            // No four-line record parses (wrapped sequence lines, for example),
            // so the first header votes alone with no length evidence.
            return infer(fromHeader: header)
        }
        return infer(records: records)
    }

    static func firstHeaderLine(_ data: Data) -> String? {
        let text = String(decoding: data.prefix(65_536), as: UTF8.self)
        guard let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              line.hasPrefix("@") else { return nil }
        return String(trimCR(line))
    }

    /// Infers the platform from one header line, with no length evidence.
    public static func infer(fromHeader header: String) -> PlatformInference {
        let trimmed = header.trimmingCharacters(in: .newlines)
        let stripped = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty else { return noRecords() }
        return infer(records: [Record(header: trimmed, length: 0)])
    }

    /// Infers the platform from sampled records. A length of 0 means "not known".
    public static func infer(records: [Record]) -> PlatformInference {
        guard !records.isEmpty else { return noRecords() }
        let votes = records.map { PlatformHeaderRules.vote(forHeader: $0.header) }
        let lengths = records.map(\.length).filter { $0 > 0 }
        return aggregate(votes: votes, lengths: lengths, sampled: records.count)
    }

    static func noRecords() -> PlatformInference {
        PlatformInference(
            platform: .unknown, readClass: nil, confidence: .none,
            evidence: ["No complete FASTQ records could be read."], sampledRecords: 0
        )
    }

    // MARK: - Record parsing

    static func parseRecords(_ data: Data, maxRecords: Int, isComplete: Bool = false) -> [Record] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // The last element follows the final newline or is a partial line.
        if !lines.isEmpty, !(isComplete && !text.hasSuffix("\n")) { lines.removeLast() }
        var records: [Record] = []
        var index = 0
        while index + 3 < lines.count, records.count < maxRecords {
            let header = trimCR(lines[index])
            let sequence = trimCR(lines[index + 1])
            let separator = trimCR(lines[index + 2])
            let qualities = trimCR(lines[index + 3])
            guard header.hasPrefix("@"), separator.hasPrefix("+") else { break }
            records.append(Record(header: String(header), length: sequence.count, qualities: qualities))
            index += 4
        }
        return records
    }

    private static func trimCR(_ line: Substring) -> Substring {
        line.hasSuffix("\r") ? line.dropLast() : line
    }

    // MARK: - Aggregation

    static func lengthProfile(of lengths: [Int]) -> LengthProfile? {
        guard !lengths.isEmpty else { return nil }
        let maxLength = lengths.max() ?? 0
        let mean = Double(lengths.reduce(0, +)) / Double(lengths.count)
        let variance = lengths.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(lengths.count)
        let cv = mean > 0 ? variance.squareRoot() / mean : 0
        if maxLength > 1_000 || (mean > 500 && cv > 0.3) { return .long }
        if maxLength <= 600 { return .short }
        return .intermediate
    }

    static func lengthSentence(_ lengths: [Int]) -> String? {
        guard let low = lengths.min(), let high = lengths.max() else { return nil }
        let range = low == high ? "\(formatted(low)) bases" : "\(formatted(low)) to \(formatted(high)) bases"
        return "Sampled reads are \(range) long."
    }

    static func formatted(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return (value < 0 ? "-" : "") + String(grouped.reversed())
    }

    static func aggregate(votes: [PlatformHeaderVote?], lengths: [Int], sampled: Int) -> PlatformInference {
        let profile = lengthProfile(of: lengths)
        let maxLength = lengths.max()
        var result = decide(votes: votes, lengths: lengths, sampled: sampled, profile: profile)
        result.lengthProfile = profile
        result.maxSampledReadLength = maxLength
        if let sentence = lengthSentence(lengths) {
            result.evidence.append(sentence)
        }
        return result
    }

    private static func decide(
        votes: [PlatformHeaderVote?],
        lengths: [Int],
        sampled: Int,
        profile: LengthProfile?
    ) -> PlatformInference {
        let vendorVotes = votes.compactMap { $0 }.filter { $0.vendor != .uuidName }
        let vendors = Set(vendorVotes.map(\.vendor))

        if vendors.count > 1 {
            let counts = PlatformHeaderVote.Vendor.allCases.compactMap { vendor -> String? in
                let count = vendorVotes.filter { $0.vendor == vendor }.count
                return count > 0 ? "\(count) look like \(vendor.label)" : nil
            }
            return PlatformInference(
                platform: .unknown, readClass: nil, confidence: .none,
                evidence: ["Read headers disagree. Of \(sampled) sampled reads, \(counts.joined(separator: ", "))."],
                sampledRecords: sampled
            )
        }

        guard let vendor = vendors.first else {
            return decideWithoutVendor(votes: votes, sampled: sampled, profile: profile)
        }

        let strong = vendorVotes.filter { $0.isStrong }.count
        let total = vendorVotes.count
        let confidence: Confidence
        if strong * 2 >= sampled {
            confidence = .high
        } else if total * 2 >= sampled {
            confidence = .medium
        } else {
            confidence = .low
        }
        let reasons = Array(Set(vendorVotes.map(\.reason))).sorted()
        var evidence = ["\(reasons.joined(separator: ", ")) in \(total) of \(sampled) sampled reads."]

        if vendor.isShortRead, let maxLength = lengths.max(), maxLength > 1_000 {
            evidence.append("\(vendor.label) headers on reads up to \(formatted(maxLength)) bases is a conflict, because that platform makes short reads.")
            return PlatformInference(
                platform: .unknown, readClass: nil, confidence: .none,
                evidence: evidence, sampledRecords: sampled
            )
        }

        guard confidence == .high || confidence == .medium else {
            evidence.append("Too few reads carry platform evidence to name a platform.")
            return PlatformInference(
                platform: .unknown, readClass: nil, confidence: .low,
                evidence: evidence, sampledRecords: sampled
            )
        }

        var vendorDetail: String?
        let readClass: FASTQAssemblyReadType?
        let platform: SequencingPlatform
        switch vendor {
        case .illumina:
            platform = .illumina
            readClass = .illuminaShortReads
        case .element:
            platform = .element
            readClass = .illuminaShortReads
        case .mgi:
            platform = .mgi
            readClass = .illuminaShortReads
        case .ont, .uuidName:
            platform = .oxfordNanopore
            readClass = .ontReads
        case .pacbio:
            platform = .pacbio
            let hifi = vendorVotes.filter { $0.pacbioKind == .hifi }.count
            let subreads = vendorVotes.filter { $0.pacbioKind == .subreads }.count
            if hifi * 2 > total {
                readClass = .pacBioHiFi
            } else {
                readClass = nil
                if subreads * 2 > total { vendorDetail = pacbioSubreadsDetail }
            }
        case .ionTorrent:
            // Not a first-class platform yet. Recorded as Unknown with the vendor named.
            return PlatformInference(
                platform: .unknown, readClass: nil, vendorDetail: ionTorrentDetail,
                confidence: confidence, evidence: evidence, sampledRecords: sampled
            )
        }
        return PlatformInference(
            platform: platform, readClass: readClass, vendorDetail: vendorDetail,
            confidence: confidence, evidence: evidence, sampledRecords: sampled
        )
    }

    private static func decideWithoutVendor(
        votes: [PlatformHeaderVote?],
        sampled: Int,
        profile: LengthProfile?
    ) -> PlatformInference {
        let uuidNames = votes.compactMap { $0 }.filter { $0.vendor == .uuidName }.count
        if uuidNames * 2 >= sampled, profile == .long {
            return PlatformInference(
                platform: .oxfordNanopore, readClass: .ontReads, confidence: .medium,
                evidence: ["UUID read names on long reads in \(uuidNames) of \(sampled) sampled reads, the form Oxford Nanopore basecallers write."],
                sampledRecords: sampled
            )
        }
        var evidence = ["The read headers match no known platform form (\(sampled) reads sampled)."]
        switch profile {
        case .long?:
            evidence.append("The reads look like long reads, but length alone does not name a platform.")
        case .short?:
            evidence.append("The reads look like short reads, but length alone does not name a platform.")
        case .intermediate?, nil:
            break
        }
        return PlatformInference(
            platform: .unknown, readClass: nil, confidence: profile == nil ? .none : .low,
            evidence: evidence, sampledRecords: sampled
        )
    }
}
