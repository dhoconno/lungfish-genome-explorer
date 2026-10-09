import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeResultBundle {
    public static let directoryExtension = "lungfishgenotype"

    private static let maximumCollectedCandidateArtifactBytes: Int64 = 256 * 1_024 * 1_024
    private static let artifactReadChunkBytes = 64 * 1_024
    private static let maximumStableReadAttempts = 3
    private static let artifactValidationCache = ArtifactValidationCache()

    private struct ArtifactValidationCacheKey: Hashable {
        let device: UInt64
        let inode: UInt64
        let sizeBytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let sha256: String
    }

    private final class ArtifactValidationCache: @unchecked Sendable {
        private static let maximumEntries = 512

        private let lock = NSLock()
        private var entries: Set<ArtifactValidationCacheKey> = []
        private var hashingPassCount = 0

        func contains(_ key: ArtifactValidationCacheKey) -> Bool {
            lock.withLock { entries.contains(key) }
        }

        func insert(_ key: ArtifactValidationCacheKey) {
            lock.withLock {
                if entries.count >= Self.maximumEntries {
                    entries.removeAll(keepingCapacity: true)
                }
                entries.insert(key)
                hashingPassCount += 1
            }
        }

#if DEBUG
        func resetForTesting() {
            lock.withLock {
                entries.removeAll(keepingCapacity: false)
                hashingPassCount = 0
            }
        }

        var hashingPassCountForTesting: Int {
            lock.withLock { hashingPassCount }
        }
#endif
    }

    private struct ManifestSnapshot: Equatable {
        let data: Data
        let device: dev_t
        let inode: ino_t
        let sizeBytes: Int64
        let sha256: String

        static func == (lhs: ManifestSnapshot, rhs: ManifestSnapshot) -> Bool {
            lhs.device == rhs.device
                && lhs.inode == rhs.inode
                && lhs.sizeBytes == rhs.sizeBytes
                && lhs.sha256 == rhs.sha256
        }
    }

    private struct MHCCandidateProjection {
        let candidates: ONTMHCCandidateAllelesDocument?
        let unnameable: ONTMHCUnnameableClustersDocument?
        let candidateSequencesByStableClusterID: [String: String]
        let genBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs
        let alignmentArtifactURLs: ONTMHCAlignmentArtifactURLs
        let warnings: [ONTGenotypeIntegrityWarning]

        static let absent = MHCCandidateProjection(
            candidates: nil,
            unnameable: nil,
            candidateSequencesByStableClusterID: [:],
            genBankArtifactURLs: .empty,
            alignmentArtifactURLs: .empty,
            warnings: []
        )
    }

    private struct ProvisionalExon2Projection {
        let sequencesByGenotype: [String: ONTGenotypeProvisionalExon2Sequence]
        let artifactURLs: ONTGenotypeProvisionalExon2ArtifactURLs

        static let absent = ProvisionalExon2Projection(
            sequencesByGenotype: [:],
            artifactURLs: .empty
        )
    }

    private struct CandidateIntegrityFailure: Error, LocalizedError {
        let warning: ONTGenotypeIntegrityWarning

        var errorDescription: String? {
            if let path = warning.path {
                return "MHC artifact integrity failure for \(path): \(warning.detail)"
            }
            return "MHC artifact integrity failure: \(warning.detail)"
        }
    }

    private struct ParsedFASTA {
        let sequenceChecksums: [String: String]
        let counts: [String: Int]
        let sequencesByID: [String: String]
    }

    private struct StreamingFASTAParser {
        private static let maximumLineBytes = 1_048_576
        private let path: String
        private let requiredIDs: Set<String>
        private let retainRequiredSequences: Bool
        private var pendingLine: [UInt8] = []
        private var currentID: String?
        private var currentIsRequired = false
        private var currentHasher = SHA256()
        private var currentBaseCount = 0
        private var currentSequence: [UInt8] = []
        private var counts: [String: Int] = [:]
        private var checksums: [String: String] = [:]
        private var sequences: [String: String] = [:]

        init(path: String, requiredIDs: Set<String>, retainRequiredSequences: Bool = false) {
            self.path = path
            self.requiredIDs = requiredIDs
            self.retainRequiredSequences = retainRequiredSequences
        }

        mutating func consume(_ data: Data) throws {
            for byte in data {
                if byte == 0x0a {
                    try consumeLine(pendingLine)
                    pendingLine.removeAll(keepingCapacity: true)
                } else {
                    guard pendingLine.count < Self.maximumLineBytes else {
                        throw ONTGenotypeResultBundle.integrityFailure(
                            .candidateArtifactMalformedFASTA,
                            "Candidate FASTA contains a line longer than \(Self.maximumLineBytes) bytes.",
                            path: path
                        )
                    }
                    pendingLine.append(byte)
                }
            }
        }

        mutating func finish() throws -> ParsedFASTA {
            if !pendingLine.isEmpty { try consumeLine(pendingLine) }
            try finishRecord()
            return ParsedFASTA(
                sequenceChecksums: checksums,
                counts: counts,
                sequencesByID: sequences
            )
        }

        private mutating func consumeLine(_ rawLine: [UInt8]) throws {
            var line = rawLine
            if line.last == 0x0d { line.removeLast() }
            if line.first == 0x3e {
                try finishRecord()
                guard let header = String(bytes: line.dropFirst(), encoding: .utf8) else {
                    throw malformed("Candidate FASTA header is not valid UTF-8.")
                }
                let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = trimmed.split(whereSeparator: \.isWhitespace).first, !id.isEmpty else {
                    throw malformed("Candidate FASTA contains an empty record identifier.")
                }
                currentID = String(id)
                currentIsRequired = requiredIDs.contains(String(id))
                currentHasher = SHA256()
                currentBaseCount = 0
                currentSequence.removeAll(keepingCapacity: true)
                return
            }
            var start = 0
            var end = line.count
            while start < end, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
            while end > start, line[end - 1] == 0x20 || line[end - 1] == 0x09 { end -= 1 }
            guard start < end || currentID != nil else {
                throw malformed("Candidate FASTA contains sequence data before its first header.")
            }
            guard start < end else { return }
            guard currentID != nil else {
                throw malformed("Candidate FASTA contains sequence data before its first header.")
            }
            var normalized: [UInt8] = []
            normalized.reserveCapacity(end - start)
            for byte in line[start..<end] {
                guard byte >= 0x21, byte <= 0x7e else {
                    throw malformed("Candidate FASTA sequence contains non-ASCII or embedded whitespace bytes.")
                }
                normalized.append((0x61...0x7a).contains(byte) ? byte - 0x20 : byte)
            }
            if currentIsRequired {
                currentHasher.update(data: Data(normalized))
                if retainRequiredSequences { currentSequence.append(contentsOf: normalized) }
            }
            currentBaseCount += normalized.count
        }

        private mutating func finishRecord() throws {
            guard let id = currentID else { return }
            guard currentBaseCount > 0 else {
                throw malformed("FASTA record '\(id)' has no sequence.")
            }
            counts[id, default: 0] += 1
            if currentIsRequired, checksums[id] == nil {
                checksums[id] = currentHasher.finalize().map { String(format: "%02x", $0) }.joined()
                if retainRequiredSequences {
                    sequences[id] = String(decoding: currentSequence, as: UTF8.self)
                }
            }
            currentID = nil
            currentIsRequired = false
            currentBaseCount = 0
            currentSequence.removeAll(keepingCapacity: true)
        }

        private func malformed(_ detail: String) -> CandidateIntegrityFailure {
            ONTGenotypeResultBundle.integrityFailure(.candidateArtifactMalformedFASTA, detail, path: path)
        }
    }

    public static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
    }

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(ONTGenotypeResultBundleManifest.filename)
    }

    public static func loadManifest(from bundleURL: URL) throws -> ONTGenotypeResultBundleManifest {
        let data = try Data(contentsOf: manifestURL(in: bundleURL))
        return try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: data)
    }

    /// Reads the durable bundle manifest through a regular-file descriptor
    /// without following symbolic links and verifies that the file remains
    /// stable for the full read.
    public static func readManifestDataNoFollow(
        from bundleURL: URL
    ) throws -> Data {
        try readManifestSnapshotNoFollow(
            from: bundleURL.standardizedFileURL
        ).data
    }

    public static func writeManifest(
        _ manifest: ONTGenotypeResultBundleManifest,
        to bundleURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: bundleURL), options: .atomic)
    }

    public static func primaryWorkbookURL(for bundleURL: URL) throws -> URL {
        let manifest = try loadManifest(from: bundleURL)
        return resolvedURL(for: manifest.primaryWorkbookPath, in: bundleURL)
    }

    public static func currentWorkbookURL(for bundleURL: URL) throws -> URL {
        let manifest = try loadManifest(from: bundleURL)
        return resolvedURL(
            for: manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath,
            in: bundleURL
        )
    }

    /// Synchronous loader retained for CLI and non-UI callers. This method may hash
    /// large declared BAM artifacts; AppKit call sites should use `loadResultAsync`.
    public static func loadResult(from bundleURL: URL) throws -> ONTGenotypeResultBundleData {
        try loadStableResult(
            from: bundleURL,
            candidateArtifactByteBudget: maximumCollectedCandidateArtifactBytes,
            requiredManifest: nil,
            stableReadObserver: nil
        )
    }

    /// Loads a published result only while its durable manifest still matches
    /// the caller's already-captured manifest. This lets provenance-sensitive
    /// readers bind path discovery, artifact loading, and the manifest witness
    /// to one scientific generation without weakening the stable-read checks.
    public static func loadResult(
        from bundleURL: URL,
        requiring manifest: ONTGenotypeResultBundleManifest
    ) throws -> ONTGenotypeResultBundleData {
        try loadStableResult(
            from: bundleURL,
            candidateArtifactByteBudget: maximumCollectedCandidateArtifactBytes,
            requiredManifest: manifest,
            stableReadObserver: nil
        )
    }

    public static func loadResultAsync(from bundleURL: URL) async throws -> ONTGenotypeResultBundleData {
        try Task.checkCancellation()
        let worker = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            return try loadResult(from: bundleURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func loadResult(
        from bundleURL: URL,
        candidateArtifactByteBudget: Int64,
        stableReadObserver: ((Int) throws -> Void)? = nil
    ) throws -> ONTGenotypeResultBundleData {
        try loadStableResult(
            from: bundleURL,
            candidateArtifactByteBudget: candidateArtifactByteBudget,
            requiredManifest: nil,
            stableReadObserver: stableReadObserver
        )
    }

    /// Loads result artifacts against an in-memory manifest before that manifest
    /// is durably published. Workflow writers use this while deriving analyses
    /// that must be completed before `genotype-result.json` is published last.
    /// Readers of an already-published bundle should use `loadResult(from:)` or
    /// `loadResultAsync(from:)` so transaction recovery and stable-read checks run.
    public static func loadResult(
        from bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest
    ) throws -> ONTGenotypeResultBundleData {
        try loadResult(
            from: bundleURL,
            manifest: manifest,
            candidateArtifactByteBudget: maximumCollectedCandidateArtifactBytes,
        )
    }

    private static func loadStableResult(
        from bundleURL: URL,
        candidateArtifactByteBudget: Int64,
        requiredManifest: ONTGenotypeResultBundleManifest?,
        stableReadObserver: ((Int) throws -> Void)?
    ) throws -> ONTGenotypeResultBundleData {
        let bundle = bundleURL.standardizedFileURL
        for attempt in 0..<maximumStableReadAttempts {
            try Task.checkCancellation()
            if try transactionMarkerExistsNoFollow(for: bundle) {
                try recoverUsingExistingPublicationLock(for: bundle)
                continue
            }

            let before = try readManifestSnapshotNoFollow(from: bundle)
            let manifest = try JSONDecoder().decode(ONTGenotypeResultBundleManifest.self, from: before.data)
            if let requiredManifest, manifest != requiredManifest {
                throw ONTGenotypeWorkbookUpdateRecoveryError.currentWorkbookIntegrity(
                    "The caller-supplied manifest is stale relative to the durable bundle manifest."
                )
            }
            let result = try loadResult(
                from: bundle,
                manifest: manifest,
                candidateArtifactByteBudget: candidateArtifactByteBudget
            )
            try stableReadObserver?(attempt)
            try Task.checkCancellation()

            if try transactionMarkerExistsNoFollow(for: bundle) {
                try recoverUsingExistingPublicationLock(for: bundle)
                continue
            }
            let after = try readManifestSnapshotNoFollow(from: bundle)
            if before == after { return result }
        }
        throw ONTGenotypeWorkbookUpdateRecoveryError.currentWorkbookIntegrity(
            "The genotype result changed repeatedly while it was being loaded. Please retry after the writer finishes."
        )
    }

    private static func recoverUsingExistingPublicationLock(for bundleURL: URL) throws {
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(
            for: bundleURL,
            blocking: true,
            createIfMissing: false
        )
        defer { publicationLock.release() }
        try ONTGenotypeWorkbookUpdateRecovery.recoverIfNeededAssumingLock(for: bundleURL)
    }

    private static func transactionMarkerExistsNoFollow(for bundleURL: URL) throws -> Bool {
        let markerCount = try ONTGenotypeWorkbookUpdateRecovery.transactionMarkerHintCount(
            for: bundleURL
        )
        guard markerCount <= 1 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.ambiguousTransaction(
                "Multiple workbook transaction marker hints exist; no recovery action was taken."
            )
        }
        let marker = ONTGenotypeWorkbookUpdateRecovery.markerURL(for: bundleURL)
        var info = stat()
        guard Darwin.lstat(marker.path, &info) == 0 else {
            if errno == ENOENT {
                let lock = ONTGenotypeBundlePublicationLock.lockURL(for: bundleURL)
                var lockInfo = stat()
                if Darwin.lstat(lock.path, &lockInfo) == 0 {
                    guard lockInfo.st_mode & S_IFMT == S_IFREG else {
                        throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeLock(lock.path)
                    }
                    return try ONTGenotypeWorkbookUpdateRecovery.recoveryAuthorityExists(
                        for: bundleURL
                    )
                }
                if errno == ENOENT { return false }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(lock.path, errno)
            }
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(marker.path, errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.unsafeMarker(marker.path)
        }
        return true
    }

    private static func readManifestSnapshotNoFollow(from bundleURL: URL) throws -> ManifestSnapshot {
        let url = manifestURL(in: bundleURL)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.currentWorkbookIntegrity(
                "The durable bundle manifest is not a regular file: \(url.path)"
            )
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ONTGenotypeWorkbookUpdateRecoveryError.systemFailure(url.path, errno)
            }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              Int64(data.count) == Int64(after.st_size) else {
            throw ONTGenotypeWorkbookUpdateRecoveryError.currentWorkbookIntegrity(
                "The durable bundle manifest changed while it was being read."
            )
        }
        return ManifestSnapshot(
            data: data,
            device: after.st_dev,
            inode: after.st_ino,
            sizeBytes: Int64(after.st_size),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    public struct ReferenceGenotypeLocusDisplayOrderCapture: Sendable {
        public let order: [String]
        public let manifestURL: URL
        public let manifestData: Data

        public init(order: [String], manifestURL: URL, manifestData: Data) {
            self.order = order
            self.manifestURL = manifestURL.standardizedFileURL
            self.manifestData = manifestData
        }
    }

    /// Resolves the optional legacy reference-order fallback while retaining
    /// the exact reference-manifest bytes that supplied the order. Supplying
    /// provenance data binds resolution to an already-captured provenance
    /// witness instead of reopening that mutable file.
    public static func referenceGenotypeLocusDisplayOrderCapture(
        manifest: ONTGenotypeResultBundleManifest,
        in bundleURL: URL,
        provenanceData: Data? = nil
    ) throws -> ReferenceGenotypeLocusDisplayOrderCapture? {
        let data = try provenanceData
            ?? Data(contentsOf: resolvedURL(for: manifest.provenancePath, in: bundleURL))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let options = object["options"] as? [String: Any]
        let explicit = options?["explicit"] as? [String: Any] ?? options
        var referencePath: String?
        for key in ["reference", "referenceSource"] {
            if let value = explicit?[key] as? String { referencePath = value; break }
            if let value = explicit?[key] as? [String: Any], let path = value["value"] as? String {
                referencePath = path; break
            }
        }
        if referencePath == nil, let argv = object["argv"] as? [String],
           let index = argv.firstIndex(of: "--reference"), argv.indices.contains(index + 1) {
            referencePath = argv[index + 1]
        }
        guard let referencePath else { return nil }
        let referenceURL = referencePath.hasPrefix("/")
            ? URL(fileURLWithPath: referencePath) : bundleURL.appendingPathComponent(referencePath)
        guard MHCAmpliconReferenceBundle.isBundleURL(referenceURL) else { return nil }
        let referenceManifestURL = MHCAmpliconReferenceBundle.manifestURL(
            in: referenceURL
        ).standardizedFileURL
        let referenceManifestData = try Data(contentsOf: referenceManifestURL)
        let reference = try JSONDecoder().decode(
            MHCAmpliconReferenceBundleManifest.self,
            from: referenceManifestData
        )
        guard let order = reference.genotypeLocusDisplayOrder else { return nil }
        return .init(
            order: try MHCAlleleDisplayOrder.validatedLocusDisplayOrder(order),
            manifestURL: referenceManifestURL,
            manifestData: referenceManifestData
        )
    }

    public static func referenceGenotypeLocusDisplayOrder(
        manifest: ONTGenotypeResultBundleManifest,
        in bundleURL: URL
    ) -> [String]? {
        try? referenceGenotypeLocusDisplayOrderCapture(
            manifest: manifest,
            in: bundleURL
        )?.order
    }

    private static func loadResult(
        from bundleURL: URL,
        manifest: ONTGenotypeResultBundleManifest,
        candidateArtifactByteBudget: Int64
    ) throws -> ONTGenotypeResultBundleData {
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: resolvedURL(
                for: manifest.currentWorkbookPath ?? manifest.primaryWorkbookPath,
                in: bundleURL
            ),
            primaryWorkbookURL: resolvedURL(for: manifest.primaryWorkbookPath, in: bundleURL),
            longSummaryCSVURL: resolvedURL(for: manifest.longSummaryCSVPath, in: bundleURL),
            sampleSummaryCSVURL: resolvedURL(for: manifest.sampleSummaryCSVPath, in: bundleURL),
            statsJSONURL: resolvedURL(for: manifest.statsJSONPath, in: bundleURL),
            provenanceURL: resolvedURL(for: manifest.provenancePath, in: bundleURL),
            deduplicatedUnmatchedClustersFASTAURL: manifest.deduplicatedUnmatchedClustersFASTAPath.map {
                resolvedURL(for: $0, in: bundleURL)
            },
            haplotypeAnalysisURL: manifest.haplotypeAnalysisPath.map {
                resolvedURL(for: $0, in: bundleURL)
            }
        )
        let callRows = try loadCSVRows(from: artifacts.longSummaryCSVURL)
        let sampleRows = try loadCSVRows(from: artifacts.sampleSummaryCSVURL)
        let stats = try ONTGenotypeRunStats.load(from: artifacts.statsJSONURL)
        let haplotypeAnalysis = try loadHaplotypeAnalysisIfPresent(from: artifacts.haplotypeAnalysisURL)
        let calls = callRows.compactMap(makeCall(row:)).filter { isAssignedSample($0.sample) }
        let mhcProjection: MHCCandidateProjection
        if manifest.kind == "full-length-ont-mhc-genotype" {
            mhcProjection = try loadMHCCandidateProjection(
                from: manifest.mhcCandidateArtifacts,
                bundleURL: bundleURL,
                parsedArtifactByteBudget: candidateArtifactByteBudget
            )
        } else {
            mhcProjection = .absent
        }
        if let generic = manifest.alignmentArtifacts,
           let nested = manifest.mhcCandidateArtifacts,
           generic.genotypingEvidence != nested.genotypingEvidence
            || generic.reciprocalEvidence != nested.reciprocalEvidence {
            throw ONTGenotypeScientificArtifactError.conflictingAlignmentDeclarations
        }
        let alignmentArtifactURLs = try loadGenericAlignmentArtifacts(
            from: manifest.alignmentArtifacts,
            bundleURL: bundleURL
        ) ?? mhcProjection.alignmentArtifactURLs
        let provisionalExon2Projection = try loadProvisionalExon2Projection(
            from: manifest.provisionalExon2Artifacts,
            bundleURL: bundleURL,
            calls: calls
        )
        let mhcReferenceVisualizations = try loadMHCReferenceVisualizations(
            from: manifest.mhcReferenceVisualizations,
            bundleURL: bundleURL
        )
        let referenceMetadata = try loadReferenceMetadataIfPresent(
            manifest.referenceRecordStore,
            from: bundleURL
        )
        let reviewableRowCatalog = try loadReviewableRowCatalog(
            from: manifest.reviewableRowCatalog,
            bundleURL: bundleURL
        )

        let callsBySample = Dictionary(grouping: calls, by: \.sample)
        let orderedSampleNames = orderedAssignedSampleNames(sampleRows: sampleRows, calls: calls)
        let samples = orderedSampleNames.map { sampleName in
            let row = sampleRows.first { ($0["sample"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == sampleName }
            let callsForSample = callsBySample[sampleName] ?? []
            let passedAlignments = parseInt(row?["passed_alignments"]) ?? callsForSample.reduce(0) { $0 + $1.passedAlignments }
            let passedUniqueReads = parseInt(row?["passed_unique_reads"])
                ?? callsForSample.map(\.passedUniqueReads).max()
                ?? 0
            return ONTGenotypeSampleResult(
                sample: sampleName,
                passedAlignments: passedAlignments,
                passedUniqueReads: passedUniqueReads,
                sampleTotalReads: parseInt(row?["sample_total_reads"]),
                sampleUniqueRetainedPercent: parseDouble(row?["sample_unique_retained_percent"]),
                calls: callsForSample
            )
        }

        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: mhcProjection.candidates,
            mhcUnnameableClusters: mhcProjection.unnameable,
            mhcCandidateSequencesByStableClusterID: mhcProjection.candidateSequencesByStableClusterID,
            mhcCandidateGenBankArtifactURLs: mhcProjection.genBankArtifactURLs,
            mhcAlignmentArtifactURLs: alignmentArtifactURLs,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            integrityWarnings: mhcProjection.warnings,
            referenceMetadata: referenceMetadata,
            provisionalExon2SequencesByGenotype: provisionalExon2Projection.sequencesByGenotype,
            provisionalExon2ArtifactURLs: provisionalExon2Projection.artifactURLs,
            reviewableRowCatalog: reviewableRowCatalog
        )
    }

    private static func loadReviewableRowCatalog(
        from reference: ONTMHCArtifactReference?,
        bundleURL: URL
    ) throws -> GenotypeReviewableRowCatalog? {
        guard let reference else { return nil }
        guard let data = try validateArtifact(
            reference,
            in: bundleURL,
            collectData: true
        ) else {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "The reviewable-row catalog could not be read.",
                path: reference.path
            )
        }
        do {
            return try JSONDecoder()
                .decode(GenotypeReviewableRowCatalog.self, from: data)
                .validated()
        } catch let failure as CandidateIntegrityFailure {
            throw failure
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "The reviewable-row catalog is invalid: \(error.localizedDescription)",
                path: reference.path
            )
        }
    }

    private static func loadGenericAlignmentArtifacts(
        from manifest: ONTGenotypeAlignmentArtifactManifest?,
        bundleURL: URL
    ) throws -> ONTMHCAlignmentArtifactURLs? {
        guard let manifest else { return nil }
        for reference in [
            manifest.genotypingEvidence?.bam,
            manifest.genotypingEvidence?.bai,
            manifest.reciprocalEvidence?.bam,
            manifest.reciprocalEvidence?.bai,
        ].compactMap({ $0 }) {
            _ = try validateArtifact(reference, in: bundleURL, collectData: false)
        }
        return ONTMHCAlignmentArtifactURLs(
            genotypingBAM: try manifest.genotypingEvidence.map {
                try normalizedValidatedArtifactURL($0.bam, in: bundleURL)
            },
            genotypingBAI: try manifest.genotypingEvidence.map {
                try normalizedValidatedArtifactURL($0.bai, in: bundleURL)
            },
            reciprocalBAM: try manifest.reciprocalEvidence.map {
                try normalizedValidatedArtifactURL($0.bam, in: bundleURL)
            },
            reciprocalBAI: try manifest.reciprocalEvidence.map {
                try normalizedValidatedArtifactURL($0.bai, in: bundleURL)
            }
        )
    }

    private static func loadProvisionalExon2Projection(
        from manifest: ONTGenotypeProvisionalExon2ArtifactManifest?,
        bundleURL: URL,
        calls: [ONTGenotypeCall]
    ) throws -> ProvisionalExon2Projection {
        guard let manifest else { return .absent }
        guard manifest.schemaVersion == ONTGenotypeProvisionalExon2Document.supportedSchemaVersion else {
            throw ONTGenotypeScientificArtifactError.unsupportedProvisionalExon2Schema(
                manifest.schemaVersion
            )
        }
        let jsonData = try validateArtifact(
            manifest.catalogJSON,
            in: bundleURL,
            collectData: true
        ) ?? Data()
        let document: ONTGenotypeProvisionalExon2Document
        do {
            document = try JSONDecoder().decode(
                ONTGenotypeProvisionalExon2Document.self,
                from: jsonData
            )
        } catch {
            throw ONTGenotypeScientificArtifactError.malformedProvisionalExon2JSON(
                error.localizedDescription
            )
        }
        guard document.schemaVersion == ONTGenotypeProvisionalExon2Document.supportedSchemaVersion,
              document.schemaVersion == manifest.schemaVersion else {
            throw ONTGenotypeScientificArtifactError.unsupportedProvisionalExon2Schema(
                document.schemaVersion
            )
        }

        let genotypes = document.records.map(\.genotype)
        guard Set(genotypes).count == genotypes.count else {
            let duplicate = Dictionary(grouping: genotypes, by: { $0 })
                .first(where: { $0.value.count > 1 })?.key ?? ""
            throw ONTGenotypeScientificArtifactError.duplicateProvisionalGenotype(duplicate)
        }
        let fastaRecordIDs = document.records.map(\.fastaRecordID)
        guard Set(fastaRecordIDs).count == fastaRecordIDs.count else {
            let duplicate = Dictionary(grouping: fastaRecordIDs, by: { $0 })
                .first(where: { $0.value.count > 1 })?.key ?? ""
            throw ONTGenotypeScientificArtifactError.duplicateFASTARecord(
                duplicate
            )
        }
        let observedGenotypes = Set(calls.map(\.genotype))
        for record in document.records {
            guard record.genotype.localizedCaseInsensitiveContains("_nov") else {
                throw ONTGenotypeScientificArtifactError.invalidProvisionalGenotype(record.genotype)
            }
            guard observedGenotypes.contains(record.genotype) else {
                throw ONTGenotypeScientificArtifactError.unobservedProvisionalGenotype(record.genotype)
            }
        }

        let requiredFASTAIDs = Set(document.records.map(\.fastaRecordID))
        var parser = StreamingFASTAParser(
            path: manifest.sequencesFASTA.path,
            requiredIDs: requiredFASTAIDs,
            retainRequiredSequences: true
        )
        var parserFailure: Error?
        _ = try validateArtifact(
            manifest.sequencesFASTA,
            in: bundleURL,
            collectData: false,
            chunkHandler: { chunk in
                guard parserFailure == nil else { return }
                do { try parser.consume(chunk) } catch { parserFailure = error }
            }
        )
        if let parserFailure { throw parserFailure }
        let parsedFASTA = try parser.finish()
        guard Set(parsedFASTA.counts.keys) == requiredFASTAIDs else {
            throw ONTGenotypeScientificArtifactError.unexpectedFASTARecords
        }
        if let duplicate = parsedFASTA.counts.first(where: { $0.value != 1 })?.key {
            throw ONTGenotypeScientificArtifactError.duplicateFASTARecord(duplicate)
        }

        let callsByGenotype = Dictionary(grouping: calls, by: \.genotype)
        var sequencesByGenotype: [String: ONTGenotypeProvisionalExon2Sequence] = [:]
        sequencesByGenotype.reserveCapacity(document.records.count)
        for record in document.records {
            guard let sequence = parsedFASTA.sequencesByID[record.fastaRecordID],
                  let sequenceChecksum = parsedFASTA.sequenceChecksums[record.fastaRecordID] else {
                throw ONTGenotypeScientificArtifactError.missingFASTARecord(record.fastaRecordID)
            }
            guard sequence.utf8.count == record.sequenceLength else {
                throw ONTGenotypeScientificArtifactError.sequenceLengthMismatch(record.genotype)
            }
            guard sequenceChecksum.caseInsensitiveCompare(record.sequenceSHA256) == .orderedSame else {
                throw ONTGenotypeScientificArtifactError.sequenceChecksumMismatch(record.genotype)
            }
            let expectedSupport = Dictionary(
                grouping: callsByGenotype[record.genotype] ?? [],
                by: \.sample
            )
                .map { sample, calls in
                    ONTGenotypeProvisionalExon2SampleSupport(
                        sample: sample,
                        passedAlignments: calls.reduce(0) {
                            $0 + $1.passedAlignments
                        },
                        passedUniqueReads: calls.reduce(0) {
                            $0 + $1.passedUniqueReads
                        }
                    )
                }
                .sorted { lhs, rhs in
                    lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
                }
            let observedLoci = Set((callsByGenotype[record.genotype] ?? []).map(\.locusGroup))
            guard observedLoci == [record.locus] else {
                throw ONTGenotypeScientificArtifactError.locusMismatch(record.genotype)
            }
            let declaredSupport = record.sampleSupport.sorted { lhs, rhs in
                lhs.sample.localizedStandardCompare(rhs.sample) == .orderedAscending
            }
            guard declaredSupport == expectedSupport else {
                throw ONTGenotypeScientificArtifactError.sampleSupportMismatch(record.genotype)
            }
            sequencesByGenotype[record.genotype] = ONTGenotypeProvisionalExon2Sequence(
                genotype: record.genotype,
                locus: record.locus,
                sequence: sequence,
                sequenceSHA256: sequenceChecksum,
                sampleSupport: declaredSupport
            )
        }

        return ProvisionalExon2Projection(
            sequencesByGenotype: sequencesByGenotype,
            artifactURLs: ONTGenotypeProvisionalExon2ArtifactURLs(
                catalogJSON: try normalizedValidatedArtifactURL(manifest.catalogJSON, in: bundleURL),
                sequencesFASTA: try normalizedValidatedArtifactURL(manifest.sequencesFASTA, in: bundleURL)
            )
        )
    }

    private static func loadMHCReferenceVisualizations(
        from artifacts: ONTMHCReferenceVisualizationArtifacts?,
        bundleURL: URL
    ) throws -> ONTMHCReferenceVisualizationArtifact? {
        guard let artifacts else { return nil }
        guard artifacts.schemaVersion == 1 else {
            throw integrityFailure(
                .candidateArtifactManifestSchemaUnsupported,
                "MHC reference visualization artifact manifest schema \(artifacts.schemaVersion) is unsupported; expected schema 1."
            )
        }

        let data = try validateArtifact(
            artifacts.recordsJSON,
            in: bundleURL,
            collectData: true
        ) ?? Data()
        let artifact: ONTMHCReferenceVisualizationArtifact
        do {
            artifact = try JSONDecoder().decode(ONTMHCReferenceVisualizationArtifact.self, from: data)
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "MHC reference visualization JSON is malformed: \(error.localizedDescription)",
                path: artifacts.recordsJSON.path
            )
        }
        let validated = try artifact.validated()
        guard artifacts.recordCount == validated.records.count else {
            throw ONTMHCReferenceVisualizationError.descriptorRecordCountMismatch(
                expected: artifacts.recordCount,
                actual: validated.records.count
            )
        }
        return validated
    }

    private static func loadReferenceMetadataIfPresent(
        _ info: ONTGenotypeReferenceRecordStoreInfo?,
        from bundleURL: URL
    ) throws -> ONTGenotypeReferenceMetadata? {
        guard let info else { return nil }
        guard info.format == ONTGenotypeReferenceRecordStoreInfo.supportedFormat else {
            throw ONTGenotypeReferenceRecordStoreError.unsupportedFormat(info.format)
        }
        guard info.schemaVersion == GenBankRecordDatabase.schemaVersion else {
            throw ONTGenotypeReferenceRecordStoreError.unsupportedSchemaVersion(info.schemaVersion)
        }
        let databaseURL = try BundleManifest.validatedBundleMemberURL(
            for: info.databasePath,
            in: bundleURL,
            field: "reference_record_store.database_path"
        )
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ONTGenotypeReferenceRecordStoreError.missingFile(databaseURL.path)
        }
        let data = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let actualSize = Int64(data.count)
        guard actualSize == info.sizeBytes else {
            throw ONTGenotypeReferenceRecordStoreError.sizeMismatch(expected: info.sizeBytes, actual: actualSize)
        }
        let actualSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualSHA256 == info.sha256.lowercased() else {
            throw ONTGenotypeReferenceRecordStoreError.checksumMismatch(
                expected: info.sha256,
                actual: actualSHA256
            )
        }
        let database = try GenBankRecordDatabase(url: databaseURL)
        let actualRecordCount = try database.recordCount()
        guard actualRecordCount == info.recordCount else {
            throw ONTGenotypeReferenceRecordStoreError.recordCountMismatch(
                expected: info.recordCount,
                actual: actualRecordCount
            )
        }
        let actualFieldCount = try database.fieldCount()
        guard actualFieldCount == info.fieldCount else {
            throw ONTGenotypeReferenceRecordStoreError.fieldCountMismatch(
                expected: info.fieldCount,
                actual: actualFieldCount
            )
        }
        let fields = try database.fieldDefinitions()
        let rows = try database.records()
        return ONTGenotypeReferenceMetadata(
            fields: fields,
            recordsBySequenceName: Dictionary(uniqueKeysWithValues: rows.map { ($0.sequenceName, $0.values) }),
            alleleFieldKey: fields.first(where: { $0.key == "feature.allele" })?.key
        )
    }

    private static func loadMHCCandidateProjection(
        from artifactManifest: ONTMHCCandidateArtifactManifest?,
        bundleURL: URL,
        parsedArtifactByteBudget: Int64
    ) throws -> MHCCandidateProjection {
        guard let artifactManifest else { return .absent }
        do {
            guard (1 ... 2).contains(artifactManifest.schemaVersion) else {
                throw integrityFailure(
                    .candidateArtifactManifestSchemaUnsupported,
                    "MHC candidate artifact manifest schema \(artifactManifest.schemaVersion) is unsupported; expected schema 1 or 2."
                )
            }
            try requirePairedDeclaration(
                artifactManifest.candidateJSON,
                artifactManifest.candidateFASTA,
                label: "candidate JSON and FASTA"
            )
            try requirePairedDeclaration(
                artifactManifest.unnameableJSON,
                artifactManifest.unnameableFASTA,
                label: "un-nameable JSON and FASTA"
            )
            if artifactManifest.candidateGenBank != nil,
               artifactManifest.candidateJSON == nil || artifactManifest.candidateFASTA == nil {
                throw integrityFailure(
                    .candidateArtifactDocumentReferenceMismatch,
                    "Candidate GenBank requires the corresponding candidate JSON and FASTA declarations."
                )
            }
            if artifactManifest.unnameableGenBank != nil,
               artifactManifest.unnameableJSON == nil || artifactManifest.unnameableFASTA == nil {
                throw integrityFailure(
                    .candidateArtifactDocumentReferenceMismatch,
                    "Un-nameable GenBank requires the corresponding un-nameable JSON and FASTA declarations."
                )
            }
            if artifactManifest.candidateEMBL != nil,
               artifactManifest.candidateJSON == nil || artifactManifest.candidateFASTA == nil {
                throw integrityFailure(
                    .candidateArtifactDocumentReferenceMismatch,
                    "Candidate EMBL requires the corresponding candidate JSON and FASTA declarations."
                )
            }
            if artifactManifest.unnameableEMBL != nil,
               artifactManifest.unnameableJSON == nil || artifactManifest.unnameableFASTA == nil {
                throw integrityFailure(
                    .candidateArtifactDocumentReferenceMismatch,
                    "Un-nameable EMBL requires the corresponding un-nameable JSON and FASTA declarations."
                )
            }
            let parsedReferences = [
                artifactManifest.candidateJSON,
                artifactManifest.candidateFASTA,
                artifactManifest.unnameableJSON,
                artifactManifest.unnameableFASTA,
            ].compactMap { $0 }
            guard parsedArtifactByteBudget >= 0 else {
                throw integrityFailure(
                    .candidateArtifactTooLarge,
                    "The aggregate candidate artifact byte budget must not be negative."
                )
            }
            var aggregateBytes: Int64 = 0
            for reference in parsedReferences {
                let (next, overflow) = aggregateBytes.addingReportingOverflow(reference.sizeBytes)
                guard reference.sizeBytes >= 0, !overflow, next <= parsedArtifactByteBudget else {
                    throw integrityFailure(
                        .candidateArtifactTooLarge,
                        "Declared candidate JSON/FASTA artifacts exceed the aggregate parsed-artifact budget of \(parsedArtifactByteBudget) bytes.",
                        path: reference.path
                    )
                }
                aggregateBytes = next
            }
            for reference in declaredBAMReferences(artifactManifest) {
                _ = try validateArtifact(reference, in: bundleURL, collectData: false)
            }
            let alignmentArtifactURLs = ONTMHCAlignmentArtifactURLs(
                genotypingBAM: try artifactManifest.genotypingEvidence.map {
                    try normalizedValidatedArtifactURL($0.bam, in: bundleURL)
                },
                genotypingBAI: try artifactManifest.genotypingEvidence.map {
                    try normalizedValidatedArtifactURL($0.bai, in: bundleURL)
                },
                reciprocalBAM: try artifactManifest.reciprocalEvidence.map {
                    try normalizedValidatedArtifactURL($0.bam, in: bundleURL)
                },
                reciprocalBAI: try artifactManifest.reciprocalEvidence.map {
                    try normalizedValidatedArtifactURL($0.bai, in: bundleURL)
                }
            )
            for reference in [
                artifactManifest.candidateGenBank,
                artifactManifest.unnameableGenBank,
                artifactManifest.candidateEMBL,
                artifactManifest.unnameableEMBL,
                artifactManifest.rawUnmatchedFASTA,
                artifactManifest.sourceIdentityMap,
            ].compactMap({ $0 }) {
                _ = try validateArtifact(reference, in: bundleURL, collectData: false)
            }

            let declaredEvidence = declaredBAMReferences(artifactManifest)
            var candidates: ONTMHCCandidateAllelesDocument?
            var candidateSequencesByStableClusterID: [String: String] = [:]
            if let jsonReference = artifactManifest.candidateJSON,
               let fastaReference = artifactManifest.candidateFASTA {
                let jsonData = try validateArtifact(jsonReference, in: bundleURL, collectData: true) ?? Data()
                let document = try decodeCandidateDocument(jsonData, path: jsonReference.path)
                try validateDocumentReferences(
                    sequenceFASTA: document.sequenceFASTA,
                    evidence: document.evidence,
                    expectedSequenceFASTA: fastaReference,
                    expectedEvidence: declaredEvidence,
                    reciprocalEvidenceLocators: document.candidates.map(\.selectedEvidence),
                    genotypingEvidenceLocators: document.observations.flatMap(\.evidence),
                    genotypingBAMPath: artifactManifest.genotypingEvidence?.bam.path,
                    reciprocalBAMPath: artifactManifest.reciprocalEvidence?.bam.path,
                    documentPath: jsonReference.path
                )
                if document.schemaVersion >= 2 {
                    try validateCompactCandidateDocument(
                        document,
                        genotypingBAMPath: artifactManifest.genotypingEvidence?.bam.path,
                        reciprocalBAMPath: artifactManifest.reciprocalEvidence?.bam.path,
                        documentPath: jsonReference.path
                    )
                }
                var parser = StreamingFASTAParser(
                    path: fastaReference.path,
                    requiredIDs: Set(document.candidates.map(\.stableClusterID)),
                    retainRequiredSequences: true
                )
                var parserFailure: Error?
                _ = try validateArtifact(
                    fastaReference,
                    in: bundleURL,
                    collectData: false,
                    chunkHandler: { chunk in
                        guard parserFailure == nil else { return }
                        do { try parser.consume(chunk) } catch { parserFailure = error }
                    }
                )
                if let parserFailure { throw parserFailure }
                let parsedFASTA = try parser.finish()
                try validateCandidateRecords(
                    document.candidates,
                    fasta: parsedFASTA,
                    path: fastaReference.path
                )
                candidates = document
                candidateSequencesByStableClusterID = parsedFASTA.sequencesByID
            }
            var unnameable: ONTMHCUnnameableClustersDocument?
            if let jsonReference = artifactManifest.unnameableJSON,
               let fastaReference = artifactManifest.unnameableFASTA {
                let jsonData = try validateArtifact(jsonReference, in: bundleURL, collectData: true) ?? Data()
                let document = try decodeUnnameableDocument(jsonData, path: jsonReference.path)
                try validateDocumentReferences(
                    sequenceFASTA: document.sequenceFASTA,
                    evidence: document.evidence,
                    expectedSequenceFASTA: fastaReference,
                    expectedEvidence: declaredEvidence,
                    reciprocalEvidenceLocators: document.schemaVersion == 1
                        ? document.clusters.flatMap(\.evidence)
                        : document.clusters.compactMap(\.selectedEvidence),
                    genotypingEvidenceLocators: document.observations.flatMap(\.evidence),
                    genotypingBAMPath: artifactManifest.genotypingEvidence?.bam.path,
                    reciprocalBAMPath: artifactManifest.reciprocalEvidence?.bam.path,
                    documentPath: jsonReference.path
                )
                if document.schemaVersion >= 2 {
                    try validateCompactUnnameableDocument(
                        document,
                        genotypingBAMPath: artifactManifest.genotypingEvidence?.bam.path,
                        reciprocalBAMPath: artifactManifest.reciprocalEvidence?.bam.path,
                        documentPath: jsonReference.path
                    )
                }
                if candidates == nil || candidates?.schemaVersion == document.schemaVersion {
                    try validateGlobalRawSourceOwnership(
                        candidates: candidates,
                        unnameable: document,
                        documentPath: jsonReference.path
                    )
                }
                let exportableUnnameableIDs = Set(document.clusters.compactMap(\.fastaRecordID))
                var parser = StreamingFASTAParser(
                    path: fastaReference.path,
                    requiredIDs: exportableUnnameableIDs
                )
                var parserFailure: Error?
                _ = try validateArtifact(
                    fastaReference,
                    in: bundleURL,
                    collectData: false,
                    chunkHandler: { chunk in
                        guard parserFailure == nil else { return }
                        do { try parser.consume(chunk) } catch { parserFailure = error }
                    }
                )
                if let parserFailure { throw parserFailure }
                try validateUnnameableRecords(
                    document.clusters,
                    schemaVersion: document.schemaVersion,
                    fasta: try parser.finish(),
                    path: fastaReference.path
                )
                unnameable = document
            }
            if let candidates, let unnameable,
               candidates.schemaVersion != unnameable.schemaVersion {
                throw integrityFailure(
                    .candidateArtifactSchemaUnsupported,
                    "Candidate and un-nameable document schema versions must match; found \(candidates.schemaVersion) and \(unnameable.schemaVersion)."
                )
            }
            let genBankArtifactURLs = ONTMHCCandidateGenBankArtifactURLs(
                candidateAlleles: try artifactManifest.candidateGenBank.map {
                    try normalizedValidatedArtifactURL($0, in: bundleURL)
                },
                unnameableClusters: try artifactManifest.unnameableGenBank.map {
                    try normalizedValidatedArtifactURL($0, in: bundleURL)
                },
                candidateFASTA: try artifactManifest.candidateFASTA.map {
                    try normalizedValidatedArtifactURL($0, in: bundleURL)
                },
                unnameableFASTA: try artifactManifest.unnameableFASTA.map {
                    try normalizedValidatedArtifactURL($0, in: bundleURL)
                },
                candidateEMBL: try artifactManifest.candidateEMBL.map {
                    try normalizedValidatedArtifactURL($0, in: bundleURL)
                },
                unnameableEMBL: try artifactManifest.unnameableEMBL.map {
                    try normalizedValidatedArtifactURL($0, in: bundleURL)
                }
            )
            return MHCCandidateProjection(
                candidates: candidates,
                unnameable: unnameable,
                candidateSequencesByStableClusterID: candidateSequencesByStableClusterID,
                genBankArtifactURLs: genBankArtifactURLs,
                alignmentArtifactURLs: alignmentArtifactURLs,
                warnings: []
            )
        } catch let failure as CandidateIntegrityFailure {
            return MHCCandidateProjection(
                candidates: nil,
                unnameable: nil,
                candidateSequencesByStableClusterID: [:],
                genBankArtifactURLs: .empty,
                alignmentArtifactURLs: .empty,
                warnings: [failure.warning]
            )
        }
    }

    private static func normalizedValidatedArtifactURL(
        _ reference: ONTMHCArtifactReference,
        in bundleURL: URL
    ) throws -> URL {
        try safeRelativePathComponents(reference.path).reduce(bundleURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL
    }

    private static func requirePairedDeclaration(
        _ json: ONTMHCArtifactReference?,
        _ fasta: ONTMHCArtifactReference?,
        label: String
    ) throws {
        guard (json == nil) == (fasta == nil) else {
            throw integrityFailure(
                .candidateArtifactIncompleteDeclaration,
                "The optional MHC \(label) must either both be declared or both be absent.",
                path: json?.path ?? fasta?.path
            )
        }
    }

    private static func declaredBAMReferences(
        _ manifest: ONTMHCCandidateArtifactManifest
    ) -> [ONTMHCArtifactReference] {
        [
            manifest.genotypingEvidence?.bam,
            manifest.genotypingEvidence?.bai,
            manifest.reciprocalEvidence?.bam,
            manifest.reciprocalEvidence?.bai,
        ].compactMap { $0 }
    }

    private static func validateArtifact(
        _ reference: ONTMHCArtifactReference,
        in bundleURL: URL,
        collectData: Bool,
        chunkHandler: ((Data) throws -> Void)? = nil
    ) throws -> Data? {
        let components = try safeRelativePathComponents(reference.path)
        let rootFD = bundleURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFD >= 0 else {
            throw integrityFailure(
                .candidateArtifactPathInvalid,
                "The genotype bundle root could not be opened without following symbolic links: \(errnoDetail()).",
                path: reference.path
            )
        }
        defer { Darwin.close(rootFD) }

        var directoryFD = rootFD
        var ownedDirectoryFDs: [Int32] = []
        defer { ownedDirectoryFDs.reversed().forEach { Darwin.close($0) } }
        for component in components.dropLast() {
            let nextFD = component.withCString {
                Darwin.openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard nextFD >= 0 else {
                let code: ONTGenotypeIntegrityWarningCode = errno == ENOENT
                    ? .candidateArtifactMissing
                    : .candidateArtifactPathInvalid
                throw integrityFailure(
                    code,
                    "A path component could not be opened as a real directory without following links: \(errnoDetail()).",
                    path: reference.path
                )
            }
            ownedDirectoryFDs.append(nextFD)
            directoryFD = nextFD
        }

        let finalFD = components.last!.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard finalFD >= 0 else {
            let code: ONTGenotypeIntegrityWarningCode = errno == ENOENT
                ? .candidateArtifactMissing
                : .candidateArtifactPathInvalid
            throw integrityFailure(
                code,
                "The declared artifact could not be opened as a no-follow file: \(errnoDetail()).",
                path: reference.path
            )
        }
        defer { Darwin.close(finalFD) }

        var status = stat()
        guard Darwin.fstat(finalFD, &status) == 0 else {
            throw integrityFailure(
                .candidateArtifactPathInvalid,
                "The declared artifact could not be inspected: \(errnoDetail()).",
                path: reference.path
            )
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw integrityFailure(
                .candidateArtifactNotRegularFile,
                "The declared MHC artifact is not a regular file.",
                path: reference.path
            )
        }
        let actualSize = Int64(status.st_size)
        guard reference.sizeBytes >= 0, actualSize == reference.sizeBytes else {
            throw integrityFailure(
                .candidateArtifactSizeMismatch,
                "Declared size \(reference.sizeBytes) bytes does not match the regular file size \(actualSize) bytes.",
                path: reference.path
            )
        }
        if (collectData || chunkHandler != nil), actualSize > maximumCollectedCandidateArtifactBytes {
            throw integrityFailure(
                .candidateArtifactTooLarge,
                "The candidate JSON/FASTA is \(actualSize) bytes; the safe loading limit is \(maximumCollectedCandidateArtifactBytes) bytes.",
                path: reference.path
            )
        }
        let validationCacheKey = ArtifactValidationCacheKey(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            sizeBytes: actualSize,
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            sha256: reference.sha256.lowercased()
        )
        if !collectData,
           chunkHandler == nil,
           artifactValidationCache.contains(validationCacheKey) {
            return nil
        }

        var hasher = SHA256()
        var collected = collectData ? Data() : nil
        if collectData { collected?.reserveCapacity(Int(actualSize)) }
        var bytesRead: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: artifactReadChunkBytes)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                Darwin.read(finalFD, rawBuffer.baseAddress!, rawBuffer.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw integrityFailure(
                    .candidateArtifactPathInvalid,
                    "The declared artifact could not be read: \(errnoDetail()).",
                    path: reference.path
                )
            }
            if count == 0 { break }
            bytesRead += Int64(count)
            guard bytesRead <= actualSize else {
                throw integrityFailure(
                    .candidateArtifactSizeMismatch,
                    "The artifact grew while it was being validated.",
                    path: reference.path
                )
            }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            collected?.append(chunk)
            try chunkHandler?(chunk)
        }
        guard bytesRead == actualSize else {
            throw integrityFailure(
                .candidateArtifactSizeMismatch,
                "The artifact changed size while it was being validated (read \(bytesRead) of \(actualSize) bytes).",
                path: reference.path
            )
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == reference.sha256.lowercased() else {
            throw integrityFailure(
                .candidateArtifactChecksumMismatch,
                "Declared SHA-256 \(reference.sha256) does not match computed SHA-256 \(checksum).",
                path: reference.path
            )
        }
        if !collectData, chunkHandler == nil {
            artifactValidationCache.insert(validationCacheKey)
        }
        return collected
    }

#if DEBUG
    static func resetArtifactValidationCacheForTesting() {
        artifactValidationCache.resetForTesting()
    }

    static var artifactValidationHashingPassCountForTesting: Int {
        artifactValidationCache.hashingPassCountForTesting
    }
#endif

    private static func safeRelativePathComponents(_ path: String) throws -> [String] {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.utf8.contains(0),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw integrityFailure(
                .candidateArtifactPathInvalid,
                "Candidate artifact paths must be non-empty relative paths contained below the bundle root.",
                path: path
            )
        }
        return components
    }

    private static func decodeCandidateDocument(
        _ data: Data,
        path: String
    ) throws -> ONTMHCCandidateAllelesDocument {
        try requireSupportedCandidateSchema(
            data,
            path: path,
            recordCollectionKey: "candidates"
        )
        do {
            return try JSONDecoder().decode(ONTMHCCandidateAllelesDocument.self, from: data)
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate JSON does not conform to a supported schema: \(error.localizedDescription)",
                path: path
            )
        }
    }

    private static func decodeUnnameableDocument(
        _ data: Data,
        path: String
    ) throws -> ONTMHCUnnameableClustersDocument {
        try requireSupportedCandidateSchema(
            data,
            path: path,
            recordCollectionKey: "clusters"
        )
        do {
            return try JSONDecoder().decode(ONTMHCUnnameableClustersDocument.self, from: data)
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Un-nameable cluster JSON does not conform to a supported schema: \(error.localizedDescription)",
                path: path
            )
        }
    }

    private static func requireSupportedCandidateSchema(
        _ data: Data,
        path: String,
        recordCollectionKey: String
    ) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate artifact is not valid JSON: \(error.localizedDescription)",
                path: path
            )
        }
        guard let dictionary = object as? [String: Any], let schema = dictionary["schema_version"] as? Int else {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate artifact must be a JSON object with integer schema_version 1, 2, 3, 4, or 5.",
                path: path
            )
        }
        guard (1 ... 5).contains(schema) else {
            throw integrityFailure(
                .candidateArtifactSchemaUnsupported,
                "Candidate artifact schema \(schema) is unsupported; expected schema 1, 2, 3, 4, or 5.",
                path: path
            )
        }
        if recordCollectionKey == "clusters", schema < 4 {
            guard let records = dictionary[recordCollectionKey] as? [[String: Any]],
                  records.allSatisfy({
                      $0["fasta_record_id"] is String && $0["sequence_sha256"] is String
                  }) else {
                throw integrityFailure(
                    .candidateArtifactMalformedJSON,
                    "Un-nameable candidate artifact schemas 1 through 3 require external FASTA identity and checksum fields.",
                    path: path
                )
            }
        }
        guard schema >= 2 else { return }
        guard let records = dictionary[recordCollectionKey] as? [[String: Any]],
              records.allSatisfy({ $0["reciprocal_hit_summary"] != nil }),
              let observations = dictionary["observations"] as? [[String: Any]],
              observations.allSatisfy({
                  $0["genotyping_hit_summaries"] != nil && $0["evidence"] == nil
              }),
              (recordCollectionKey != "clusters" || records.allSatisfy({ $0["evidence"] == nil })) else {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate artifact schema \(schema) requires compact hit summaries and forbids legacy bulk evidence arrays.",
                path: path
            )
        }
        if schema >= 4 {
            guard let observations = dictionary["observations"] as? [[String: Any]],
                  observations.allSatisfy({ $0["source_sequence_cluster_id"] is String }),
                  recordCollectionKey != "candidates" || records.allSatisfy({
                      $0["source_sequence_cluster_ids"] is [String]
                          && $0["representative_source_sequence_cluster_id"] is String
                  }),
                  recordCollectionKey != "clusters" || records.allSatisfy({
                      ($0["fasta_record_id"] is String) == ($0["sequence_sha256"] is String)
                  }) else {
                throw integrityFailure(
                    .candidateArtifactMalformedJSON,
                    "Candidate artifact schema 4 requires explicit raw source-sequence bindings and paired external FASTA identity/checksum fields.",
                    path: path
                )
            }
        }
        guard schema >= 3 else { return }
        guard let observations = dictionary["observations"] as? [[String: Any]],
              observations.allSatisfy({ observation in
                  guard let summaries = observation["genotyping_hit_summaries"] as? [[String: Any]] else {
                      return false
                  }
                  return summaries.allSatisfy { $0["cdna_extension_interpretations"] is [Any] }
              }) else {
            throw integrityFailure(
                .candidateArtifactMalformedJSON,
                "Candidate artifact schema \(schema) requires compact cDNA extension interpretations on every genotyping hit summary.",
                path: path
            )
        }
        if recordCollectionKey == "candidates" {
            let valid = records.allSatisfy { record in
                guard let extensionOf = record["extension_of"] as? [String],
                      let interpretations = record["extension_interpretations"] as? [[String: Any]],
                      record["provisional_naming_ambiguous"] is Bool else {
                    return false
                }
                let interpretationNames = interpretations.compactMap { $0["allele_name"] as? String }
                let rawIDs = interpretations.compactMap { $0["raw_reference_id"] as? String }
                guard interpretationNames.count == interpretations.count,
                      rawIDs.count == interpretations.count,
                      Set(rawIDs).count == rawIDs.count else {
                    return false
                }
                let extensionNames = Set(extensionOf)
                let interpretedNames = Set(interpretationNames)
                switch record["classification"] as? String {
                case "extension":
                    return !extensionOf.isEmpty
                        && !interpretations.isEmpty
                        && interpretedNames == extensionNames
                case "partial-extension":
                    return schema >= 5
                        && !extensionOf.isEmpty
                        && interpretedNames.isSubset(of: extensionNames)
                default:
                    return extensionOf.isEmpty && interpretations.isEmpty
                }
            }
            guard valid else {
                throw integrityFailure(
                    .candidateArtifactMalformedJSON,
                    "Candidate artifact schema \(schema) requires consistent extension_of, extension_interpretations, and provisional_naming_ambiguous fields on every candidate.",
                    path: path
                )
            }
        }
    }

    private static func validateDocumentReferences(
        sequenceFASTA: ONTMHCArtifactReference,
        evidence: [ONTMHCArtifactReference],
        expectedSequenceFASTA: ONTMHCArtifactReference,
        expectedEvidence: [ONTMHCArtifactReference],
        reciprocalEvidenceLocators: [ONTMHCEvidenceLocator],
        genotypingEvidenceLocators: [ONTMHCEvidenceLocator],
        genotypingBAMPath: String?,
        reciprocalBAMPath: String?,
        documentPath: String?
    ) throws {
        guard sequenceFASTA == expectedSequenceFASTA else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "The document sequence_fasta reference does not exactly match the manifest FASTA reference.",
                path: documentPath
            )
        }
        guard canonicalReferences(evidence) == canonicalReferences(expectedEvidence) else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "The document evidence references do not exactly match the BAM/BAI artifacts declared by the manifest.",
                path: documentPath
            )
        }
        guard reciprocalEvidenceLocators.allSatisfy({ $0.bamPath == reciprocalBAMPath }) else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Candidate and un-nameable reciprocal evidence locators must name exactly the reciprocal BAM declared by the typed manifest role.",
                path: documentPath
            )
        }
        guard genotypingEvidenceLocators.allSatisfy({ $0.bamPath == genotypingBAMPath }) else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Candidate and un-nameable observation evidence locators must name exactly the genotyping BAM declared by the typed manifest role.",
                path: documentPath
            )
        }
    }

    private static func validateCompactCandidateDocument(
        _ document: ONTMHCCandidateAllelesDocument,
        genotypingBAMPath: String?,
        reciprocalBAMPath: String?,
        documentPath: String
    ) throws {
        try validateGlobalRawSourceOwnership(
            candidates: document,
            unnameable: nil,
            documentPath: documentPath
        )
        for record in document.candidates {
            let summary = record.reciprocalHitSummary
            let expectedQueryName = document.schemaVersion >= 4
                ? record.representativeSourceSequenceClusterID
                : record.stableClusterID
            guard summary.bamPath == reciprocalBAMPath,
                  summary.queryName == expectedQueryName,
                  record.selectedEvidence.bamPath == reciprocalBAMPath,
                  record.selectedEvidence.queryName == expectedQueryName,
                  document.schemaVersion < 4 || (
                      !record.sourceSequenceClusterIDs.isEmpty
                          && Set(record.sourceSequenceClusterIDs).count
                              == record.sourceSequenceClusterIDs.count
                          && record.sourceSequenceClusterIDs.contains(
                              record.representativeSourceSequenceClusterID
                          )
                  ),
                  summary.closestMatchTargetNames.contains(record.selectedEvidence.referenceName) else {
                throw compactBindingFailure(
                    "Candidate reciprocal summaries and selected evidence must belong to the record and typed reciprocal BAM, with the selected target in closest_match_target_names.",
                    path: documentPath
                )
            }
        }
        try validateCompactObservations(
            document.observations,
            sourceSequenceIDsByStableID: Dictionary(
                document.candidates.map {
                    ($0.stableClusterID, Set($0.sourceSequenceClusterIDs))
                },
                uniquingKeysWith: { $0.union($1) }
            ),
            schemaVersion: document.schemaVersion,
            genotypingBAMPath: genotypingBAMPath,
            documentPath: documentPath
        )
    }

    private static func validateCompactUnnameableDocument(
        _ document: ONTMHCUnnameableClustersDocument,
        genotypingBAMPath: String?,
        reciprocalBAMPath: String?,
        documentPath: String
    ) throws {
        for record in document.clusters {
            let summary = record.reciprocalHitSummary
            guard summary.bamPath == reciprocalBAMPath,
                  summary.queryName == record.stableClusterID else {
                throw compactBindingFailure(
                    "Un-nameable reciprocal summaries must belong to the record and typed reciprocal BAM.",
                    path: documentPath
                )
            }
            if summary.alignmentCount == 0 {
                guard record.selectedEvidence == nil,
                      summary.closestMatchTargetNames.isEmpty else {
                    throw compactBindingFailure(
                        "An un-nameable record without reciprocal alignments must not contain selected evidence or closest targets.",
                        path: documentPath
                    )
                }
            } else {
                guard let selected = record.selectedEvidence,
                      selected.bamPath == reciprocalBAMPath,
                      selected.queryName == record.stableClusterID,
                      summary.closestMatchTargetNames.contains(selected.referenceName) else {
                    throw compactBindingFailure(
                        "An aligned un-nameable record must select a closest target from the typed reciprocal BAM.",
                        path: documentPath
                    )
                }
            }
        }
        try validateCompactObservations(
            document.observations,
            sourceSequenceIDsByStableID: Dictionary(
                document.clusters.map { ($0.stableClusterID, Set([$0.stableClusterID])) },
                uniquingKeysWith: { $0.union($1) }
            ),
            schemaVersion: document.schemaVersion,
            genotypingBAMPath: genotypingBAMPath,
            documentPath: documentPath
        )
    }

    private static func validateGlobalRawSourceOwnership(
        candidates: ONTMHCCandidateAllelesDocument?,
        unnameable: ONTMHCUnnameableClustersDocument?,
        documentPath: String
    ) throws {
        guard (candidates?.schemaVersion ?? 0) >= 4
                || (unnameable?.schemaVersion ?? 0) >= 4 else { return }
        var ownerByRawSourceID: [String: String] = [:]
        for record in candidates?.candidates ?? [] {
            let owner = "candidate:\(record.stableClusterID)"
            for rawSourceID in record.sourceSequenceClusterIDs {
                if let existingOwner = ownerByRawSourceID[rawSourceID],
                   existingOwner != owner {
                    throw compactBindingFailure(
                        "Raw source sequence '\(rawSourceID)' is owned by multiple candidate records.",
                        path: documentPath
                    )
                }
                ownerByRawSourceID[rawSourceID] = owner
            }
        }
        for record in unnameable?.clusters ?? [] {
            let rawSourceID = record.stableClusterID
            if ownerByRawSourceID[rawSourceID] != nil {
                throw compactBindingFailure(
                    "Raw source sequence '\(rawSourceID)' is owned by multiple candidate or un-nameable records.",
                    path: documentPath
                )
            }
            ownerByRawSourceID[rawSourceID] = "unnameable:\(record.stableClusterID)"
        }
    }

    private static func validateCompactObservations(
        _ observations: [ONTMHCCandidateObservation],
        sourceSequenceIDsByStableID: [String: Set<String>],
        schemaVersion: Int,
        genotypingBAMPath: String?,
        documentPath: String
    ) throws {
        for observation in observations {
            let expectedTargets = Set(observation.sourceClusterIDs.map {
                "\(observation.sampleID)|\($0)"
            })
            let targetNames = observation.genotypingHitSummaries.map(\.targetName)
            guard let sourceSequenceIDs = sourceSequenceIDsByStableID[observation.stableClusterID],
                  schemaVersion < 4
                    || sourceSequenceIDs.contains(observation.sourceSequenceClusterID),
                  Set(targetNames).count == targetNames.count,
                  Set(targetNames).isSubset(of: expectedTargets),
                  observation.genotypingHitSummaries.allSatisfy({
                      $0.bamPath == genotypingBAMPath
                  }) else {
                throw compactBindingFailure(
                    "Observation hit summaries must belong to a document record, a unique sample/source target, and the typed genotyping BAM.",
                    path: documentPath
                )
            }
        }
    }

    private static func compactBindingFailure(
        _ detail: String,
        path: String
    ) -> CandidateIntegrityFailure {
        integrityFailure(
            .candidateArtifactDocumentReferenceMismatch,
            detail,
            path: path
        )
    }

    private static func canonicalReferences(_ references: [ONTMHCArtifactReference]) -> [String] {
        references.map { "\($0.path)\u{0}\($0.sha256.lowercased())\u{0}\($0.sizeBytes)" }.sorted()
    }

    private static func validateCandidateRecords(
        _ records: [ONTMHCCandidateRecord],
        fasta: ParsedFASTA,
        path: String
    ) throws {
        try validateFASTARecords(
            records.map { ($0.stableClusterID, $0.fastaRecordID, $0.sequenceSHA256) },
            fasta: fasta,
            path: path
        )
    }

    private static func validateUnnameableRecords(
        _ records: [ONTMHCUnnameableRecord],
        schemaVersion: Int,
        fasta: ParsedFASTA,
        path: String
    ) throws {
        guard records.allSatisfy({
            ($0.fastaRecordID == nil) == ($0.sequenceSHA256 == nil)
        }) else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Un-nameable records must provide both fasta_record_id and sequence_sha256 or neither.",
                path: path
            )
        }
        if schemaVersion < 4, records.contains(where: { $0.fastaRecordID == nil }) {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Un-nameable document schemas 1 through 3 require external FASTA identity and checksum fields.",
                path: path
            )
        }
        try validateFASTARecords(
            records.compactMap { record in
                guard let fastaRecordID = record.fastaRecordID,
                      let sequenceSHA256 = record.sequenceSHA256 else {
                    return nil
                }
                return (record.stableClusterID, fastaRecordID, sequenceSHA256)
            },
            fasta: fasta,
            path: path,
            requiresMatchingStableID: schemaVersion < 4
        )
    }

    private static func validateFASTARecords(
        _ records: [(stableID: String, fastaID: String, checksum: String)],
        fasta: ParsedFASTA,
        path: String,
        requiresMatchingStableID: Bool = true
    ) throws {
        guard records.allSatisfy({
            !$0.stableID.isEmpty
                && !$0.fastaID.isEmpty
                && (!requiresMatchingStableID || $0.stableID == $0.fastaID)
        }),
              Set(records.map(\.stableID)).count == records.count,
              Set(records.map(\.fastaID)).count == records.count else {
            throw integrityFailure(
                .candidateArtifactDocumentReferenceMismatch,
                "Every exported document record must have unique, non-empty stable and FASTA identities, with matching identities where required by the schema.",
                path: path
            )
        }
        let expected = Set(records.map(\.fastaID))
        if let missing = expected.sorted().first(where: { fasta.counts[$0] == nil }) {
            throw integrityFailure(
                .candidateArtifactMissingFASTARecord,
                "FASTA is missing declared stable cluster '\(missing)'.",
                path: path
            )
        }
        if let duplicate = expected.sorted().first(where: { fasta.counts[$0] != 1 }) {
            throw integrityFailure(
                .candidateArtifactDuplicateFASTARecord,
                "FASTA stable cluster '\(duplicate)' occurs \(fasta.counts[duplicate] ?? 0) times; expected exactly once.",
                path: path
            )
        }
        let extras = Set(fasta.counts.keys).subtracting(expected)
        if let extra = extras.sorted().first {
            throw integrityFailure(
                .candidateArtifactExtraFASTARecord,
                "FASTA contains undeclared record '\(extra)'.",
                path: path
            )
        }
        for record in records.sorted(by: { $0.stableID < $1.stableID }) {
            guard let checksum = fasta.sequenceChecksums[record.fastaID] else { continue }
            guard checksum == record.checksum.lowercased() else {
                throw integrityFailure(
                    .candidateArtifactSequenceChecksumMismatch,
                    "FASTA sequence SHA-256 for '\(record.fastaID)' is \(checksum), not the document value \(record.checksum).",
                    path: path
                )
            }
        }
    }

    private static func integrityFailure(
        _ code: ONTGenotypeIntegrityWarningCode,
        _ detail: String,
        path: String? = nil
    ) -> CandidateIntegrityFailure {
        CandidateIntegrityFailure(warning: ONTGenotypeIntegrityWarning(code: code, detail: detail, path: path))
    }

    private static func errnoDetail() -> String {
        String(cString: Darwin.strerror(errno))
    }

    public static func resolvedURL(for path: String, in bundleURL: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return bundleURL.appendingPathComponent(trimmed).standardizedFileURL
    }

    static func parseInt(_ value: String?) -> Int? {
        guard let double = parseDouble(value) else { return nil }
        return Int(double)
    }

    static func parseDouble(_ value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.hasSuffix("%") {
            text.removeLast()
        }
        text = text.replacingOccurrences(of: ",", with: "")
        return Double(text)
    }

    static func makeCall(row: [String: String]) -> ONTGenotypeCall? {
        let sample = (row["sample"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let genotype = (row["genotype"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty, !genotype.isEmpty else { return nil }
        return ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: parseInt(row["passed_alignments"]) ?? 0,
            passedUniqueReads: parseInt(row["passed_unique_reads"]) ?? 0,
            sampleTotalReads: parseInt(row["sample_total_reads"]),
            sampleUniqueRetainedReads: parseInt(row["sample_unique_retained_reads"]),
            sampleUniqueRetainedPercent: parseDouble(row["sample_unique_retained_percent"]),
            overallInputReads: parseInt(row["overall_input_reads"]),
            overallUniqueRetainedReads: parseInt(row["overall_unique_retained_reads"]),
            overallUniqueRetainedPercent: parseDouble(row["overall_unique_retained_percent"]),
            ambiguousWith: parseAmbiguityGroup(row["ambiguous_with"]),
            indelBases: parseInt(row["indel_bases"])
        )
    }

    /// `ambiguous_with` is a ";"-separated member list. Absent or
    /// empty (older bundles, rows without duplicates) means no group.
    static func parseAmbiguityGroup(_ value: String?) -> [String]? {
        let members = (value ?? "")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return members.count > 1 ? members : nil
    }

    private static func isAssignedSample(_ sample: String) -> Bool {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.lowercased() != "unassigned"
    }

    private static func orderedAssignedSampleNames(
        sampleRows: [[String: String]],
        calls: [ONTGenotypeCall]
    ) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for row in sampleRows {
            let sample = (row["sample"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isAssignedSample(sample), seen.insert(sample).inserted else { continue }
            names.append(sample)
        }
        for call in calls where seen.insert(call.sample).inserted {
            names.append(call.sample)
        }
        return names
    }

    private static func loadHaplotypeAnalysisIfPresent(
        from url: URL?
    ) throws -> GenotypeHaplotypeAnalysis? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GenotypeHaplotypeAnalysis.self, from: data)
    }

    private static func loadCSVRows(from url: URL) throws -> [[String: String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rows = parseCSV(content)
        guard let headers = rows.first else { return [] }
        return rows.dropFirst().compactMap { row in
            guard !isRepeatedCSVHeaderRow(row, headers: headers) else { return nil }
            var dict: [String: String] = [:]
            for index in headers.indices {
                let header = headers[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !header.isEmpty else { continue }
                dict[header] = index < row.count ? row[index] : ""
            }
            return dict
        }
    }

    private static func isRepeatedCSVHeaderRow(_ row: [String], headers: [String]) -> Bool {
        guard !headers.isEmpty, row.count >= headers.count else { return false }
        for index in headers.indices {
            let header = headers[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard value == header else { return false }
        }
        return true
    }

    private static func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()

        while let character = iterator.next() {
            switch character {
            case "\"":
                if inQuotes {
                    var peekIterator = iterator
                    if let next = peekIterator.next(), next == "\"" {
                        field.append("\"")
                        iterator = peekIterator
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            case "," where !inQuotes:
                row.append(field)
                field = ""
            case "\n" where !inQuotes:
                row.append(field)
                appendCSVRow(row, to: &rows)
                row = []
                field = ""
            case "\r" where !inQuotes:
                continue
            default:
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            appendCSVRow(row, to: &rows)
        }
        return rows
    }

    private static func appendCSVRow(_ row: [String], to rows: inout [[String]]) {
        let trimmed = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed.contains(where: { !$0.isEmpty }) {
            rows.append(trimmed)
        }
    }
}
