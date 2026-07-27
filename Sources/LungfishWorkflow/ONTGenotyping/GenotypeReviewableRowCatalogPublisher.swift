import Darwin
import CryptoKit
import Foundation
import LungfishIO

public enum GenotypeReviewableRowCatalogPublisherError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case invalidRosterSample(String)
    case duplicateRosterSample(String)
    case invalidInputDescriptor(String)
    case invalidCandidate(String)
    case duplicateReferenceSequenceID(String)
    case duplicateCandidateStableID(String)
    case sampleOutsideRoster(String)
    case duplicateCall(locus: String, genotype: String)
    case duplicateCallSample(locus: String, genotype: String, sample: String)
    case invalidSupport(sample: String, value: Int)
    case callWithoutAuthoritativeRow(locus: String, genotype: String)
    case candidateSupportMismatch(locus: String, genotype: String, sample: String)
    case outputOutsideBundle(String)
    case finalArtifactMismatch(String)
    case authorityChanged(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRosterSample(sample):
            return "The authoritative genotype roster contains invalid sample '\(sample)'."
        case let .duplicateRosterSample(sample):
            return "The authoritative genotype roster contains duplicate sample '\(sample)'."
        case let .invalidInputDescriptor(path):
            return "The genotype review-row authority descriptor is incomplete: \(path)."
        case let .invalidCandidate(stableID):
            return "The genotype review-row candidate is invalid: \(stableID)."
        case let .duplicateReferenceSequenceID(sequenceID):
            return "Duplicate exact-run reference sequence ID: \(sequenceID)."
        case let .duplicateCandidateStableID(stableID):
            return "Duplicate genotype review-row candidate stable ID: \(stableID)."
        case let .sampleOutsideRoster(sample):
            return "Genotype review-row evidence contains sample outside the authoritative roster: \(sample)."
        case let .duplicateCall(locus, genotype):
            return "Duplicate authoritative genotype call: \(locus), \(genotype)."
        case let .duplicateCallSample(locus, genotype, sample):
            return "Duplicate authoritative genotype call evidence: \(locus), \(genotype), \(sample)."
        case let .invalidSupport(sample, value):
            return "Genotype review-row evidence for \(sample) is invalid: \(value)."
        case let .callWithoutAuthoritativeRow(locus, genotype):
            return "Genotype call has no authoritative reference or candidate row: \(locus), \(genotype)."
        case let .candidateSupportMismatch(locus, genotype, sample):
            return "Candidate observation and call evidence disagree: \(locus), \(genotype), \(sample)."
        case let .outputOutsideBundle(path):
            return "The genotype reviewable-row catalog output is outside the result bundle: \(path)."
        case let .finalArtifactMismatch(path):
            return "The published genotype reviewable-row catalog does not match its staged payload: \(path)."
        case let .authorityChanged(path):
            return "The genotype review-row authority changed while it was being read: \(path)."
        }
    }
}

struct GenotypeReviewAuthorityFileSnapshot: Equatable, Sendable {
    let url: URL
    let data: Data
    let sha256: String
    let fileSize: UInt64
    let identity: FileSystemObjectIdentity
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    static func capture(
        _ url: URL,
        retainingData: Bool = true,
        readObserver: ((Int) -> Void)? = nil
    ) throws -> Self {
        let standardized = url.standardizedFileURL
        let parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(
            standardized.deletingLastPathComponent()
        )
        defer { Darwin.close(parentDescriptor) }
        let name = standardized.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw GenotypeReviewableRowCatalogPublisherError
                .invalidInputDescriptor(standardized.path)
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0 else {
            throw GenotypeReviewableRowCatalogPublisherError
                .invalidInputDescriptor(standardized.path)
        }
        var data = Data()
        if retainingData {
            data.reserveCapacity(Int(before.st_size))
        }
        var hasher = SHA256()
        var bytesRead: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            if retainingData {
                data.append(chunk)
            }
            bytesRead += UInt64(count)
            readObserver?(count)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              FileSystemObjectIdentity(from: before)
                == FileSystemObjectIdentity(from: after),
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              bytesRead == UInt64(after.st_size) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(standardized.path)
        }
        return Self(
            url: standardized,
            data: data,
            sha256: hasher.finalize()
                .map { String(format: "%02x", $0) }
                .joined(),
            fileSize: bytesRead,
            identity: FileSystemObjectIdentity(from: after),
            modificationSeconds: Int64(after.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            changeSeconds: Int64(after.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(after.st_ctimespec.tv_nsec)
        )
    }

    func requireUnchanged() throws {
        let current = try Self.capture(url, retainingData: false)
        guard current.identity == identity,
              current.fileSize == fileSize,
              current.sha256 == sha256,
              current.modificationSeconds == modificationSeconds,
              current.modificationNanoseconds == modificationNanoseconds,
              current.changeSeconds == changeSeconds,
              current.changeNanoseconds == changeNanoseconds else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(url.path)
        }
    }

    func requireMetadataUnchanged() throws {
        let standardized = url.standardizedFileURL
        let parentDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(
            standardized.deletingLastPathComponent()
        )
        defer { Darwin.close(parentDescriptor) }
        let descriptor = standardized.lastPathComponent.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(standardized.path)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              FileSystemObjectIdentity(from: info) == identity,
              UInt64(info.st_size) == fileSize,
              Int64(info.st_mtimespec.tv_sec) == modificationSeconds,
              Int64(info.st_mtimespec.tv_nsec) == modificationNanoseconds,
              Int64(info.st_ctimespec.tv_sec) == changeSeconds,
              Int64(info.st_ctimespec.tv_nsec) == changeNanoseconds else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(standardized.path)
        }
    }

    func descriptor(
        format: FileFormat?,
        role: FileRole
    ) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path,
            checksumSHA256: sha256,
            fileSize: fileSize,
            format: format,
            role: role
        )
    }
}

struct GenotypeReviewCSVSemanticAuthority: Sendable {
    let roster: [String]
    let calls: [ONTGenotypeCall]
    let sampleSnapshot: GenotypeReviewAuthorityFileSnapshot
    let reportSnapshot: GenotypeReviewAuthorityFileSnapshot

    static func capture(
        sampleSummaryURL: URL,
        reportURL: URL
    ) throws -> Self {
        let sampleSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            sampleSummaryURL
        )
        let reportSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            reportURL
        )
        let sampleRows = try rows(from: sampleSnapshot)
        let reportRows = try rows(from: reportSnapshot)
        let calls = try parseCalls(reportRows, path: reportURL.path)
        let roster = try parseRoster(sampleRows, path: sampleSummaryURL.path)
        let rosterSamples = Set(roster)
        if let outsideRoster = calls.first(where: {
            !rosterSamples.contains($0.sample)
        }) {
            throw GenotypeReviewableRowCatalogPublisherError
                .sampleOutsideRoster(outsideRoster.sample)
        }
        return Self(
            roster: roster,
            calls: calls,
            sampleSnapshot: sampleSnapshot,
            reportSnapshot: reportSnapshot
        )
    }

    func requireMatches(
        expectedRoster: [String],
        expectedCalls: [ONTGenotypeCall]
    ) throws {
        guard Set(roster) == Set(expectedRoster),
              roster.count == expectedRoster.count else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(
                    "\(sampleSnapshot.url.path) (captured roster \(roster), expected \(expectedRoster))"
                )
        }
        guard try Self.supportProjection(calls)
            == Self.supportProjection(expectedCalls) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(reportSnapshot.url.path)
        }
    }

    func requireUnchanged() throws {
        try sampleSnapshot.requireUnchanged()
        try reportSnapshot.requireUnchanged()
    }

    private struct SupportKey: Hashable {
        let sample: String
        let genotype: String
    }

    private struct SupportValue: Equatable {
        var alignments: Int
        var uniqueReads: Int
    }

    private static func supportProjection(
        _ calls: [ONTGenotypeCall]
    ) throws -> [SupportKey: SupportValue] {
        var result: [SupportKey: SupportValue] = [:]
        for call in calls {
            let key = SupportKey(sample: call.sample, genotype: call.genotype)
            var value = result[key] ?? SupportValue(
                alignments: 0,
                uniqueReads: 0
            )
            let alignments = value.alignments.addingReportingOverflow(
                call.passedAlignments
            )
            let uniqueReads = value.uniqueReads.addingReportingOverflow(
                call.passedUniqueReads
            )
            guard !alignments.overflow, !uniqueReads.overflow else {
                throw GenotypeReviewableRowCatalogPublisherError.invalidSupport(
                    sample: call.sample,
                    value: Int.max
                )
            }
            value.alignments = alignments.partialValue
            value.uniqueReads = uniqueReads.partialValue
            result[key] = value
        }
        return result
    }

    private static func rows(
        from snapshot: GenotypeReviewAuthorityFileSnapshot
    ) throws -> [[String: String]] {
        guard let content = String(data: snapshot.data, encoding: .utf8) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(snapshot.url.path)
        }
        let parsed = parseCSV(content)
        guard let header = parsed.first else { return [] }
        let normalizedHeader = header.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var seenHeaders = Set<String>()
        guard normalizedHeader.allSatisfy({
            !$0.isEmpty && seenHeaders.insert($0).inserted
        }) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(snapshot.url.path)
        }
        return parsed.dropFirst().map { row in
            Dictionary(uniqueKeysWithValues: normalizedHeader.enumerated().map {
                let value = $0.offset < row.count ? row[$0.offset] : ""
                return (
                    $0.element,
                    value.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            })
        }
    }

    private static func parseRoster(
        _ rows: [[String: String]],
        path: String
    ) throws -> [String] {
        var seen = Set<String>()
        return try rows.compactMap { row in
            let sample = row["sample", default: ""]
            guard isAssignedSample(sample) else { return nil }
            guard seen.insert(sample).inserted else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .authorityChanged(path)
            }
            return sample
        }
    }

    private static func parseCalls(
        _ rows: [[String: String]],
        path: String
    ) throws -> [ONTGenotypeCall] {
        try rows.compactMap { row in
            let sample = row["sample", default: ""]
            let genotype = row["genotype", default: ""]
            guard isAssignedSample(sample), !genotype.isEmpty else { return nil }
            guard let alignments = Int(row["passed_alignments", default: ""]),
                  let uniqueReads = Int(
                    row["passed_unique_reads", default: ""]
                  ),
                  alignments >= 0,
                  uniqueReads >= 0 else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .authorityChanged(path)
            }
            func optionalInt(_ key: String) -> Int? {
                let value = row[key, default: ""]
                return value.isEmpty ? nil : Int(value)
            }
            func optionalDouble(_ key: String) -> Double? {
                let value = row[key, default: ""]
                return value.isEmpty ? nil : Double(value)
            }
            return ONTGenotypeCall(
                sample: sample,
                genotype: genotype,
                passedAlignments: alignments,
                passedUniqueReads: uniqueReads,
                sampleTotalReads: optionalInt("sample_total_reads"),
                sampleUniqueRetainedReads: optionalInt(
                    "sample_unique_retained_reads"
                ),
                sampleUniqueRetainedPercent: optionalDouble(
                    "sample_unique_retained_percent"
                ),
                overallInputReads: optionalInt("overall_input_reads"),
                overallUniqueRetainedReads: optionalInt(
                    "overall_unique_retained_reads"
                ),
                overallUniqueRetainedPercent: optionalDouble(
                    "overall_unique_retained_percent"
                )
            )
        }
    }

    private static func isAssignedSample(_ sample: String) -> Bool {
        let normalized = sample
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !normalized.isEmpty && normalized != "unassigned"
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
                    var peek = iterator
                    if peek.next() == "\"" {
                        field.append("\"")
                        iterator = peek
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
                if row.contains(where: {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }) {
                    rows.append(row)
                }
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
            rows.append(row)
        }
        return rows
    }
}

public struct GenotypeReviewableRowCatalogRecoveryError:
    Error,
    LocalizedError,
    Sendable
{
    public enum State: String, Equatable, Sendable {
        case rollbackFailed
        case priorGenerationRemovalDurabilityUncertain
    }

    public let state: State
    public let primaryErrorDescription: String
    public let rollbackErrorDescription: String
    public let canonicalOutputPath: String
    public let recoveryPaths: [String]

    public init(
        state: State = .rollbackFailed,
        primaryErrorDescription: String,
        rollbackErrorDescription: String,
        canonicalOutputPath: String,
        recoveryPaths: [String]
    ) {
        self.state = state
        self.primaryErrorDescription = primaryErrorDescription
        self.rollbackErrorDescription = rollbackErrorDescription
        self.canonicalOutputPath = canonicalOutputPath
        self.recoveryPaths = recoveryPaths
    }

    public var errorDescription: String? {
        let stateDescription = state
            == .priorGenerationRemovalDurabilityUncertain
            ? "Prior-generation removal durability is uncertain."
            : "Rollback failed."
        return """
        \(primaryErrorDescription) \(stateDescription) \(rollbackErrorDescription) \
        Canonical output: \(canonicalOutputPath). Recoverable generations: \
        \(recoveryPaths.joined(separator: ", ")).
        """
    }
}

public struct GenotypeReviewableRowCatalogPublicationFailure:
    Error,
    LocalizedError,
    @unchecked Sendable
{
    public let message: String
    public let provenance: ProvenanceEnvelope
    public let underlyingError: Error

    public init(
        message: String,
        provenance: ProvenanceEnvelope,
        underlyingError: Error
    ) {
        self.message = message
        self.provenance = provenance
        self.underlyingError = underlyingError
    }

    public var errorDescription: String? { message }
}

/// A workflow-neutral projection of a validated candidate authority.
///
/// The miSeq pipeline derives provisional-exon-2 values from its exact
/// provisional sequence document. The full-length pipeline derives candidate
/// values from its candidate document and observations. The catalog publisher
/// intentionally does not reopen either source artifact.
public struct GenotypeReviewableRowCandidate: Equatable, Sendable {
    public let kind: GenotypeReviewableRowCatalog.RowKind
    public let stableID: String
    public let displayName: String
    public let locus: String
    public let supportBySample: [String: Int]
    fileprivate let validationError: GenotypeReviewableRowCatalogPublisherError?

    public init(
        kind: GenotypeReviewableRowCatalog.RowKind,
        stableID: String,
        displayName: String,
        locus: String,
        supportBySample: [String: Int]
    ) {
        self.kind = kind
        self.stableID = stableID
        self.displayName = displayName
        self.locus = locus
        self.supportBySample = supportBySample
        self.validationError = nil
    }

    public init(provisionalExon2 record: ONTGenotypeProvisionalExon2Record) {
        var supportBySample: [String: Int] = [:]
        var validationError:
            GenotypeReviewableRowCatalogPublisherError?
        for support in record.sampleSupport {
            let current = supportBySample[support.sample, default: 0]
            let addition = current.addingReportingOverflow(
                support.passedUniqueReads
            )
            if addition.overflow {
                validationError = .invalidSupport(
                    sample: support.sample,
                    value: Int.max
                )
                break
            }
            supportBySample[support.sample] = addition.partialValue
        }
        self.kind = .provisionalExon2
        self.stableID = "sha256:\(record.sequenceSHA256)"
        self.displayName = record.genotype
        self.locus = record.locus
        self.supportBySample = supportBySample
        self.validationError = validationError
    }

    public static func fullLengthCandidates(
        from document: ONTMHCCandidateAllelesDocument
    ) -> [Self] {
        var supportByStableID: [String: [String: Int]] = [:]
        var validationErrorByStableID:
            [String: GenotypeReviewableRowCatalogPublisherError] = [:]
        for observation in document.observations {
            let current = supportByStableID[
                observation.stableClusterID,
                default: [:]
            ][observation.sampleID, default: 0]
            let addition = current.addingReportingOverflow(
                observation.aggregatedSampleReadCount
            )
            if addition.overflow {
                validationErrorByStableID[observation.stableClusterID] =
                    .invalidSupport(
                        sample: observation.sampleID,
                        value: Int.max
                    )
            } else {
                supportByStableID[
                    observation.stableClusterID,
                    default: [:]
                ][observation.sampleID] = addition.partialValue
            }
        }
        return document.candidates.map { candidate in
            Self(
                kind: .candidate,
                stableID: candidate.stableClusterID,
                displayName: candidate.provisionalName,
                locus: candidate.locus,
                supportBySample:
                    supportByStableID[candidate.stableClusterID] ?? [:],
                validationError:
                    validationErrorByStableID[candidate.stableClusterID]
            )
        }
    }

    private init(
        kind: GenotypeReviewableRowCatalog.RowKind,
        stableID: String,
        displayName: String,
        locus: String,
        supportBySample: [String: Int],
        validationError: GenotypeReviewableRowCatalogPublisherError?
    ) {
        self.kind = kind
        self.stableID = stableID
        self.displayName = displayName
        self.locus = locus
        self.supportBySample = supportBySample
        self.validationError = validationError
    }
}

public struct GenotypeReviewableRowCatalogInputs: Sendable {
    public let referenceRecords: [MHCReferenceRecord]
    public let authoritativeSamples: [String]
    public let calls: [ONTGenotypeSharedCall]
    public let candidates: [GenotypeReviewableRowCandidate]
    public let inputDescriptors: [ProvenanceFileDescriptor]
    public let workflowName: String
    public let workflowVersion: String
    public let toolVersion: String
    public let argv: [String]
    public let userVisibleOptions: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity

    public init(
        referenceRecords: [MHCReferenceRecord],
        authoritativeSamples: [String],
        calls: [ONTGenotypeSharedCall],
        candidates: [GenotypeReviewableRowCandidate] = [],
        inputDescriptors: [ProvenanceFileDescriptor],
        workflowName: String,
        workflowVersion: String,
        toolVersion: String,
        argv: [String],
        userVisibleOptions: [String: ParameterValue],
        resolvedDefaults: [String: ParameterValue],
        runtimeIdentity: ProvenanceRuntimeIdentity
    ) {
        self.referenceRecords = referenceRecords
        self.authoritativeSamples = authoritativeSamples
        self.calls = calls
        self.candidates = candidates
        self.inputDescriptors = inputDescriptors
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolVersion = toolVersion
        self.argv = argv
        self.userVisibleOptions = userVisibleOptions
        self.resolvedDefaults = resolvedDefaults
        self.runtimeIdentity = runtimeIdentity
    }
}

public struct GenotypeReviewableRowCatalogPublication: Sendable {
    public let document: GenotypeReviewableRowCatalog
    public let artifact: ONTMHCArtifactReference
    public let outputURL: URL
    public let provenance: ProvenanceEnvelope

    public init(
        document: GenotypeReviewableRowCatalog,
        artifact: ONTMHCArtifactReference,
        outputURL: URL,
        provenance: ProvenanceEnvelope
    ) {
        self.document = document
        self.artifact = artifact
        self.outputURL = outputURL
        self.provenance = provenance
    }

}

public struct GenotypeReviewableRowCatalogPublisher: Sendable {
    private struct PostPublicationAuthorityFailure: LocalizedError {
        let underlying: Error
        let rollbackPath: String

        var errorDescription: String? {
            "\(underlying.localizedDescription) Rollback paths: \(rollbackPath)"
        }
    }

    public enum PublicationPhase: Equatable, Sendable {
        case staged
        case published
    }

    public enum RollbackPhase: Equatable, Sendable {
        case beforeRestoreExchange
        case beforeDetachNewOutput
        case beforeRemoveRecovery
        case afterFinalIdentityCheckBeforeTerminalDeletion
        case beforeSyncRecoveryRemoval
    }

    private struct DisplayIdentity: Hashable {
        let locus: String
        let displayName: String
    }

    private struct StorageIdentity: Hashable {
        let kind: GenotypeReviewableRowCatalog.RowKind
        let locus: String
        let displayName: String
        let stableID: String?
    }

    private struct MutableRow {
        let kind: GenotypeReviewableRowCatalog.RowKind
        let callID: String
        let displayName: String
        let locus: String
        let stableID: String?
        let section: String
        var supportBySample: [String: Int]
    }

    private struct CatalogPayloadAttestation {
        let sha256: String
        let fileSize: UInt64
        let identity: FileSystemObjectIdentity
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        func hasSameSemanticPayload(as other: Self) -> Bool {
            sha256 == other.sha256 && fileSize == other.fileSize
        }
    }

    private let dateProvider: @Sendable () -> Date
    private let publicationObserver: @Sendable (PublicationPhase) throws -> Void
    private let rollbackObserver: @Sendable (RollbackPhase) throws -> Void
    private let finalArtifactDescriptorProvider:
        (@Sendable (URL) throws -> (sha256: String, fileSize: UInt64))?

    public init(
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        publicationObserver: @escaping @Sendable (PublicationPhase) throws -> Void = { _ in },
        rollbackObserver: @escaping @Sendable (RollbackPhase) throws -> Void = { _ in },
        finalArtifactDescriptorProvider:
            (@Sendable (URL) throws -> (sha256: String, fileSize: UInt64))? = nil
    ) {
        self.dateProvider = dateProvider
        self.publicationObserver = publicationObserver
        self.rollbackObserver = rollbackObserver
        self.finalArtifactDescriptorProvider = finalArtifactDescriptorProvider
    }

    public func publish(
        _ inputs: GenotypeReviewableRowCatalogInputs,
        to bundleDirectoryURL: URL,
        postPublicationAuthorityCheck:
            @escaping @Sendable () throws -> Void = {}
    ) throws -> GenotypeReviewableRowCatalogPublication {
        let startedAt = dateProvider()
        do {
            return try publish(
                inputs,
                to: bundleDirectoryURL,
                startedAt: startedAt,
                postPublicationAuthorityCheck: postPublicationAuthorityCheck
            )
        } catch let failure as GenotypeReviewableRowCatalogPublicationFailure {
            throw failure
        } catch {
            let completedAt = dateProvider()
            throw GenotypeReviewableRowCatalogPublicationFailure(
                message: error.localizedDescription,
                provenance: failureProvenance(
                    inputs: inputs,
                    bundleDirectoryURL: bundleDirectoryURL,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    error: error
                ),
                underlyingError: error
            )
        }
    }

    private func publish(
        _ inputs: GenotypeReviewableRowCatalogInputs,
        to bundleDirectoryURL: URL,
        startedAt: Date,
        postPublicationAuthorityCheck:
            @escaping @Sendable () throws -> Void
    ) throws -> GenotypeReviewableRowCatalogPublication {
        let roster = try validatedRoster(inputs.authoritativeSamples)
        try validateInputDescriptors(inputs.inputDescriptors)
        let references = try referenceRows(
            inputs.referenceRecords,
            roster: roster
        )
        var rowsByIdentity = references.rows
        let candidatesByDisplay = try appendCandidates(
            inputs.candidates,
            roster: roster,
            rowsByIdentity: &rowsByIdentity
        )
        try reconcileCalls(
            inputs.calls,
            roster: roster,
            referencesBySequenceID: references.bySequenceID,
            candidatesByDisplay: candidatesByDisplay,
            rowsByIdentity: &rowsByIdentity
        )

        let rows = rowsByIdentity.values
            .map { row in
                GenotypeReviewableRowCatalog.Row(
                    kind: row.kind,
                    callID: row.callID,
                    displayName: row.displayName,
                    locus: row.locus,
                    stableID: row.stableID,
                    section: row.section,
                    sortKey: sortKey(
                        kind: row.kind,
                        locus: row.locus,
                        displayName: row.displayName,
                        stableID: row.stableID
                    ),
                    supportBySample: row.supportBySample
                )
            }
            .sorted { $0.sortKey < $1.sortKey }
        let document = try GenotypeReviewableRowCatalog(
            samples: inputs.authoritativeSamples,
            rows: rows
        ).validated()
        let outputURL = bundleDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent("genotype-reviewable-rows.json")
            .standardizedFileURL
        let relativeOutputPath = try relativePath(
            from: bundleDirectoryURL,
            to: outputURL
        )
        var encoded = try document.encoded()
        encoded.append(0x0a)
        let finalDescriptor = try publishCatalogData(
            encoded,
            bundleDirectoryURL: bundleDirectoryURL,
            outputURL: outputURL,
            postPublicationAuthorityCheck: postPublicationAuthorityCheck
        )

        let outputHash = finalDescriptor.sha256
        let outputSize = finalDescriptor.fileSize
        let artifact = ONTMHCArtifactReference(
            path: relativeOutputPath,
            sha256: outputHash,
            sizeBytes: Int64(outputSize)
        )
        let outputDescriptor = ProvenanceFileDescriptor(
            path: outputURL.path,
            checksumSHA256: outputHash,
            fileSize: outputSize,
            format: .json,
            role: .report
        )
        let completedAt = dateProvider()
        let options = ProvenanceOptions(
            explicit: inputs.userVisibleOptions,
            resolvedDefaults: inputs.resolvedDefaults
        )
        let step = ProvenanceStep(
            toolName: "lungfish genotype reviewable row catalog publisher",
            toolVersion: inputs.toolVersion,
            argv: inputs.argv,
            durableReplayArgv: inputs.argv,
            reproducibleCommand: inputs.argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: inputs.userVisibleOptions.merging(inputs.resolvedDefaults) {
                explicit, _ in explicit
            },
            runtimeIdentity: inputs.runtimeIdentity,
            inputs: inputs.inputDescriptors,
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let provenance = ProvenanceEnvelope(
            createdAt: completedAt,
            workflowName: inputs.workflowName,
            workflowVersion: inputs.workflowVersion,
            toolName: "lungfish genotype reviewable row catalog publisher",
            toolVersion: inputs.toolVersion,
            tool: ProvenanceToolIdentity(
                name: "lungfish genotype reviewable row catalog publisher",
                version: inputs.toolVersion,
                kind: "in-process"
            ),
            argv: inputs.argv,
            durableReplayArgv: inputs.argv,
            reproducibleCommand: inputs.argv.map(shellEscape).joined(separator: " "),
            options: options,
            runtimeIdentity: inputs.runtimeIdentity,
            files: inputs.inputDescriptors + [outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0,
            stderr: nil
        )
        return GenotypeReviewableRowCatalogPublication(
            document: document,
            artifact: artifact,
            outputURL: outputURL,
            provenance: provenance
        )
    }

    private func validatedRoster(_ samples: [String]) throws -> Set<String> {
        var roster = Set<String>()
        roster.reserveCapacity(samples.count)
        for sample in samples {
            guard isCanonicalNonempty(sample) else {
                throw GenotypeReviewableRowCatalogPublisherError.invalidRosterSample(sample)
            }
            guard roster.insert(sample).inserted else {
                throw GenotypeReviewableRowCatalogPublisherError.duplicateRosterSample(sample)
            }
        }
        return roster
    }

    private func validateInputDescriptors(
        _ descriptors: [ProvenanceFileDescriptor]
    ) throws {
        guard !descriptors.isEmpty else {
            throw GenotypeReviewableRowCatalogPublisherError.invalidInputDescriptor(
                "no authority descriptors"
            )
        }
        for descriptor in descriptors {
            guard isCanonicalNonempty(descriptor.path),
                  let checksum = descriptor.checksumSHA256,
                  checksum.count == 64,
                  checksum.allSatisfy(\.isHexDigit),
                  descriptor.fileSize != nil else {
                throw GenotypeReviewableRowCatalogPublisherError.invalidInputDescriptor(
                    descriptor.path
                )
            }
        }
    }

    private func referenceRows(
        _ records: [MHCReferenceRecord],
        roster: Set<String>
    ) throws -> (
        rows: [StorageIdentity: MutableRow],
        bySequenceID: [String: DisplayIdentity]
    ) {
        var rows: [StorageIdentity: MutableRow] = [:]
        var bySequenceID: [String: DisplayIdentity] = [:]
        rows.reserveCapacity(records.count)
        bySequenceID.reserveCapacity(records.count)
        for record in records {
            let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(record.locus)
            guard locus != "Unknown", isCanonicalNonempty(record.alleleName) else {
                throw GenotypeReviewableRowCatalogPublisherError.invalidCandidate(
                    record.sequenceID
                )
            }
            let displayIdentity = DisplayIdentity(
                locus: locus,
                displayName: record.alleleName
            )
            guard bySequenceID.updateValue(
                displayIdentity,
                forKey: record.sequenceID
            ) == nil else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .duplicateReferenceSequenceID(record.sequenceID)
            }
            let identity = StorageIdentity(
                kind: .reference,
                locus: locus,
                displayName: record.alleleName,
                stableID: nil
            )
            if rows[identity] != nil {
                continue
            }
            rows[identity] = MutableRow(
                kind: .reference,
                callID: "reference:\(locus):\(record.alleleName)",
                displayName: record.alleleName,
                locus: locus,
                stableID: nil,
                section: "reference",
                supportBySample: zeroSupport(roster)
            )
        }
        return (rows, bySequenceID)
    }

    private func appendCandidates(
        _ candidates: [GenotypeReviewableRowCandidate],
        roster: Set<String>,
        rowsByIdentity: inout [StorageIdentity: MutableRow]
    ) throws -> [DisplayIdentity: [StorageIdentity]] {
        var stableIDs = Set<String>()
        var identitiesByDisplay: [DisplayIdentity: [StorageIdentity]] = [:]
        stableIDs.reserveCapacity(candidates.count)
        identitiesByDisplay.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let validationError = candidate.validationError {
                throw validationError
            }
            let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(candidate.locus)
            guard candidate.kind.requiresStableID,
                  locus != "Unknown",
                  isCanonicalNonempty(candidate.stableID),
                  isCanonicalNonempty(candidate.displayName) else {
                throw GenotypeReviewableRowCatalogPublisherError.invalidCandidate(
                    candidate.stableID
                )
            }
            guard stableIDs.insert(candidate.stableID).inserted else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .duplicateCandidateStableID(candidate.stableID)
            }
            let displayIdentity = DisplayIdentity(
                locus: locus,
                displayName: candidate.displayName
            )
            let identity = StorageIdentity(
                kind: candidate.kind,
                locus: locus,
                displayName: candidate.displayName,
                stableID: candidate.stableID
            )
            var support = zeroSupport(roster)
            for (sample, value) in candidate.supportBySample {
                guard roster.contains(sample) else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .sampleOutsideRoster(sample)
                }
                guard value >= 0 else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .invalidSupport(sample: sample, value: value)
                }
                support[sample] = value
            }
            rowsByIdentity[identity] = MutableRow(
                kind: candidate.kind,
                callID: "\(candidate.kind.rawValue):\(locus):\(candidate.stableID)",
                displayName: candidate.displayName,
                locus: locus,
                stableID: candidate.stableID,
                section: candidate.kind.rawValue,
                supportBySample: support
            )
            identitiesByDisplay[displayIdentity, default: []].append(identity)
        }
        return identitiesByDisplay
    }

    private func reconcileCalls(
        _ calls: [ONTGenotypeSharedCall],
        roster: Set<String>,
        referencesBySequenceID: [String: DisplayIdentity],
        candidatesByDisplay: [DisplayIdentity: [StorageIdentity]],
        rowsByIdentity: inout [StorageIdentity: MutableRow]
    ) throws {
        var seenCalls = Set<DisplayIdentity>()
        var seenRawCalls = Set<DisplayIdentity>()
        var referenceSupport:
            [StorageIdentity: [String: Int]] = [:]
        seenCalls.reserveCapacity(calls.count)
        for call in calls {
            let locus = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locus)
            let rawIdentity = DisplayIdentity(locus: locus, displayName: call.genotype)
            guard seenRawCalls.insert(rawIdentity).inserted else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .duplicateCall(locus: locus, genotype: call.genotype)
            }
            let displayIdentity: DisplayIdentity
            if let referenceIdentity = referencesBySequenceID[call.genotype] {
                guard referenceIdentity.locus == locus else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .callWithoutAuthoritativeRow(
                            locus: locus,
                            genotype: call.genotype
                        )
                }
                displayIdentity = referenceIdentity
            } else {
                displayIdentity = rawIdentity
            }
            let referenceIdentity = StorageIdentity(
                kind: .reference,
                locus: displayIdentity.locus,
                displayName: displayIdentity.displayName,
                stableID: nil
            )
            let candidateIdentities = candidatesByDisplay[displayIdentity] ?? []
            guard displayIdentity.locus != "Unknown",
                  rowsByIdentity[referenceIdentity] != nil
                    || candidateIdentities.count == 1 else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .callWithoutAuthoritativeRow(locus: locus, genotype: call.genotype)
            }
            var seenSamples = Set<String>()
            var callSupport = zeroSupport(roster)
            for sampleSupport in call.sampleSupport {
                let sample = sampleSupport.sample
                guard roster.contains(sample) else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .sampleOutsideRoster(sample)
                }
                guard seenSamples.insert(sample).inserted else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .duplicateCallSample(
                            locus: locus,
                            genotype: call.genotype,
                            sample: sample
                        )
                }
                guard sampleSupport.passedUniqueReads >= 0 else {
                    throw GenotypeReviewableRowCatalogPublisherError.invalidSupport(
                        sample: sample,
                        value: sampleSupport.passedUniqueReads
                    )
                }
                callSupport[sample] = sampleSupport.passedUniqueReads
            }
            if let candidateIdentity = candidateIdentities.first,
               rowsByIdentity[referenceIdentity] == nil {
                guard seenCalls.insert(displayIdentity).inserted else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .duplicateCall(locus: locus, genotype: call.genotype)
                }
                for sample in roster
                where rowsByIdentity[candidateIdentity]!.supportBySample[sample]
                    != callSupport[sample] {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .candidateSupportMismatch(
                            locus: locus,
                            genotype: call.genotype,
                            sample: sample
                        )
                }
            } else {
                var accumulated = referenceSupport[referenceIdentity]
                    ?? zeroSupport(roster)
                for sample in roster {
                    let (value, overflow) = accumulated[sample]!.addingReportingOverflow(
                        callSupport[sample]!
                    )
                    guard !overflow else {
                        throw GenotypeReviewableRowCatalogPublisherError.invalidSupport(
                            sample: sample,
                            value: Int.max
                        )
                    }
                    accumulated[sample] = value
                }
                referenceSupport[referenceIdentity] = accumulated
            }
        }
        for (identity, support) in referenceSupport {
            rowsByIdentity[identity]!.supportBySample = support
        }
    }

    private func zeroSupport(_ roster: Set<String>) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: roster.map { ($0, 0) })
    }

    private func sortKey(
        kind: GenotypeReviewableRowCatalog.RowKind,
        locus: String,
        displayName: String,
        stableID: String?
    ) -> String {
        let rank: String
        switch kind {
        case .reference:
            rank = "0"
        case .provisionalExon2:
            rank = "1"
        case .candidate:
            rank = "2"
        }
        return "\(rank)|\(locus)|\(displayName)|\(stableID ?? "")"
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) throws -> String {
        let directory = directoryURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard file.hasPrefix(prefix) else {
            throw GenotypeReviewableRowCatalogPublisherError.outputOutsideBundle(file)
        }
        return String(file.dropFirst(prefix.count))
    }

    private func publishCatalogData(
        _ data: Data,
        bundleDirectoryURL: URL,
        outputURL: URL,
        postPublicationAuthorityCheck:
            @escaping @Sendable () throws -> Void
    ) throws -> CatalogPayloadAttestation {
        let bundleDescriptor = try NoFollowFileSystem.openDirectoryHierarchy(
            bundleDirectoryURL
        )
        defer { Darwin.close(bundleDescriptor) }
        let artifactsDescriptor = try openOrCreateDirectory(
            named: "artifacts",
            in: bundleDescriptor,
            displayedAt: bundleDirectoryURL
        )
        defer { Darwin.close(artifactsDescriptor) }
        let projectionsURL = bundleDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
        let projectionsDescriptor = try openOrCreateDirectory(
            named: "projections",
            in: artifactsDescriptor,
            displayedAt: bundleDirectoryURL.appendingPathComponent("artifacts")
        )
        defer { Darwin.close(projectionsDescriptor) }

        let outputName = "genotype-reviewable-rows.json"
        let stagingName = ".\(outputName).staging-\(UUID().uuidString.lowercased())"
        let stagingURL = projectionsURL.appendingPathComponent(stagingName)
        let stagingDescriptor = stagingName.withCString {
            Darwin.openat(
                projectionsDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard stagingDescriptor >= 0 else {
            throw posixError()
        }
        var stagingIsOpen = true
        var removeUnpublishedStaging = true
        defer {
            if stagingIsOpen {
                Darwin.close(stagingDescriptor)
            }
            if removeUnpublishedStaging {
                _ = stagingName.withCString {
                    Darwin.unlinkat(projectionsDescriptor, $0, 0)
                }
            }
        }

        try writeAll(data, to: stagingDescriptor, displayedAt: stagingURL)
        guard Darwin.fsync(stagingDescriptor) == 0 else { throw posixError() }
        var stagedInfo = stat()
        guard Darwin.fstat(stagingDescriptor, &stagedInfo) == 0,
              stagedInfo.st_mode & S_IFMT == S_IFREG else {
            throw posixError(defaultCode: EINVAL)
        }
        let stagedIdentity = FileSystemObjectIdentity(from: stagedInfo)
        guard Darwin.close(stagingDescriptor) == 0 else {
            stagingIsOpen = false
            throw posixError()
        }
        stagingIsOpen = false
        let stagedAttestation = try descriptorSnapshot(
            named: stagingName,
            expectedIdentity: stagedIdentity,
            in: projectionsDescriptor,
            displayedAt: stagingURL
        )
        let semanticSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard stagedAttestation.sha256 == semanticSHA256,
              stagedAttestation.fileSize == UInt64(data.count) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .finalArtifactMismatch(stagingURL.path)
        }
        try publicationObserver(.staged)

        let previousIdentity = try regularFileIdentityIfPresent(
            named: outputName,
            in: projectionsDescriptor,
            displayedAt: outputURL
        )
        let renameStatus: Int32
        if previousIdentity != nil {
            renameStatus = stagingName.withCString { staging in
                outputName.withCString { output in
                    Darwin.renameatx_np(
                        projectionsDescriptor,
                        staging,
                        projectionsDescriptor,
                        output,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
        } else {
            renameStatus = stagingName.withCString { staging in
                outputName.withCString { output in
                    Darwin.renameatx_np(
                        projectionsDescriptor,
                        staging,
                        projectionsDescriptor,
                        output,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard renameStatus == 0 else { throw posixError() }
        removeUnpublishedStaging = false
        guard Darwin.fsync(projectionsDescriptor) == 0 else {
            let primary = posixError()
            try rollbackPublication(
                primaryError: primary,
                previousIdentity: previousIdentity,
                stagedIdentity: stagedIdentity,
                outputName: outputName,
                stagingName: stagingName,
                directoryDescriptor: projectionsDescriptor,
                directoryURL: projectionsURL,
                outputURL: outputURL
            )
            throw primary
        }

        do {
            try publicationObserver(.published)
            let exactDescriptor = try descriptorSnapshot(
                named: outputName,
                expectedIdentity: stagedIdentity,
                in: projectionsDescriptor,
                displayedAt: outputURL
            )
            guard exactDescriptor.hasSameSemanticPayload(
                as: stagedAttestation
            ) else {
                throw GenotypeReviewableRowCatalogPublisherError
                    .finalArtifactMismatch(outputURL.path)
            }
            if let finalArtifactDescriptorProvider {
                let injectedDescriptor = try finalArtifactDescriptorProvider(outputURL)
                guard injectedDescriptor.sha256 == exactDescriptor.sha256,
                      injectedDescriptor.fileSize == exactDescriptor.fileSize else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .finalArtifactMismatch(outputURL.path)
                }
            }
            do {
                try postPublicationAuthorityCheck()
            } catch {
                throw PostPublicationAuthorityFailure(
                    underlying: error,
                    rollbackPath: outputURL.path
                )
            }
            if previousIdentity != nil {
                do {
                    guard try regularFileIdentityIfPresent(
                        named: stagingName,
                        in: projectionsDescriptor,
                        displayedAt: stagingURL
                    ) == previousIdentity else {
                        throw GenotypeReviewableRowCatalogPublisherError
                            .finalArtifactMismatch(
                                "The retained prior catalog identity changed before cleanup."
                            )
                    }
                    let retiredName =
                        ".\(outputName).retired-\(UUID().uuidString.lowercased())"
                    let retiredURL = projectionsURL
                        .appendingPathComponent(retiredName)
                    try detachVerifyAndRemove(
                        sourceName: stagingName,
                        detachedName: retiredName,
                        expectedIdentity: previousIdentity!,
                        directoryDescriptor: projectionsDescriptor,
                        displayedAt: retiredURL
                    )
                } catch {
                    let recoveryURLs = existingRecoveryURLs(
                        namesAndURLs: [
                            (outputName, outputURL),
                            (stagingName, stagingURL),
                        ] + recoveryEntries(
                            prefix: ".\(outputName).retired-",
                            in: projectionsURL
                        ),
                        in: projectionsDescriptor
                    )
                    throw recoveryError(
                        primary: GenotypeReviewableRowCatalogPublisherError
                            .finalArtifactMismatch(
                                "Published catalog is valid but the prior generation could not be removed."
                        ),
                        rollback: error,
                        outputURL: outputURL,
                        recoveryURLs: recoveryURLs,
                        state: recoveryURLs.contains(stagingURL)
                            ? .rollbackFailed
                            : .priorGenerationRemovalDurabilityUncertain
                    )
                }
            }
            return exactDescriptor
        } catch let recovery as GenotypeReviewableRowCatalogRecoveryError {
            throw recovery
        } catch {
            try rollbackPublication(
                primaryError: error,
                previousIdentity: previousIdentity,
                stagedIdentity: stagedIdentity,
                outputName: outputName,
                stagingName: stagingName,
                directoryDescriptor: projectionsDescriptor,
                directoryURL: projectionsURL,
                outputURL: outputURL
            )
            throw error
        }
    }

    private func rollbackPublication(
        primaryError: Error,
        previousIdentity: FileSystemObjectIdentity?,
        stagedIdentity: FileSystemObjectIdentity,
        outputName: String,
        stagingName: String,
        directoryDescriptor: Int32,
        directoryURL: URL,
        outputURL: URL
    ) throws {
        let stagingURL = directoryURL.appendingPathComponent(stagingName)
        if let previousIdentity {
            do {
                guard try regularFileIdentityIfPresent(
                    named: outputName,
                    in: directoryDescriptor,
                    displayedAt: outputURL
                ) == stagedIdentity,
                try regularFileIdentityIfPresent(
                    named: stagingName,
                    in: directoryDescriptor,
                    displayedAt: stagingURL
                ) == previousIdentity else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .finalArtifactMismatch(
                            "Publication identities changed before rollback."
                        )
                }
                try rollbackObserver(.beforeRestoreExchange)
                let status = stagingName.withCString { staging in
                    outputName.withCString { output in
                        Darwin.renameatx_np(
                            directoryDescriptor,
                            staging,
                            directoryDescriptor,
                            output,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                guard status == 0 else { throw posixError() }
                guard Darwin.fsync(directoryDescriptor) == 0 else {
                    throw posixError()
                }
                guard try regularFileIdentityIfPresent(
                    named: outputName,
                    in: directoryDescriptor,
                    displayedAt: outputURL
                ) == previousIdentity,
                try regularFileIdentityIfPresent(
                    named: stagingName,
                    in: directoryDescriptor,
                    displayedAt: stagingURL
                ) == stagedIdentity else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .finalArtifactMismatch(
                            "Publication identities changed during rollback."
                        )
                }
                let retiredName =
                    ".\(outputName).retired-\(UUID().uuidString.lowercased())"
                try detachVerifyAndRemove(
                    sourceName: stagingName,
                    detachedName: retiredName,
                    expectedIdentity: stagedIdentity,
                    directoryDescriptor: directoryDescriptor,
                    displayedAt:
                        directoryURL.appendingPathComponent(retiredName)
                )
            } catch {
                throw recoveryError(
                    primary: primaryError,
                    rollback: error,
                    outputURL: outputURL,
                    recoveryURLs: existingRecoveryURLs(
                        namesAndURLs: [
                            (outputName, outputURL),
                            (stagingName, stagingURL),
                        ] + recoveryEntries(
                            prefix: ".\(outputName).retired-",
                            in: directoryURL
                        ),
                        in: directoryDescriptor
                    )
                )
            }
        } else {
            do {
                guard try regularFileIdentityIfPresent(
                    named: outputName,
                    in: directoryDescriptor,
                    displayedAt: outputURL
                ) == stagedIdentity else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .finalArtifactMismatch(
                            "Published catalog identity changed before rollback."
                        )
                }
                try rollbackObserver(.beforeDetachNewOutput)
                let status = outputName.withCString { output in
                    stagingName.withCString { staging in
                        Darwin.renameatx_np(
                            directoryDescriptor,
                            output,
                            directoryDescriptor,
                            staging,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard status == 0 else { throw posixError() }
                guard Darwin.fsync(directoryDescriptor) == 0 else {
                    throw posixError()
                }
                guard try regularFileIdentityIfPresent(
                    named: stagingName,
                    in: directoryDescriptor,
                    displayedAt: stagingURL
                ) == stagedIdentity else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .finalArtifactMismatch(
                            "Published catalog identity changed during rollback."
                        )
                }
                let retiredName =
                    ".\(outputName).retired-\(UUID().uuidString.lowercased())"
                try detachVerifyAndRemove(
                    sourceName: stagingName,
                    detachedName: retiredName,
                    expectedIdentity: stagedIdentity,
                    directoryDescriptor: directoryDescriptor,
                    displayedAt:
                        directoryURL.appendingPathComponent(retiredName)
                )
            } catch {
                throw recoveryError(
                    primary: primaryError,
                    rollback: error,
                    outputURL: outputURL,
                    recoveryURLs: existingRecoveryURLs(
                        namesAndURLs: [
                            (outputName, outputURL),
                            (stagingName, stagingURL),
                        ] + recoveryEntries(
                            prefix: ".\(outputName).retired-",
                            in: directoryURL
                        ),
                        in: directoryDescriptor
                    )
                )
            }
        }
    }

    private func detachVerifyAndRemove(
        sourceName: String,
        detachedName: String,
        expectedIdentity: FileSystemObjectIdentity,
        directoryDescriptor: Int32,
        displayedAt detachedURL: URL
    ) throws {
        let status = sourceName.withCString { source in
            detachedName.withCString { detached in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    source,
                    directoryDescriptor,
                    detached,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else { throw posixError() }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError()
        }
        try rollbackObserver(.beforeRemoveRecovery)
        guard try regularFileIdentityIfPresent(
            named: detachedName,
            in: directoryDescriptor,
            displayedAt: detachedURL
        ) == expectedIdentity else {
            throw GenotypeReviewableRowCatalogPublisherError
                .finalArtifactMismatch(
                    "Detached catalog generation identity changed before removal."
                )
        }
        try rollbackObserver(
            .afterFinalIdentityCheckBeforeTerminalDeletion
        )
        // Never unlink the observer-visible name. Move its current entry to a
        // fresh terminal name, then bind deletion to a second identity check.
        // A late substitution is preserved instead of being deleted.
        let terminalName =
            "\(detachedName).terminal-\(UUID().uuidString.lowercased())"
        let terminalURL = detachedURL.deletingLastPathComponent()
            .appendingPathComponent(terminalName)
        let terminalStatus = detachedName.withCString { detached in
            terminalName.withCString { terminal in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    detached,
                    directoryDescriptor,
                    terminal,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard terminalStatus == 0 else { throw posixError() }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError()
        }
        guard try regularFileIdentityIfPresent(
            named: terminalName,
            in: directoryDescriptor,
            displayedAt: terminalURL
        ) == expectedIdentity else {
            _ = terminalName.withCString { terminal in
                detachedName.withCString { detached in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        terminal,
                        directoryDescriptor,
                        detached,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            _ = Darwin.fsync(directoryDescriptor)
            throw GenotypeReviewableRowCatalogPublisherError
                .finalArtifactMismatch(
                    "Terminal catalog generation identity changed before removal."
                )
        }
        guard terminalName.withCString({
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }) == 0 else {
            throw posixError()
        }
        try rollbackObserver(.beforeSyncRecoveryRemoval)
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError()
        }
    }

    private func recoveryEntries(
        prefix: String,
        in directoryURL: URL
    ) -> [(String, URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directoryURL.path
        )) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map {
            ($0, directoryURL.appendingPathComponent($0))
        }
    }

    private func recoveryError(
        primary: Error,
        rollback: Error,
        outputURL: URL,
        recoveryURLs: [URL],
        state: GenotypeReviewableRowCatalogRecoveryError.State = .rollbackFailed
    ) -> GenotypeReviewableRowCatalogRecoveryError {
        GenotypeReviewableRowCatalogRecoveryError(
            state: state,
            primaryErrorDescription: primary.localizedDescription,
            rollbackErrorDescription: rollback.localizedDescription,
            canonicalOutputPath: outputURL.path,
            recoveryPaths: recoveryURLs.map(\.path)
        )
    }

    private func existingRecoveryURLs(
        namesAndURLs: [(String, URL)],
        in directoryDescriptor: Int32
    ) -> [URL] {
        namesAndURLs.compactMap { name, url in
            var info = stat()
            let status = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &info,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            return status == 0 ? url : nil
        }
    }

    private func openOrCreateDirectory(
        named name: String,
        in parentDescriptor: Int32,
        displayedAt parentURL: URL
    ) throws -> Int32 {
        let createStatus = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        if createStatus != 0, errno != EEXIST {
            throw posixError()
        }
        if createStatus == 0, Darwin.fsync(parentDescriptor) != 0 {
            throw posixError()
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw GenotypeReviewableRowCatalogPublisherError.outputOutsideBundle(
                parentURL.appendingPathComponent(name).path
            )
        }
        return descriptor
    }

    private func regularFileIdentityIfPresent(
        named name: String,
        in directoryDescriptor: Int32,
        displayedAt url: URL
    ) throws -> FileSystemObjectIdentity? {
        var info = stat()
        let status = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0, errno == ENOENT { return nil }
        guard status == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw GenotypeReviewableRowCatalogPublisherError.outputOutsideBundle(
                url.path
            )
        }
        return FileSystemObjectIdentity(from: info)
    }

    private func descriptorSnapshot(
        named name: String,
        expectedIdentity: FileSystemObjectIdentity,
        in directoryDescriptor: Int32,
        displayedAt url: URL
    ) throws -> CatalogPayloadAttestation {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              FileSystemObjectIdentity(from: before) == expectedIdentity else {
            throw GenotypeReviewableRowCatalogPublisherError
                .finalArtifactMismatch(url.path)
        }
        let data = try readAll(from: descriptor)
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              FileSystemObjectIdentity(from: after) == expectedIdentity,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw GenotypeReviewableRowCatalogPublisherError
                .finalArtifactMismatch(url.path)
        }
        return CatalogPayloadAttestation(
            sha256: SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined(),
            fileSize: UInt64(data.count),
            identity: FileSystemObjectIdentity(from: after),
            modificationSeconds: Int64(after.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            changeSeconds: Int64(after.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(after.st_ctimespec.tv_nsec)
        )
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        displayedAt url: URL
    ) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, cursor, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                cursor = cursor.advanced(by: count)
                remaining -= count
            }
        }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { return result }
            result.append(buffer, count: count)
        }
    }

    private func posixError(defaultCode: Int32 = EIO) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno == 0 ? defaultCode : errno) ?? .EIO)
    }

    private func failureProvenance(
        inputs: GenotypeReviewableRowCatalogInputs,
        bundleDirectoryURL: URL,
        startedAt: Date,
        completedAt: Date,
        error: Error
    ) -> ProvenanceEnvelope {
        let outputURL = bundleDirectoryURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent("genotype-reviewable-rows.json")
            .standardizedFileURL
        let intendedOutput = ProvenanceFileDescriptor(
            path: outputURL.path,
            format: .json,
            role: .report
        )
        let stderr = error.localizedDescription
        let options = ProvenanceOptions(
            explicit: inputs.userVisibleOptions,
            resolvedDefaults: inputs.resolvedDefaults
        )
        let step = ProvenanceStep(
            toolName: "lungfish genotype reviewable row catalog publisher",
            toolVersion: inputs.toolVersion,
            argv: inputs.argv,
            durableReplayArgv: inputs.argv,
            reproducibleCommand: inputs.argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: inputs.userVisibleOptions.merging(inputs.resolvedDefaults) {
                explicit, _ in explicit
            },
            runtimeIdentity: inputs.runtimeIdentity,
            inputs: inputs.inputDescriptors,
            outputs: [intendedOutput],
            exitStatus: 1,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: stderr,
            startedAt: startedAt,
            completedAt: completedAt
        )
        return ProvenanceEnvelope(
            createdAt: completedAt,
            workflowName: inputs.workflowName,
            workflowVersion: inputs.workflowVersion,
            toolName: "lungfish genotype reviewable row catalog publisher",
            toolVersion: inputs.toolVersion,
            tool: ProvenanceToolIdentity(
                name: "lungfish genotype reviewable row catalog publisher",
                version: inputs.toolVersion,
                kind: "in-process"
            ),
            argv: inputs.argv,
            durableReplayArgv: inputs.argv,
            reproducibleCommand: inputs.argv.map(shellEscape).joined(separator: " "),
            options: options,
            runtimeIdentity: inputs.runtimeIdentity,
            files: inputs.inputDescriptors + [intendedOutput],
            output: intendedOutput,
            outputs: [intendedOutput],
            steps: [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 1,
            stderr: stderr
        )
    }

    private func isCanonicalNonempty(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value
    }
}
