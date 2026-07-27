import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct GenotypeCurrentWorkbookInputFingerprint: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    private static let maximumProvenanceBytes = 16 * 1024 * 1024

    public let schemaVersion: Int
    public let sha256: String
    public let reviewableRowCatalogPath: String?
    public let reviewableRowCatalogSize: UInt64?
    public let reviewableRowCatalogSHA256: String?
    public let reviewableRowCatalogSchemaVersion: Int?

    private struct CanonicalInput: Encodable {
        let schemaVersion: Int
        let calls: [CanonicalCall]
        let includedLoci: [String]
        let annotationSidecar: GenotypeAnnotationSidecar?
        let candidateArtifacts: CanonicalCandidateArtifacts?
        let reviewableRowCatalog: CanonicalReviewableRowCatalog?
    }

    private struct CanonicalCall: Encodable {
        let sample: String
        let locus: String
        let haplotype1: String
        let haplotype2: String
        let status: String
        let notes: String

        var sortFields: [String] {
            [sample, locus, haplotype1, haplotype2, status, notes]
        }
    }

    private struct CanonicalCallKey: Hashable {
        let sample: String
        let locus: String
    }

    private struct CanonicalCandidateArtifacts: Encodable {
        let schemaVersion: Int
        let artifacts: [CanonicalArtifact]
    }

    private struct CanonicalArtifact: Encodable {
        let role: String
        let path: String
        let sha256: String
        let sizeBytes: Int64
    }

    private struct CanonicalReviewableRowCatalog: Encodable {
        let path: String
        let size: UInt64
        let sha256: String
        let schemaVersion: Int
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sha256
        case reviewableRowCatalogPath
        case reviewableRowCatalogSize
        case reviewableRowCatalogSHA256
        case reviewableRowCatalogSchemaVersion
    }

    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case unsupportedSchemaVersion(Int)
        case invalidSHA256(String)
        case invalidReviewableRowCatalogDescriptor

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "Unsupported current workbook input fingerprint schema version: \(version)."
            case .invalidSHA256:
                return "Current workbook input fingerprint must be a lowercase 64-character SHA-256 digest."
            case .invalidReviewableRowCatalogDescriptor:
                return "Current workbook input fingerprint reviewable-row catalog descriptor is incomplete or invalid."
            }
        }
    }

    public init(
        schemaVersion: Int,
        sha256: String,
        reviewableRowCatalogPath: String? = nil,
        reviewableRowCatalogSize: UInt64? = nil,
        reviewableRowCatalogSHA256: String? = nil,
        reviewableRowCatalogSchemaVersion: Int? = nil
    ) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard Self.isValidSHA256(sha256) else {
            throw ValidationError.invalidSHA256(sha256)
        }
        try Self.validateReviewableRowCatalogDescriptor(
            path: reviewableRowCatalogPath,
            size: reviewableRowCatalogSize,
            sha256: reviewableRowCatalogSHA256,
            schemaVersion: reviewableRowCatalogSchemaVersion
        )
        self.schemaVersion = schemaVersion
        self.sha256 = sha256
        self.reviewableRowCatalogPath = reviewableRowCatalogPath
        self.reviewableRowCatalogSize = reviewableRowCatalogSize
        self.reviewableRowCatalogSHA256 = reviewableRowCatalogSHA256
        self.reviewableRowCatalogSchemaVersion = reviewableRowCatalogSchemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let sha256 = try container.decode(String.self, forKey: .sha256)
        let reviewableRowCatalogPath = try container.decodeIfPresent(
            String.self,
            forKey: .reviewableRowCatalogPath
        )
        let reviewableRowCatalogSize = try container.decodeIfPresent(
            UInt64.self,
            forKey: .reviewableRowCatalogSize
        )
        let reviewableRowCatalogSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .reviewableRowCatalogSHA256
        )
        let reviewableRowCatalogSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .reviewableRowCatalogSchemaVersion
        )
        try self.init(
            schemaVersion: schemaVersion,
            sha256: sha256,
            reviewableRowCatalogPath: reviewableRowCatalogPath,
            reviewableRowCatalogSize: reviewableRowCatalogSize,
            reviewableRowCatalogSHA256: reviewableRowCatalogSHA256,
            reviewableRowCatalogSchemaVersion: reviewableRowCatalogSchemaVersion
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sha256, forKey: .sha256)
        try container.encodeIfPresent(
            reviewableRowCatalogPath,
            forKey: .reviewableRowCatalogPath
        )
        try container.encodeIfPresent(
            reviewableRowCatalogSize,
            forKey: .reviewableRowCatalogSize
        )
        try container.encodeIfPresent(
            reviewableRowCatalogSHA256,
            forKey: .reviewableRowCatalogSHA256
        )
        try container.encodeIfPresent(
            reviewableRowCatalogSchemaVersion,
            forKey: .reviewableRowCatalogSchemaVersion
        )
    }

    public static func make(
        calls: [GenotypeWorkbookHaplotypeCall],
        includedLoci: [String],
        annotationSidecar: GenotypeAnnotationSidecar?,
        candidateArtifacts: ONTMHCCandidateArtifactManifest?,
        reviewableRowCatalog: ONTMHCArtifactReference? = nil,
        reviewableRowCatalogSchemaVersion: Int? = nil
    ) throws -> Self {
        let canonicalReviewableRowCatalog: CanonicalReviewableRowCatalog?
        if let reviewableRowCatalog {
            guard let size = UInt64(exactly: reviewableRowCatalog.sizeBytes),
                  let reviewableRowCatalogSchemaVersion else {
                throw ValidationError.invalidReviewableRowCatalogDescriptor
            }
            canonicalReviewableRowCatalog = CanonicalReviewableRowCatalog(
                path: reviewableRowCatalog.path,
                size: size,
                sha256: reviewableRowCatalog.sha256,
                schemaVersion: reviewableRowCatalogSchemaVersion
            )
        } else {
            guard reviewableRowCatalogSchemaVersion == nil else {
                throw ValidationError.invalidReviewableRowCatalogDescriptor
            }
            canonicalReviewableRowCatalog = nil
        }
        try validateReviewableRowCatalogDescriptor(
            path: canonicalReviewableRowCatalog?.path,
            size: canonicalReviewableRowCatalog?.size,
            sha256: canonicalReviewableRowCatalog?.sha256,
            schemaVersion: canonicalReviewableRowCatalog?.schemaVersion
        )
        var callsByKey: [CanonicalCallKey: CanonicalCall] = [:]
        for call in calls {
            let sample = clean(call.sample)
            let locus = GenotypeWorkbookHaplotypeCall.canonicalCurrentWorkbookLocus(call.locus)
            guard !sample.isEmpty,
                  !locus.isEmpty,
                  GenotypeWorkbookHaplotypeCall.isWritableCurrentWorkbookLocus(locus) else {
                continue
            }
            callsByKey[CanonicalCallKey(sample: sample, locus: locus)] = CanonicalCall(
                sample: sample,
                locus: locus,
                haplotype1: clean(call.haplotype1),
                haplotype2: clean(call.haplotype2),
                status: clean(call.status),
                notes: clean(call.notes)
            )
        }
        let canonicalCalls = callsByKey.values.sorted {
            $0.sortFields.lexicographicallyPrecedes($1.sortFields)
        }
        let canonicalIncludedLoci = includedLoci.map {
            GenotypeWorkbookHaplotypeCall.canonicalCurrentWorkbookLocus($0)
        }
        let input = CanonicalInput(
            schemaVersion: schemaVersion,
            calls: canonicalCalls,
            includedLoci: Array(Set(canonicalIncludedLoci)).sorted(),
            annotationSidecar: annotationSidecar,
            candidateArtifacts: candidateArtifacts.map(canonicalCandidateArtifacts),
            reviewableRowCatalog: canonicalReviewableRowCatalog
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(input))
        return try Self(
            schemaVersion: schemaVersion,
            sha256: digest.map { String(format: "%02x", $0) }.joined(),
            reviewableRowCatalogPath: canonicalReviewableRowCatalog?.path,
            reviewableRowCatalogSize: canonicalReviewableRowCatalog?.size,
            reviewableRowCatalogSHA256: canonicalReviewableRowCatalog?.sha256,
            reviewableRowCatalogSchemaVersion:
                canonicalReviewableRowCatalog?.schemaVersion
        )
    }

    public static func recorded(
        in manifest: ONTGenotypeResultBundleManifest,
        bundleURL: URL
    ) throws -> Self? {
        guard let currentWorkbookPath = manifest.currentWorkbookPath,
              let revision = manifest.workbookRevisions?.reversed().first(where: {
                  $0.path == currentWorkbookPath
              }),
              let provenancePath = revision.provenancePath,
              let provenanceComponents = safeRelativePathComponents(provenancePath),
              let data = boundedRegularFileData(
                  at: provenanceComponents,
                  in: bundleURL
              ),
              let envelope = try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data),
              let digest = envelope.options.explicit["currentWorkbookInputFingerprint"]?.stringValue,
              let recordedSchemaVersion = envelope.options.explicit[
                  "currentWorkbookInputFingerprintSchemaVersion"
              ]?.integerValue,
              recordedSchemaVersion == schemaVersion,
              isValidSHA256(digest) else {
            return nil
        }
        let path = envelope.options.explicit["reviewableRowCatalogPath"]?.stringValue
        let sizeValue = envelope.options.explicit["reviewableRowCatalogSize"]?.integerValue
        let catalogSHA256 =
            envelope.options.explicit["reviewableRowCatalogSHA256"]?.stringValue
        let catalogSchemaVersion =
            envelope.options.explicit["reviewableRowCatalogSchemaVersion"]?.integerValue
        let descriptorFieldCount = [
            path != nil,
            sizeValue != nil,
            catalogSHA256 != nil,
            catalogSchemaVersion != nil,
        ].filter { $0 }.count
        guard descriptorFieldCount == 0 || descriptorFieldCount == 4 else {
            return nil
        }
        let size = sizeValue.flatMap(UInt64.init(exactly:))
        if sizeValue != nil, size == nil {
            return nil
        }
        return try? Self(
            schemaVersion: recordedSchemaVersion,
            sha256: digest,
            reviewableRowCatalogPath: path,
            reviewableRowCatalogSize: size,
            reviewableRowCatalogSHA256: catalogSHA256,
            reviewableRowCatalogSchemaVersion: catalogSchemaVersion
        )
    }

    private static func validateReviewableRowCatalogDescriptor(
        path: String?,
        size: UInt64?,
        sha256: String?,
        schemaVersion: Int?
    ) throws {
        let fieldCount = [
            path != nil,
            size != nil,
            sha256 != nil,
            schemaVersion != nil,
        ].filter { $0 }.count
        guard fieldCount == 0 || fieldCount == 4 else {
            throw ValidationError.invalidReviewableRowCatalogDescriptor
        }
        guard fieldCount != 0 else { return }
        guard let path,
              let sha256,
              let schemaVersion,
              size != nil,
              safeRelativePathComponents(path) != nil,
              isValidSHA256(sha256),
              schemaVersion > 0 else {
            throw ValidationError.invalidReviewableRowCatalogDescriptor
        }
    }

    private static func canonicalCandidateArtifacts(
        _ manifest: ONTMHCCandidateArtifactManifest
    ) -> CanonicalCandidateArtifacts {
        var references: [(role: String, reference: ONTMHCArtifactReference)] = []
        if let pair = manifest.genotypingEvidence {
            references.append(("genotypingEvidence.bam", pair.bam))
            references.append(("genotypingEvidence.bai", pair.bai))
        }
        if let pair = manifest.reciprocalEvidence {
            references.append(("reciprocalEvidence.bam", pair.bam))
            references.append(("reciprocalEvidence.bai", pair.bai))
        }
        let optionalReferences: [(String, ONTMHCArtifactReference?)] = [
            ("candidateJSON", manifest.candidateJSON),
            ("candidateFASTA", manifest.candidateFASTA),
            ("candidateGenBank", manifest.candidateGenBank),
            ("unnameableJSON", manifest.unnameableJSON),
            ("unnameableFASTA", manifest.unnameableFASTA),
            ("unnameableGenBank", manifest.unnameableGenBank),
            ("rawUnmatchedFASTA", manifest.rawUnmatchedFASTA),
            ("sourceIdentityMap", manifest.sourceIdentityMap),
        ]
        for (role, reference) in optionalReferences {
            if let reference {
                references.append((role, reference))
            }
        }
        let artifacts = references.map {
            CanonicalArtifact(
                role: $0.role,
                path: $0.reference.path,
                sha256: $0.reference.sha256,
                sizeBytes: $0.reference.sizeBytes
            )
        }.sorted {
            if $0.path != $1.path {
                return $0.path < $1.path
            }
            if $0.role != $1.role {
                return $0.role < $1.role
            }
            if $0.sha256 != $1.sha256 {
                return $0.sha256 < $1.sha256
            }
            return $0.sizeBytes < $1.sizeBytes
        }
        return CanonicalCandidateArtifacts(
            schemaVersion: manifest.schemaVersion,
            artifacts: artifacts
        )
    }

    private static func safeRelativePathComponents(_ path: String) -> [String]? {
        guard path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.utf8.contains(0) else {
            return nil
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }

    private static func boundedRegularFileData(
        at components: [String],
        in bundleURL: URL
    ) -> Data? {
        var directoryDescriptor = Darwin.open(
            bundleURL.standardizedFileURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard directoryDescriptor >= 0 else { return nil }
        defer { Darwin.close(directoryDescriptor) }

        var directoryInformation = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryInformation) == 0,
              directoryInformation.st_mode & S_IFMT == S_IFDIR else {
            return nil
        }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard nextDescriptor >= 0 else { return nil }
            var information = stat()
            guard Darwin.fstat(nextDescriptor, &information) == 0,
                  information.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(nextDescriptor)
                return nil
            }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        guard let finalComponent = components.last else { return nil }
        let descriptor = finalComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= maximumProvenanceBytes else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(Int(information.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard data.count <= maximumProvenanceBytes - count else {
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
