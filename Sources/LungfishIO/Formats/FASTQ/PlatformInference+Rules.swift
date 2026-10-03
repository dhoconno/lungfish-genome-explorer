// PlatformInference+Rules.swift - Per-read header rules of the platform detector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What one read header says about its platform.
struct PlatformHeaderVote: Sendable, Equatable {
    enum Vendor: String, CaseIterable, Sendable {
        case illumina, element, mgi, ionTorrent, ont, pacbio
        /// A bare UUID read name. Counts towards ONT only on long reads.
        case uuidName

        var label: String {
            switch self {
            case .illumina: return "Illumina"
            case .element: return "Element AVITI"
            case .mgi: return "MGI DNBSEQ"
            case .ionTorrent: return "Ion Torrent"
            case .ont: return "Oxford Nanopore"
            case .pacbio: return "PacBio"
            case .uuidName: return "UUID read names"
            }
        }

        var isShortRead: Bool {
            switch self {
            case .illumina, .element, .mgi, .ionTorrent: return true
            case .ont, .pacbio, .uuidName: return false
            }
        }
    }

    enum PacBioKind: Sendable, Equatable { case hifi, subreads, other }

    var vendor: Vendor
    var isStrong: Bool
    /// A short phrase naming the evidence, shared by every read with the same form.
    var reason: String
    var pacbioKind: PacBioKind? = nil
}

/// The per-read rules. Each rule names a header form that only one platform writes.
enum PlatformHeaderRules {

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals checked by the tests, so a failure is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    // Illumina CASAVA 1.8 and later. Optional UMI field and ENA or SRA mate suffix.
    private static let casava = regex(#"^([A-Za-z0-9_-]+):\d+:[A-Za-z0-9-]+:\d+:\d+:\d+:\d+(:[ACGTN+]+)?(/[12])?$"#)
    // Illumina before CASAVA 1.8.
    private static let casavaPre18 = regex(#"^[A-Za-z0-9_-]+:\d+:\d+:\d+:\d+#[^/\s]*/[12]$"#)
    // Known Illumina instrument name forms.
    private static let illuminaInstrument = regex(#"^((MN|NB|NS|VH|VL|FS|LH|SH|SN|A|M|D|K|J|E|C)\d{3,}[A-Za-z]?|HWI-[A-Za-z0-9-]+|HWUSI-[A-Za-z0-9-]+|ST-E\d+)$"#)
    private static let elementInstrument = regex(#"^AV\d+$"#)
    // The bcl2fastq read comment, such as 1:N:0:ACGTACGT+TTAGGC.
    private static let casavaComment = regex(#"^[12]:[YN]:\d+:[A-Za-z0-9+]*$"#)
    private static let mgi = regex(#"^[A-Z]{1,2}\d{8,10}L\d+C\d{3}R\d{3}_?\d+(/[12])?$"#)
    private static let ionTorrent = regex(#"^[A-Z0-9]{5}:\d{1,5}:\d{1,5}$"#)
    // PacBio movie names: Sequel (m54...), Sequel II (m64...), IIe (m64...e), Revio (m84..._s1).
    private static let pacbioCCS = regex(#"^m\d+[a-z]?_\d{6}_\d{6}(_s\d+)?/\d+/ccs(/fwd|/rev)?$"#)
    private static let pacbioSubread = regex(#"^m\d+[a-z]?_\d{6}_\d{6}(_s\d+)?/\d+/\d+_\d+$"#)
    private static let renamedCCS = regex(#"^[^/\s]+/\d+/ccs(/fwd|/rev)?$"#)
    private static let uuid = regex(#"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#)
    private static let doradoModel = regex(#"(_dna_r|_rna\d|_rna_|@v\d)"#)

    private static let minKNOWKeys = [
        "flow_cell_id=", "ch=", "read=", "start_time=", "basecall_model_version_id=",
        "model_version_id=", "basecall_gpu=", "protocol_group_id=", "parent_read_id=",
    ]
    private static let doradoTags = [
        "ch:i:", "st:Z:", "rn:i:", "fn:Z:", "mx:i:", "du:f:", "ns:i:", "ts:i:",
        "sm:f:", "sd:f:", "sv:Z:", "dx:i:", "pi:Z:",
    ]

    /// The vote of one header line, or nil when it names no platform.
    static func vote(forHeader rawHeader: String) -> PlatformHeaderVote? {
        let header = rawHeader.hasPrefix("@") ? String(rawHeader.dropFirst()) : rawHeader
        let tokens = header.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let name = tokens.first else { return nil }
        let rest = Array(tokens.dropFirst())

        if let vote = ontVote(name: name, rest: rest) { return vote }
        if let vote = pacbioVote(name: name, rest: rest) { return vote }
        if let vote = shortReadVote(name: name, rest: rest) { return vote }
        if rest.isEmpty, matches(uuid, name) != nil {
            return PlatformHeaderVote(vendor: .uuidName, isStrong: false, reason: "UUID read names")
        }
        return nil
    }

    private static func ontVote(name: String, rest: [String]) -> PlatformHeaderVote? {
        let hasRunID = rest.contains { $0.hasPrefix("runid=") }
        let keys = rest.filter { token in minKNOWKeys.contains { token.hasPrefix($0) } }
        if hasRunID {
            return PlatformHeaderVote(
                vendor: .ont, isStrong: !keys.isEmpty,
                reason: keys.isEmpty ? "MinKNOW runid key" : "MinKNOW header keys (runid and others)"
            )
        }
        if rest.contains(where: { $0.hasPrefix("basecall_model_version_id=") || $0.hasPrefix("basecall_gpu=") }) {
            return PlatformHeaderVote(vendor: .ont, isStrong: true, reason: "ONT basecaller header keys")
        }
        let tags = Set(rest.compactMap { token in doradoTags.first { token.hasPrefix($0) } })
        let readGroup = rest.first { $0.hasPrefix("RG:Z:") }
        let doradoReadGroup = readGroup.map { matches(doradoModel, $0) != nil } ?? false
        if tags.count >= 2 || doradoReadGroup {
            return PlatformHeaderVote(vendor: .ont, isStrong: true, reason: "dorado SAM tags")
        }
        return nil
    }

    private static func pacbioVote(name: String, rest: [String]) -> PlatformHeaderVote? {
        if matches(pacbioCCS, name) != nil {
            return PlatformHeaderVote(vendor: .pacbio, isStrong: true, reason: "PacBio CCS movie names", pacbioKind: .hifi)
        }
        if matches(pacbioSubread, name) != nil {
            return PlatformHeaderVote(vendor: .pacbio, isStrong: true, reason: "PacBio subread movie names", pacbioKind: .subreads)
        }
        let readQuality = rest.first { $0.hasPrefix("rq:f:") }.flatMap { Double($0.dropFirst(5)) }
        let hasPasses = rest.contains { $0.hasPrefix("np:i:") }
        let hasZMW = rest.contains { $0.hasPrefix("zm:i:") }
        let renamedCCSName = matches(renamedCCS, name) != nil
        guard (readQuality != nil && (hasPasses || hasZMW)) || hasZMW else {
            // A CCS read name without a movie name, such as movie/12/ccs.
            return renamedCCSName
                ? PlatformHeaderVote(vendor: .pacbio, isStrong: false, reason: "PacBio CCS read names", pacbioKind: .hifi)
                : nil
        }
        let strong = renamedCCSName
        let kind: PlatformHeaderVote.PacBioKind
        if let readQuality {
            kind = readQuality >= 0.99 ? .hifi : .other
        } else {
            kind = strong ? .hifi : .other
        }
        return PlatformHeaderVote(vendor: .pacbio, isStrong: strong, reason: "PacBio read tags (np, rq, zm)", pacbioKind: kind)
    }

    private static func shortReadVote(name: String, rest: [String]) -> PlatformHeaderVote? {
        for (index, candidate) in ([name] + rest.prefix(1)).enumerated() {
            guard let match = matches(casava, candidate),
                  let instrumentRange = Range(match.range(at: 1), in: candidate) else { continue }
            let instrument = String(candidate[instrumentRange])
            let renamed = index == 1 ? " (original names kept by ENA or SRA)" : ""
            if matches(elementInstrument, instrument) != nil {
                return PlatformHeaderVote(vendor: .element, isStrong: true, reason: "Element AVITI read names\(renamed)")
            }
            let known = matches(illuminaInstrument, instrument) != nil
            return PlatformHeaderVote(
                vendor: .illumina, isStrong: known,
                reason: known ? "Illumina read names\(renamed)" : "Illumina-form read names with an unrecognised instrument\(renamed)"
            )
        }
        if matches(casavaPre18, name) != nil {
            return PlatformHeaderVote(vendor: .illumina, isStrong: true, reason: "Illumina read names (before CASAVA 1.8)")
        }
        if matches(mgi, name) != nil {
            return PlatformHeaderVote(vendor: .mgi, isStrong: true, reason: "MGI DNBSEQ read names")
        }
        if matches(ionTorrent, name) != nil {
            return PlatformHeaderVote(vendor: .ionTorrent, isStrong: false, reason: "Ion Torrent read names")
        }
        if let comment = rest.first, matches(casavaComment, comment) != nil {
            return PlatformHeaderVote(vendor: .illumina, isStrong: false, reason: "Illumina read comments (1:N:0)")
        }
        return nil
    }
}
