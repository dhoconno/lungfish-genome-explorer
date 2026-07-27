import Darwin
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
        }
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
    }

    public init(provisionalExon2 record: ONTGenotypeProvisionalExon2Record) {
        self.init(
            kind: .provisionalExon2,
            stableID: "sha256:\(record.sequenceSHA256)",
            displayName: record.genotype,
            locus: record.locus,
            supportBySample: Dictionary(
                record.sampleSupport.map { ($0.sample, $0.passedUniqueReads) },
                uniquingKeysWith: +
            )
        )
    }

    public static func fullLengthCandidates(
        from document: ONTMHCCandidateAllelesDocument
    ) -> [Self] {
        var supportByStableID: [String: [String: Int]] = [:]
        for observation in document.observations {
            supportByStableID[
                observation.stableClusterID,
                default: [:]
            ][observation.sampleID, default: 0] += observation.aggregatedSampleReadCount
        }
        return document.candidates.map { candidate in
            Self(
                kind: .candidate,
                stableID: candidate.stableClusterID,
                displayName: candidate.provisionalName,
                locus: candidate.locus,
                supportBySample: supportByStableID[candidate.stableClusterID] ?? [:]
            )
        }
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
    public enum PublicationPhase: Equatable, Sendable {
        case staged
        case published
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

    private let dateProvider: @Sendable () -> Date
    private let publicationObserver: @Sendable (PublicationPhase) throws -> Void
    private let finalArtifactDescriptorProvider:
        @Sendable (URL) throws -> (sha256: String, fileSize: UInt64)

    public init(
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        publicationObserver: @escaping @Sendable (PublicationPhase) throws -> Void = { _ in },
        finalArtifactDescriptorProvider:
            @escaping @Sendable (URL) throws -> (sha256: String, fileSize: UInt64) = {
                (
                    try ProvenanceFileHasher.sha256(of: $0),
                    try ProvenanceFileHasher.fileSize(of: $0)
                )
            }
    ) {
        self.dateProvider = dateProvider
        self.publicationObserver = publicationObserver
        self.finalArtifactDescriptorProvider = finalArtifactDescriptorProvider
    }

    public func publish(
        _ inputs: GenotypeReviewableRowCatalogInputs,
        to bundleDirectoryURL: URL
    ) throws -> GenotypeReviewableRowCatalogPublication {
        let startedAt = dateProvider()
        do {
            return try publish(
                inputs,
                to: bundleDirectoryURL,
                startedAt: startedAt
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
        startedAt: Date
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
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stagedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).staging-\(UUID().uuidString)")
        let finalDescriptor: (sha256: String, fileSize: UInt64)
        do {
            var encoded = try document.encoded()
            encoded.append(0x0a)
            try encoded.write(to: stagedURL, options: .withoutOverwriting)
            try publicationObserver(.staged)
            let stagedHash = try ProvenanceFileHasher.sha256(of: stagedURL)
            let stagedSize = try ProvenanceFileHasher.fileSize(of: stagedURL)
            finalDescriptor = try publishStagedFile(
                stagedURL,
                to: outputURL
            ) {
                try publicationObserver(.published)
                let descriptor = try finalArtifactDescriptorProvider(outputURL)
                guard descriptor.sha256 == stagedHash,
                      descriptor.fileSize == stagedSize else {
                    throw GenotypeReviewableRowCatalogPublisherError
                        .finalArtifactMismatch(outputURL.path)
                }
                return descriptor
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }

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
                            value: callSupport[sample]!
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

    private func publishStagedFile<T>(
        _ stagedURL: URL,
        to outputURL: URL,
        validate: () throws -> T
    ) throws -> T {
        let hadExistingOutput = FileManager.default.fileExists(atPath: outputURL.path)
        if hadExistingOutput {
            guard Darwin.renamex_np(
                stagedURL.path,
                outputURL.path,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            guard Darwin.renamex_np(
                stagedURL.path,
                outputURL.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        do {
            let result = try validate()
            if hadExistingOutput {
                try FileManager.default.removeItem(at: stagedURL)
            }
            return result
        } catch {
            if hadExistingOutput {
                if Darwin.renamex_np(
                    stagedURL.path,
                    outputURL.path,
                    UInt32(RENAME_SWAP)
                ) == 0 {
                    try? FileManager.default.removeItem(at: stagedURL)
                }
            } else if Darwin.renamex_np(
                outputURL.path,
                stagedURL.path,
                UInt32(RENAME_EXCL)
            ) == 0 {
                try? FileManager.default.removeItem(at: stagedURL)
            }
            throw error
        }
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
