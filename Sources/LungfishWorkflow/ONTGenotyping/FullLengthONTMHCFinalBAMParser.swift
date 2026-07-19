import Foundation
import LungfishIO

public struct FullLengthONTMHCFinalBAMSampleContext: Sendable, Equatable {
    public let sampleID: String
    public let readGroupID: String?
    public let clusterRecords: [FullLengthONTMHCClusterFASTARecord]

    public init(
        sampleID: String,
        readGroupID: String?,
        clusterRecords: [FullLengthONTMHCClusterFASTARecord]
    ) {
        self.sampleID = sampleID
        self.readGroupID = readGroupID
        self.clusterRecords = clusterRecords
    }
}

public enum FullLengthONTMHCFinalBAMRecordLifecycleEvent: Sendable, Equatable {
    case willProcess(lineNumber: Int)
    case didProcess(lineNumber: Int)
}

public struct FullLengthONTMHCFinalBAMValidationError: Error, LocalizedError, Sendable, Equatable {
    public let samPath: String
    public let lineNumber: Int?
    public let message: String
    public let context: String?

    public var errorDescription: String? {
        var description = "Final BAM SAM validation failed"
        if let lineNumber {
            description += " at line \(lineNumber)"
        }
        description += " in \(samPath): \(message)"
        if let context, !context.isEmpty {
            description += " [context: \(context)]"
        }
        return description
    }
}

public struct FullLengthONTMHCFinalBAMParser: @unchecked Sendable {
    private struct Target {
        let sampleID: String
        let clusterID: String
        let sequenceLength: Int
    }

    private struct OptionalTag {
        let name: String
        let type: Character
        let value: String
    }

    private let recordLifecycleObserver: @Sendable (FullLengthONTMHCFinalBAMRecordLifecycleEvent) -> Void

    public init(
        recordLifecycleObserver: @escaping @Sendable (FullLengthONTMHCFinalBAMRecordLifecycleEvent) -> Void = { _ in }
    ) {
        self.recordLifecycleObserver = recordLifecycleObserver
    }

    public func genotypeSummaries(
        samURL: URL,
        referenceFASTAURL: URL,
        samples: [FullLengthONTMHCFinalBAMSampleContext],
        cdnaThreshold: Int = 2_000,
        minUnmatchedReads: Int = 5
    ) throws -> [String: FullLengthONTMHCClusterGenotypingSummary] {
        let standardizedSAMURL = samURL.standardizedFileURL
        let referenceRecords = try FullLengthONTMHCClusterGenotyper.readFASTARecords(
            from: referenceFASTAURL.standardizedFileURL
        )
        var referenceLengths: [String: Int] = [:]
        for record in referenceRecords {
            guard !record.name.isEmpty, !record.sequence.isEmpty else {
                throw validationError(
                    samURL: standardizedSAMURL,
                    message: "Resolved reference FASTA contains an empty allele name or sequence."
                )
            }
            guard referenceLengths.updateValue(record.sequence.count, forKey: record.name) == nil else {
                throw validationError(
                    samURL: standardizedSAMURL,
                    message: "Resolved reference FASTA contains duplicate allele QNAME '\(record.name)'."
                )
            }
        }
        guard !referenceLengths.isEmpty else {
            throw validationError(
                samURL: standardizedSAMURL,
                message: "Resolved reference FASTA contains no alleles."
            )
        }

        var targets: [String: Target] = [:]
        var expectedReadGroupSamples: [String: String] = [:]
        var accumulators: [String: FullLengthONTMHCClusterGenotyper.StreamingAccumulator] = [:]
        for sample in samples {
            guard !sample.sampleID.isEmpty, accumulators[sample.sampleID] == nil else {
                throw validationError(
                    samURL: standardizedSAMURL,
                    message: "Sample declarations contain an empty or duplicate sample ID '\(sample.sampleID)'."
                )
            }
            if let readGroupID = sample.readGroupID {
                guard !readGroupID.isEmpty,
                      expectedReadGroupSamples.updateValue(sample.sampleID, forKey: readGroupID) == nil else {
                    throw validationError(
                        samURL: standardizedSAMURL,
                        message: "Sample declarations contain an empty or duplicate read group ID '\(readGroupID)'."
                    )
                }
            } else if !sample.clusterRecords.isEmpty {
                throw validationError(
                    samURL: standardizedSAMURL,
                    message: "Sample '\(sample.sampleID)' has declared clusters but no declared read group."
                )
            }
            var clusterIDs = Set<String>()
            for cluster in sample.clusterRecords {
                guard !cluster.name.isEmpty,
                      !cluster.sequence.isEmpty,
                      clusterIDs.insert(cluster.name).inserted else {
                    throw validationError(
                        samURL: standardizedSAMURL,
                        message: "Sample '\(sample.sampleID)' contains an empty or duplicate cluster record '\(cluster.name)'."
                    )
                }
                let namespacedID = "\(sample.sampleID)|\(cluster.name)"
                guard targets.updateValue(
                    Target(
                        sampleID: sample.sampleID,
                        clusterID: cluster.name,
                        sequenceLength: cluster.sequence.count
                    ),
                    forKey: namespacedID
                ) == nil else {
                    throw validationError(
                        samURL: standardizedSAMURL,
                        message: "Sample declarations contain duplicate target '\(namespacedID)'."
                    )
                }
            }
            accumulators[sample.sampleID] = .init(
                sampleID: sample.sampleID,
                clusterRecords: sample.clusterRecords,
                referenceLengths: referenceLengths,
                cdnaThreshold: cdnaThreshold,
                minUnmatchedReads: minUnmatchedReads
            )
        }

        var declaredReadGroupSamples: [String: String] = [:]
        var declaredSequenceLengths: [String: Int] = [:]
        var lineNumber = 0
        var observedAlignment = false
        try standardizedSAMURL.forEachLineAutoDecompressing { rawLine in
            try Task.checkCancellation()
            lineNumber += 1
            guard !rawLine.isEmpty else { return }
            if rawLine.hasPrefix("@") {
                guard !observedAlignment else {
                    throw lineError(
                        samURL: standardizedSAMURL,
                        lineNumber: lineNumber,
                        message: "SAM header appears after the first alignment record.",
                        context: rawLine
                    )
                }
                try validateHeader(
                    rawLine,
                    samURL: standardizedSAMURL,
                    lineNumber: lineNumber,
                    targets: targets,
                    expectedReadGroupSamples: expectedReadGroupSamples,
                    declaredReadGroupSamples: &declaredReadGroupSamples,
                    declaredSequenceLengths: &declaredSequenceLengths
                )
                return
            }

            observedAlignment = true
            recordLifecycleObserver(.willProcess(lineNumber: lineNumber))
            defer { recordLifecycleObserver(.didProcess(lineNumber: lineNumber)) }
            try validateAndConsumeAlignment(
                rawLine,
                samURL: standardizedSAMURL,
                lineNumber: lineNumber,
                referenceLengths: referenceLengths,
                targets: targets,
                declaredSequenceLengths: declaredSequenceLengths,
                declaredReadGroupSamples: declaredReadGroupSamples,
                accumulators: &accumulators
            )
        }

        if let missingTarget = Set(targets.keys)
            .subtracting(declaredSequenceLengths.keys)
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            .first {
            throw validationError(
                samURL: standardizedSAMURL,
                message: "Final BAM header is missing expected @SQ SN '\(missingTarget)'."
            )
        }
        if let missingReadGroup = Set(expectedReadGroupSamples.keys)
            .subtracting(declaredReadGroupSamples.keys)
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            .first {
            throw validationError(
                samURL: standardizedSAMURL,
                message: "Final BAM header is missing expected @RG ID '\(missingReadGroup)'."
            )
        }
        try Task.checkCancellation()

        return Dictionary(uniqueKeysWithValues: accumulators.map { ($0.key, $0.value.summary()) })
    }

    private func validateHeader(
        _ line: String,
        samURL: URL,
        lineNumber: Int,
        targets: [String: Target],
        expectedReadGroupSamples: [String: String],
        declaredReadGroupSamples: inout [String: String],
        declaredSequenceLengths: inout [String: Int]
    ) throws {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let recordType = fields.first,
              ["@HD", "@SQ", "@RG", "@PG", "@CO"].contains(recordType) else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Unknown or malformed SAM header record.",
                context: line
            )
        }
        guard recordType == "@SQ" || recordType == "@RG" else { return }
        var tags: [String: String] = [:]
        for field in fields.dropFirst() {
            let pieces = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, !pieces[0].isEmpty else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "Malformed \(recordType) tag '\(field)'.",
                    context: line
                )
            }
            let name = String(pieces[0])
            guard tags.updateValue(String(pieces[1]), forKey: name) == nil else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "Duplicate \(recordType) tag '\(name)'.",
                    context: line
                )
            }
        }

        if recordType == "@SQ" {
            guard let sequenceName = tags["SN"],
                  let rawLength = tags["LN"],
                  let length = Int(rawLength),
                  length > 0 else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "@SQ requires valid SN and positive LN tags.",
                    context: line
                )
            }
            guard let target = targets[sequenceName] else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "@SQ declares unknown target '\(sequenceName)'.",
                    context: line
                )
            }
            guard target.sequenceLength == length else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "@SQ length \(length) does not match declared target length \(target.sequenceLength) for '\(sequenceName)'.",
                    context: line
                )
            }
            guard declaredSequenceLengths.updateValue(length, forKey: sequenceName) == nil else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "duplicate @SQ SN '\(sequenceName)'.",
                    context: line
                )
            }
            return
        }

        guard let readGroupID = tags["ID"], !readGroupID.isEmpty,
              let sample = tags["SM"], !sample.isEmpty else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "@RG requires non-empty ID and SM tags.",
                context: line
            )
        }
        if let existing = declaredReadGroupSamples[readGroupID] {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: existing == sample
                    ? "duplicate @RG ID '\(readGroupID)'."
                    : "conflicting @RG ID '\(readGroupID)' declares both '\(existing)' and '\(sample)'.",
                context: line
            )
        }
        guard let expectedSample = expectedReadGroupSamples[readGroupID] else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "@RG declares unknown read group ID '\(readGroupID)'.",
                context: line
            )
        }
        guard sample == expectedSample else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "@RG ID '\(readGroupID)' declares sample '\(sample)' but expected '\(expectedSample)'.",
                context: line
            )
        }
        declaredReadGroupSamples[readGroupID] = sample
    }

    private func validateAndConsumeAlignment(
        _ line: String,
        samURL: URL,
        lineNumber: Int,
        referenceLengths: [String: Int],
        targets: [String: Target],
        declaredSequenceLengths: [String: Int],
        declaredReadGroupSamples: [String: String],
        accumulators: inout [String: FullLengthONTMHCClusterGenotyper.StreamingAccumulator]
    ) throws {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 11 else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has \(fields.count) fields; SAM requires 11 mandatory fields.",
                context: line
            )
        }
        let qname = fields[0]
        guard !qname.isEmpty, qname != "*", referenceLengths[qname] != nil else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has unknown allele QNAME '\(qname)'.",
                context: line
            )
        }
        guard let flag = Int(fields[1]), (0...Int(UInt16.max)).contains(flag) else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has invalid FLAG '\(fields[1])'.",
                context: line
            )
        }
        let isUnmapped = flag & 4 != 0
        let rname = fields[2]
        let position = try integerField(
            fields[3],
            name: "POS",
            allowed: isUnmapped ? 0...Int.max : 1...Int.max,
            samURL: samURL,
            lineNumber: lineNumber,
            context: line
        )
        _ = try integerField(
            fields[4],
            name: "MAPQ",
            allowed: 0...255,
            samURL: samURL,
            lineNumber: lineNumber,
            context: line
        )
        let cigar = fields[5]
        let mateReference = fields[6]
        if mateReference != "*", mateReference != "=", targets[mateReference] == nil {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has unknown RNEXT '\(mateReference)'.",
                context: line
            )
        }
        _ = try integerField(
            fields[7],
            name: "PNEXT",
            allowed: 0...Int.max,
            samURL: samURL,
            lineNumber: lineNumber,
            context: line
        )
        guard Int64(fields[8]) != nil else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has invalid TLEN '\(fields[8])'.",
                context: line
            )
        }
        let sequence = fields[9]
        let quality = fields[10]
        guard !sequence.isEmpty,
              sequence == "*" || sequence.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || byte == 46 || byte == 61
        }) else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has invalid SEQ field.",
                context: line
            )
        }
        guard !quality.isEmpty,
              quality == "*" || quality.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has invalid QUAL field.",
                context: line
            )
        }
        if sequence != "*", quality != "*", sequence.utf8.count != quality.utf8.count {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record SEQ and QUAL lengths differ.",
                context: line
            )
        }
        let optionalTags = try fields.dropFirst(11).map {
            try optionalTag(
                $0,
                samURL: samURL,
                lineNumber: lineNumber,
                context: line
            )
        }

        if isUnmapped {
            if rname != "*", targets[rname] == nil {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "Unmapped alignment references unknown target '\(rname)'.",
                    context: line
                )
            }
            guard cigar == "*" else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "Unmapped alignment must use '*' CIGAR.",
                    context: line
                )
            }
            return
        }

        guard let target = targets[rname] else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record references unknown target '\(rname)'.",
                context: line
            )
        }
        guard declaredSequenceLengths[rname] == target.sequenceLength else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Mapped alignment references target '\(rname)' without its exact @SQ declaration.",
                context: line
            )
        }
        let readGroupTags = optionalTags.filter { $0.name == "RG" }
        guard readGroupTags.count == 1 else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Mapped alignment must contain exactly one RG tag; found \(readGroupTags.count).",
                context: line
            )
        }
        guard let readGroup = readGroupTags.first, readGroup.type == "Z" else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Mapped alignment must contain one valid RG:Z tag.",
                context: line
            )
        }
        guard let readGroupSample = declaredReadGroupSamples[readGroup.value] else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Mapped alignment references undeclared read group '\(readGroup.value)'.",
                context: line
            )
        }
        guard readGroupSample == target.sampleID else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Mapped alignment read group sample '\(readGroupSample)' does not match target sample '\(target.sampleID)' for '\(rname)'.",
                context: line
            )
        }
        guard cigar != "*" else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Mapped alignment has missing CIGAR.",
                context: line
            )
        }
        let nmTags = optionalTags.filter { $0.name == "NM" }
        guard nmTags.count <= 1 else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has duplicate NM tags.",
                context: line
            )
        }
        let nm: Int?
        if let nmTag = nmTags.first {
            guard nmTag.type == "i", let value = Int(nmTag.value), value >= 0 else {
                throw lineError(
                    samURL: samURL,
                    lineNumber: lineNumber,
                    message: "Alignment record has invalid NM tag '\(nmTag.value)'.",
                    context: line
                )
            }
            nm = value
        } else {
            nm = nil
        }
        let metrics: FullLengthONTMHCSAMMetrics
        do {
            metrics = try FullLengthONTMHCSAMMetrics(cigar: cigar, nm: nm)
        } catch {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has invalid CIGAR '\(cigar)': \(error.localizedDescription)",
                context: line
            )
        }
        guard metrics.referenceSpan > 0 else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Mapped alignment CIGAR has zero reference span.",
                context: line
            )
        }
        let targetEnd: Int
        do {
            let offset = try FullLengthONTMHCSAMMetrics.subtracting(
                metrics.referenceSpan,
                1,
                metric: .targetEnd,
                operation: .subtract
            )
            targetEnd = try FullLengthONTMHCSAMMetrics.adding(
                position,
                offset,
                metric: .targetEnd,
                operation: .add
            )
        } catch {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment coordinate/CIGAR arithmetic failed: \(error.localizedDescription)",
                context: line
            )
        }
        guard targetEnd <= target.sequenceLength else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment ends at \(targetEnd) and extends beyond target length \(target.sequenceLength) for '\(rname)'.",
                context: line
            )
        }
        guard var accumulator = accumulators[target.sampleID] else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "No genotyping accumulator exists for target sample '\(target.sampleID)'.",
                context: line
            )
        }
        do {
            try accumulator.consume(
                allele: qname,
                cluster: target.clusterID,
                flag: flag,
                position: position,
                metrics: metrics
            )
        } catch {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Could not accept alignment evidence: \(error.localizedDescription)",
                context: line
            )
        }
        accumulators[target.sampleID] = accumulator
    }

    private func integerField(
        _ rawValue: String,
        name: String,
        allowed: ClosedRange<Int>,
        samURL: URL,
        lineNumber: Int,
        context: String
    ) throws -> Int {
        guard let value = Int(rawValue), allowed.contains(value) else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has invalid \(name) '\(rawValue)'.",
                context: context
            )
        }
        return value
    }

    private func optionalTag(
        _ field: String,
        samURL: URL,
        lineNumber: Int,
        context: String
    ) throws -> OptionalTag {
        let pieces = field.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].utf8.count == 2,
              let firstNameByte = pieces[0].utf8.first,
              (65...90).contains(firstNameByte) || (97...122).contains(firstNameByte),
              pieces[0].utf8.dropFirst().allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
              }),
              pieces[1].count == 1,
              let type = pieces[1].first,
              "AifZHB".contains(type) else {
            throw lineError(
                samURL: samURL,
                lineNumber: lineNumber,
                message: "Alignment record has malformed optional field '\(field)'.",
                context: context
            )
        }
        return OptionalTag(name: String(pieces[0]), type: type, value: String(pieces[2]))
    }

    private func validationError(
        samURL: URL,
        message: String
    ) -> FullLengthONTMHCFinalBAMValidationError {
        FullLengthONTMHCFinalBAMValidationError(
            samPath: samURL.standardizedFileURL.path,
            lineNumber: nil,
            message: message,
            context: nil
        )
    }

    private func lineError(
        samURL: URL,
        lineNumber: Int,
        message: String,
        context: String
    ) -> FullLengthONTMHCFinalBAMValidationError {
        let boundedContext = String(context.prefix(512))
        return FullLengthONTMHCFinalBAMValidationError(
            samPath: samURL.standardizedFileURL.path,
            lineNumber: lineNumber,
            message: message,
            context: boundedContext
        )
    }
}
