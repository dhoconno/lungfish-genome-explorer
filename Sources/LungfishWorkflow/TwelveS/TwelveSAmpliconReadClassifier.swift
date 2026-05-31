import Foundation

public enum TwelveSReadClassification: Equatable, Sendable {
    case exact(targetID: String, indelCount: Int)
    case ambiguous(targetIDs: [String])
    case unresolved
}

public struct TwelveSAmpliconReadClassifier: Sendable {
    public let references: [TwelveSReferenceRecord]
    public let minimumSoftClipBases: Int
    public let maximumIndelBases: Int

    private struct IndexedReference: Sendable {
        let targetID: String
        let displayName: String
        let target: [UInt8]
    }

    private struct ExactReference: Sendable {
        let target: [UInt8]
        let targetIDs: [String]
    }

    /// A reference whose uppercased sequence appears verbatim as an internal substring of the
    /// read (with at least `minimumSoftClipBases` flank on both ends). Carries enough information
    /// (`sequence`, `displayName`) to collapse nested-substring and same-species duplication
    /// artifacts before deciding exact-vs-ambiguous in ``classify(readSequence:)``.
    private struct ExactMatch: Sendable {
        let targetID: String
        let displayName: String
        let sequence: [UInt8]
    }

    private struct SeedHit: Sendable {
        let referenceIndex: Int
        let offset: Int
    }

    private struct CandidateReference: Sendable {
        let referenceIndex: Int
        let starts: [Int]?
    }

    private let indexedReferences: [IndexedReference]
    private let seedIndex: [String: [SeedHit]]
    private let indexedSeedLengths: [Int]
    private let exactHashReferencesByLength: [Int: [UInt64: [ExactReference]]]
    private let exactHashBasePowers: [Int: UInt64]
    private let referenceLengths: [Int]
    private let minimumReferenceAlignedLengths: [Int]

    private static let rollingHashBase: UInt64 = 131

    public init(
        references: [TwelveSReferenceRecord],
        minimumSoftClipBases: Int = 1,
        maximumIndelBases: Int = 3
    ) {
        self.references = references
        self.minimumSoftClipBases = max(0, minimumSoftClipBases)
        self.maximumIndelBases = max(0, maximumIndelBases)
        self.indexedReferences = references.map {
            IndexedReference(
                targetID: $0.targetID,
                displayName: $0.displayName,
                target: Array($0.sequence.uppercased().utf8)
            )
        }
        var exactSequenceTargets: [String: [String]] = [:]
        var seedIndex: [String: [SeedHit]] = [:]
        var seedLengths = Set<Int>()
        var referenceLengths = Set<Int>()
        for (referenceIndex, reference) in indexedReferences.enumerated() {
            referenceLengths.insert(reference.target.count)
            exactSequenceTargets[String(decoding: reference.target, as: UTF8.self), default: []]
                .append(reference.targetID)
            let seedLength = Self.seedLength(forTargetLength: reference.target.count)
            guard seedLength > 0, reference.target.count >= seedLength else { continue }
            seedLengths.insert(seedLength)
            var seenSeeds = Set<String>()
            for offset in 0...(reference.target.count - seedLength) {
                let seed = Self.seedKey(
                    bytes: reference.target,
                    offset: offset,
                    length: seedLength
                )
                guard seenSeeds.insert(seed).inserted else { continue }
                seedIndex[seed, default: []].append(
                    SeedHit(referenceIndex: referenceIndex, offset: offset)
                )
            }
        }
        self.seedIndex = seedIndex
        self.indexedSeedLengths = seedLengths.sorted()
        var exactHashReferencesByLength: [Int: [UInt64: [ExactReference]]] = [:]
        var exactHashBasePowers: [Int: UInt64] = [:]
        for (sequence, targetIDs) in exactSequenceTargets {
            let target = Array(sequence.utf8)
            let length = target.count
            let hash = Self.sequenceHash(bytes: target)
            exactHashReferencesByLength[length, default: [:]][hash, default: []].append(
                ExactReference(target: target, targetIDs: targetIDs)
            )
            exactHashBasePowers[length] = Self.leadingBasePower(forLength: length)
        }
        self.exactHashReferencesByLength = exactHashReferencesByLength
        self.exactHashBasePowers = exactHashBasePowers
        self.referenceLengths = referenceLengths.sorted()
        let maximumIndels = self.maximumIndelBases
        self.minimumReferenceAlignedLengths = indexedReferences.map {
            max(1, $0.target.count - maximumIndels)
        }
    }

    public func classify(readSequence: String) -> TwelveSReadClassification {
        let read = Array(readSequence.uppercased().utf8)
        var matches: [(targetID: String, indelCount: Int)] = []

        if let exactClassification = resolveExactMatches(exactMatchedReferences(in: read)) {
            return exactClassification
        }

        for candidate in candidateReferences(for: read) {
            let reference = indexedReferences[candidate.referenceIndex]
            guard let indelCount = bestIndelOnlyAlignment(
                target: reference.target,
                read: read,
                candidateStarts: candidate.starts
            ) else {
                continue
            }
            matches.append((targetID: reference.targetID, indelCount: indelCount))
        }

        guard !matches.isEmpty else { return .unresolved }
        let bestIndelCount = matches.map(\.indelCount).min() ?? 0
        let bestMatches = matches.filter { $0.indelCount == bestIndelCount }
        if bestMatches.count == 1, let match = bestMatches.first {
            return .exact(targetID: match.targetID, indelCount: match.indelCount)
        }
        return .ambiguous(targetIDs: bestMatches.map(\.targetID).sorted())
    }

    /// Returns every reference whose uppercased sequence appears verbatim inside `read` with at
    /// least `minimumSoftClipBases` flank on both ends. Order follows `indexedReferences`
    /// (deterministic), and each `targetID` appears at most once. The exact boundary scan is
    /// identical to the prior `exactMatches(in:)`; this variant only enriches the result with the
    /// matched reference's sequence and display name so ``classify(readSequence:)`` can collapse
    /// nested-substring and same-species duplication artifacts.
    private func exactMatchedReferences(in read: [UInt8]) -> [ExactMatch] {
        guard minimumSoftClipBases >= 0 else { return [] }
        let lowerBound = minimumSoftClipBases
        let upperBound = read.count - minimumSoftClipBases
        guard upperBound > lowerBound else { return [] }

        var matches: [ExactMatch] = []
        var seenTargetIDs = Set<String>()
        for reference in indexedReferences {
            let pattern = reference.target
            let m = pattern.count
            guard m > 0, m <= upperBound - lowerBound else { continue }
            let firstStart = lowerBound
            let lastStart = upperBound - m
            guard lastStart >= firstStart else { continue }
            var start = firstStart
            scan: while start <= lastStart {
                var k = 0
                while k < m {
                    if read[start + k] != pattern[k] { break }
                    k += 1
                }
                if k == m {
                    if seenTargetIDs.insert(reference.targetID).inserted {
                        matches.append(
                            ExactMatch(
                                targetID: reference.targetID,
                                displayName: reference.displayName,
                                sequence: pattern
                            )
                        )
                    }
                    break scan
                }
                start += 1
            }
        }
        return matches
    }

    /// Collapses nested-substring and same-species duplication artifacts in a set of exact matches,
    /// then decides exact-vs-ambiguous. Applies only to the exact-embedded match path (indelCount
    /// is always 0 here); the indel-only fallback in ``classify(readSequence:)`` is unaffected.
    ///
    /// Steps (per 2026-05-31 12S exact-collapse policy):
    /// 1. **Substring containment collapse** drops any match whose sequence is a *proper* substring
    ///    (contained AND strictly shorter) of another match's sequence. Equal-byte sequences are
    ///    not proper substrings, so both survive this step.
    /// 2. **Same-species canonicalization**: if all survivors share one `displayName`, the read is
    ///    not ambiguous. The canonical survivor is the longest sequence, tie-broken by smallest
    ///    `targetID` (lexicographic) for stability.
    /// 3. **Cross-species ambiguity** is preserved: survivors spanning more than one `displayName`
    ///    return `.ambiguous` over the survivors' target IDs (sorted).
    private func resolveExactMatches(_ matches: [ExactMatch]) -> TwelveSReadClassification? {
        guard !matches.isEmpty else { return nil }
        if matches.count == 1, let only = matches.first {
            return .exact(targetID: only.targetID, indelCount: 0)
        }

        // Step 1: drop any match that is a proper substring of another match's sequence.
        let survivors = matches.enumerated().filter { index, candidate in
            !matches.enumerated().contains { otherIndex, other in
                otherIndex != index
                    && other.sequence.count > candidate.sequence.count
                    && Self.isSubstringContained(candidate.sequence, within: other.sequence)
            }
        }.map(\.element)

        guard let first = survivors.first else { return nil }
        if survivors.count == 1 {
            return .exact(targetID: first.targetID, indelCount: 0)
        }

        // Step 2: if every survivor is the same species, collapse to a single canonical survivor.
        let distinctDisplayNames = Set(survivors.map(\.displayName))
        if distinctDisplayNames.count == 1 {
            let canonical = survivors.max { lhs, rhs in
                if lhs.sequence.count != rhs.sequence.count {
                    return lhs.sequence.count < rhs.sequence.count
                }
                // Longest first; for equal length prefer the smallest targetID for stability.
                return lhs.targetID > rhs.targetID
            } ?? first
            return .exact(targetID: canonical.targetID, indelCount: 0)
        }

        // Step 3: genuinely different species remain ambiguous.
        return .ambiguous(targetIDs: survivors.map(\.targetID).sorted())
    }

    /// Returns `true` when `needle` occurs as a contiguous run inside `haystack`.
    /// Both arguments are uppercased byte sequences. An empty `needle` is contained in anything.
    private static func isSubstringContained(_ needle: [UInt8], within haystack: [UInt8]) -> Bool {
        let n = needle.count
        let h = haystack.count
        guard n > 0 else { return true }
        guard n <= h else { return false }
        let lastStart = h - n
        var start = 0
        while start <= lastStart {
            var k = 0
            while k < n {
                if haystack[start + k] != needle[k] { break }
                k += 1
            }
            if k == n { return true }
            start += 1
        }
        return false
    }

    private func candidateReferences(for read: [UInt8]) -> [CandidateReference] {
        guard !seedIndex.isEmpty else {
            return indexedReferences.indices.map {
                CandidateReference(referenceIndex: $0, starts: nil)
            }
        }
        var hitCounts: [Int: Int] = [:]
        var seenReadSeeds = Set<String>()
        for seedLength in indexedSeedLengths where read.count >= seedLength {
            for readOffset in 0...(read.count - seedLength) {
                let seed = Self.seedKey(bytes: read, offset: readOffset, length: seedLength)
                guard seenReadSeeds.insert(seed).inserted else { continue }
                guard let seedHits = seedIndex[seed] else { continue }
                for seedHit in seedHits {
                    hitCounts[seedHit.referenceIndex, default: 0] += 1
                }
            }
        }
        guard let bestHitCount = hitCounts.values.max() else { return [] }
        let tolerance = max(8, maximumIndelBases * 8)
        let cutoff = max(1, bestHitCount - tolerance)
        let selectedReferenceIndexes = hitCounts
            .filter { $0.value >= cutoff }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .map(\.key)
        let selectedReferenceIndexSet = Set(selectedReferenceIndexes)

        var startVotes: [Int: [Int: Int]] = [:]
        let minimumAlignedEnd = read.count - minimumSoftClipBases
        for seedLength in indexedSeedLengths where read.count >= seedLength {
            for readOffset in 0...(read.count - seedLength) {
                let seed = Self.seedKey(bytes: read, offset: readOffset, length: seedLength)
                guard let seedHits = seedIndex[seed] else { continue }
                for seedHit in seedHits where selectedReferenceIndexSet.contains(seedHit.referenceIndex) {
                    let minimumAlignedLength = minimumReferenceAlignedLengths[seedHit.referenceIndex]
                    for startAdjustment in (-maximumIndelBases)...maximumIndelBases {
                        let candidateStart = readOffset - seedHit.offset + startAdjustment
                        guard candidateStart >= minimumSoftClipBases else { continue }
                        guard candidateStart + minimumAlignedLength <= minimumAlignedEnd else {
                            continue
                        }
                        startVotes[seedHit.referenceIndex, default: [:]][candidateStart, default: 0] += 1
                    }
                }
            }
        }
        return selectedReferenceIndexes
            .map { referenceIndex in
                let starts = startVotes[referenceIndex, default: [:]]
                    .sorted {
                        if $0.value != $1.value { return $0.value > $1.value }
                        return $0.key < $1.key
                    }
                    .prefix(16)
                    .map(\.key)
                return CandidateReference(
                    referenceIndex: referenceIndex,
                    starts: starts.isEmpty ? nil : starts
                )
            }
    }

    private func bestIndelOnlyAlignment(
        target: [UInt8],
        read: [UInt8],
        candidateStarts: [Int]? = nil
    ) -> Int? {
        guard !target.isEmpty else { return nil }
        guard read.count >= target.count + minimumSoftClipBases * 2 - maximumIndelBases else {
            return nil
        }

        let minimumAlignedLength = max(1, target.count - maximumIndelBases)
        let maximumAlignedLength = target.count + maximumIndelBases
        var best: Int?

        let lastStart = max(minimumSoftClipBases, read.count - minimumSoftClipBases - minimumAlignedLength)
        guard minimumSoftClipBases <= lastStart else { return nil }

        let starts = candidateStarts ?? Array(minimumSoftClipBases...lastStart)
        for start in starts where start >= minimumSoftClipBases && start <= lastStart {
            let minimumEnd = start + minimumAlignedLength
            let maximumEnd = min(read.count - minimumSoftClipBases, start + maximumAlignedLength)
            guard minimumEnd <= maximumEnd else { continue }

            for end in minimumEnd...maximumEnd {
                guard read[start] == target[0], read[end - 1] == target[target.count - 1] else {
                    continue
                }
                guard alignmentSoftClipIsGenuineFlank(
                    target: target,
                    read: read,
                    queryStart: start,
                    queryEnd: end
                ) else {
                    continue
                }
                guard let indelCount = indelOnlyDistance(
                    target: target,
                    read: read,
                    queryStart: start,
                    queryEnd: end,
                    maximumIndels: maximumIndelBases
                ) else {
                    continue
                }
                if best == nil || indelCount < best! {
                    best = indelCount
                    if indelCount == 0 {
                        return indelCount
                    }
                }
            }
        }

        return best
    }

    /// Rejects indel-only alignments whose soft-clipped read bases are themselves an exact
    /// continuation of the target's leading or trailing bases. Such a "flank" is not genuine:
    /// it means the target core sits flush against a read boundary and the indel aligner is
    /// manufacturing soft-clip out of the core's own bases. Per the design spec
    /// (2026-05-31-12s-flanked-exact-match-undercall-design.md, lines 117-121, 244-245), a read
    /// with no genuine `minimumSoftClipBases` flank on a side must stay unresolved.
    private func alignmentSoftClipIsGenuineFlank(
        target: [UInt8],
        read: [UInt8],
        queryStart: Int,
        queryEnd: Int
    ) -> Bool {
        guard minimumSoftClipBases > 0 else { return true }

        let leadingClipLength = queryStart
        if leadingClipLength > 0, leadingClipLength <= target.count {
            var matchesTargetPrefix = true
            for index in 0..<leadingClipLength where read[index] != target[index] {
                matchesTargetPrefix = false
                break
            }
            if matchesTargetPrefix { return false }
        }

        let trailingClipLength = read.count - queryEnd
        if trailingClipLength > 0, trailingClipLength <= target.count {
            var matchesTargetSuffix = true
            let targetTailStart = target.count - trailingClipLength
            for index in 0..<trailingClipLength where read[queryEnd + index] != target[targetTailStart + index] {
                matchesTargetSuffix = false
                break
            }
            if matchesTargetSuffix { return false }
        }

        return true
    }

    private static func seedLength(forTargetLength targetLength: Int) -> Int {
        min(targetLength <= 12 ? 4 : 8, targetLength)
    }

    private static func seedKey(bytes: [UInt8], offset: Int, length: Int) -> String {
        "\(length):" + String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
    }

    private static func sequenceHash(bytes: [UInt8]) -> UInt64 {
        sequenceHash(bytes: bytes, offset: 0, length: bytes.count)
    }

    private static func sequenceHash(bytes: [UInt8], offset: Int, length: Int) -> UInt64 {
        var hash: UInt64 = 0
        for index in offset..<(offset + length) {
            hash = hash &* rollingHashBase &+ UInt64(bytes[index])
        }
        return hash
    }

    private static func leadingBasePower(forLength length: Int) -> UInt64 {
        guard length > 1 else { return 1 }
        var power: UInt64 = 1
        for _ in 1..<length {
            power = power &* rollingHashBase
        }
        return power
    }

    private static func rollHash(
        _ hash: UInt64,
        removing removedByte: UInt8,
        adding addedByte: UInt8,
        leadingPower: UInt64
    ) -> UInt64 {
        (hash &- UInt64(removedByte) &* leadingPower) &* rollingHashBase &+ UInt64(addedByte)
    }

    private static func bytesEqual(_ target: [UInt8], _ read: [UInt8], offset: Int) -> Bool {
        guard offset + target.count <= read.count else { return false }
        for index in target.indices where target[index] != read[offset + index] {
            return false
        }
        return true
    }

    private func indelOnlyDistance(
        target: [UInt8],
        read: [UInt8],
        queryStart: Int,
        queryEnd: Int,
        maximumIndels: Int
    ) -> Int? {
        let queryLength = queryEnd - queryStart
        guard abs(target.count - queryLength) <= maximumIndels else { return nil }

        var best: Int?
        func search(targetOffset: Int, queryOffset: Int, edits: Int) {
            guard edits <= maximumIndels else { return }
            if let best, edits >= best { return }

            var targetOffset = targetOffset
            var queryOffset = queryOffset
            while targetOffset < target.count,
                  queryOffset < queryEnd,
                  target[targetOffset] == read[queryOffset] {
                targetOffset += 1
                queryOffset += 1
            }

            if targetOffset == target.count {
                let totalEdits = edits + queryEnd - queryOffset
                guard totalEdits <= maximumIndels else { return }
                best = min(best ?? totalEdits, totalEdits)
                return
            }
            if queryOffset == queryEnd {
                let totalEdits = edits + target.count - targetOffset
                guard totalEdits <= maximumIndels else { return }
                best = min(best ?? totalEdits, totalEdits)
                return
            }

            let remainingTarget = target.count - targetOffset
            let remainingQuery = queryEnd - queryOffset
            guard edits + abs(remainingTarget - remainingQuery) <= maximumIndels else {
                return
            }

            search(targetOffset: targetOffset + 1, queryOffset: queryOffset, edits: edits + 1)
            search(targetOffset: targetOffset, queryOffset: queryOffset + 1, edits: edits + 1)
        }

        search(targetOffset: 0, queryOffset: queryStart, edits: 0)
        return best
    }
}
