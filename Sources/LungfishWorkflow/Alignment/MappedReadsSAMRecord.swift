// MappedReadsSAMRecord.swift - SAM record conversion for annotation tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public struct MappedReadsSAMRecord: Sendable, Equatable {
    public let readName: String
    public let flag: UInt16
    public let referenceName: String
    public let start0: Int
    public let mapq: UInt8
    public let cigarString: String
    public let cigar: [CIGAROperation]
    public let mateReferenceName: String?
    public let matePosition0: Int?
    public let templateLength: Int
    public let sequence: String
    public let qualities: String
    public let auxiliaryTags: [String: String]

    public var referenceLength: Int {
        cigar.reduce(0) { $0 + ($1.consumesReference ? $1.length : 0) }
    }

    public var queryLength: Int {
        cigar.reduce(0) { $0 + ($1.consumesQuery ? $1.length : 0) }
    }

    public var end0: Int {
        start0 + referenceLength
    }

    public var editDistance: Int? {
        auxiliaryTags["NM"].flatMap(Int.init)
    }

    public var isPaired: Bool { hasFlag(0x1) }
    public var isProperPair: Bool { hasFlag(0x2) }
    public var isUnmapped: Bool { hasFlag(0x4) }
    public var isMateUnmapped: Bool { hasFlag(0x8) }
    public var isReverse: Bool { hasFlag(0x10) }
    public var isMateReverse: Bool { hasFlag(0x20) }
    public var isFirstInPair: Bool { hasFlag(0x40) }
    public var isSecondInPair: Bool { hasFlag(0x80) }
    public var isSecondary: Bool { hasFlag(0x100) }
    public var isDuplicate: Bool { hasFlag(0x400) }
    public var isSupplementary: Bool { hasFlag(0x800) }

    public static func parse(_ line: String) -> MappedReadsSAMRecord? {
        guard !line.isEmpty, !line.hasPrefix("@") else { return nil }

        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 11,
              let rawFlag = UInt16(fields[1]),
              let rawPosition = Int(fields[3]),
              rawPosition > 0,
              let rawMapq = UInt8(fields[4]),
              let rawTemplateLength = Int(fields[8]) else {
            return nil
        }

        let referenceName = String(fields[2])
        guard referenceName != "*" else { return nil }

        let cigarString = String(fields[5])
        guard let cigar = CIGAROperation.parse(cigarString) else { return nil }

        let mateReferenceField = String(fields[6])
        let mateReferenceName: String?
        switch mateReferenceField {
        case "*":
            mateReferenceName = nil
        case "=":
            mateReferenceName = referenceName
        default:
            mateReferenceName = mateReferenceField
        }

        let matePositionField = Int(fields[7]) ?? 0
        let matePosition0 = matePositionField > 0 ? matePositionField - 1 : nil

        var auxiliaryTags: [String: String] = [:]
        for field in fields.dropFirst(11) {
            let parts = field.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 2 else { continue }
            auxiliaryTags[String(parts[0])] = String(parts[2])
        }

        return MappedReadsSAMRecord(
            readName: String(fields[0]),
            flag: rawFlag,
            referenceName: referenceName,
            start0: rawPosition - 1,
            mapq: rawMapq,
            cigarString: cigarString,
            cigar: cigar,
            mateReferenceName: mateReferenceName,
            matePosition0: matePosition0,
            templateLength: rawTemplateLength,
            sequence: String(fields[9]),
            qualities: String(fields[10]),
            auxiliaryTags: auxiliaryTags
        )
    }

    public func annotationRow(
        sourceTrackID: String,
        sourceTrackName: String,
        request: MappedReadsAnnotationRequest
    ) -> MappedReadsAnnotationRow {
        var attributes: [String: String] = [
            "read_name": readName,
            "flag": String(flag),
            "mapq": String(mapq),
            "cigar": cigarString,
            "pos_1_based": String(start0 + 1),
            "alignment_start": String(start0),
            "alignment_end": String(end0),
            "reference_length": String(referenceLength),
            "query_length": String(queryLength),
            "template_length": String(templateLength),
            "is_paired": String(isPaired),
            "is_proper_pair": String(isProperPair),
            "is_reverse": String(isReverse),
            "is_mate_reverse": String(isMateReverse),
            "is_first_in_pair": String(isFirstInPair),
            "is_second_in_pair": String(isSecondInPair),
            "is_secondary": String(isSecondary),
            "is_supplementary": String(isSupplementary),
            "is_duplicate": String(isDuplicate),
            "source_alignment_track_id": sourceTrackID,
            "source_alignment_track_name": sourceTrackName,
        ]

        if let mateReferenceName {
            attributes["mate_reference"] = mateReferenceName
        }
        if let matePosition0 {
            attributes["mate_position_1_based"] = String(matePosition0 + 1)
        }
        if let readGroup = auxiliaryTags["RG"] {
            attributes["read_group"] = readGroup
        }
        for (tag, value) in auxiliaryTags {
            attributes["tag_\(tag)"] = value
        }
        if request.includeSequence {
            attributes["sequence"] = sequence
        }
        if request.includeQualities {
            attributes["qualities"] = qualities
        }

        return MappedReadsAnnotationRow(
            name: readName,
            type: "mapped_read",
            chromosome: referenceName,
            start: start0,
            end: end0,
            strand: isReverse ? "-" : "+",
            attributes: attributes
        )
    }

    private func hasFlag(_ mask: UInt16) -> Bool {
        flag & mask != 0
    }
}
