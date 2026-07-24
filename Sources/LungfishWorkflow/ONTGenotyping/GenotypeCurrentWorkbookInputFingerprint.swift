import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct GenotypeCurrentWorkbookInputFingerprint: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    private static let maximumProvenanceBytes = 16 * 1024 * 1024

    public let schemaVersion: Int
    public let sha256: String

    private struct CanonicalInput: Encodable {
        let schemaVersion: Int
        let calls: [CanonicalCall]
        let includedLoci: [String]
        let annotationSidecar: GenotypeAnnotationSidecar?
        let candidateArtifacts: CanonicalCandidateArtifacts?
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sha256
    }

    private enum ValidationError: Error {
        case unsupportedSchemaVersion
        case invalidSHA256
    }

    private init(sha256: String) {
        schemaVersion = Self.schemaVersion
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let sha256 = try container.decode(String.self, forKey: .sha256)
        guard schemaVersion == Self.schemaVersion else {
            throw ValidationError.unsupportedSchemaVersion
        }
        guard Self.isValidSHA256(sha256) else {
            throw ValidationError.invalidSHA256
        }
        self.schemaVersion = schemaVersion
        self.sha256 = sha256
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sha256, forKey: .sha256)
    }

    public static func make(
        calls: [GenotypeWorkbookHaplotypeCall],
        includedLoci: [String],
        annotationSidecar: GenotypeAnnotationSidecar?,
        candidateArtifacts: ONTMHCCandidateArtifactManifest?
    ) throws -> Self {
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
            candidateArtifacts: candidateArtifacts.map(canonicalCandidateArtifacts)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(input))
        return Self(sha256: digest.map { String(format: "%02x", $0) }.joined())
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
              let provenanceURL = safeURL(for: provenancePath, in: bundleURL),
              let data = boundedRegularFileData(at: provenanceURL),
              let envelope = try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data),
              let digest = envelope.options.explicit["currentWorkbookInputFingerprint"]?.stringValue,
              let recordedSchemaVersion = envelope.options.explicit[
                  "currentWorkbookInputFingerprintSchemaVersion"
              ]?.integerValue,
              recordedSchemaVersion == schemaVersion,
              isValidSHA256(digest) else {
            return nil
        }
        return Self(sha256: digest)
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

    private static func safeURL(for path: String, in bundleURL: URL) -> URL? {
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

        let root = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = components.reduce(root) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = resolvedCandidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents) else {
            return nil
        }
        return candidate
    }

    private static func boundedRegularFileData(at url: URL) -> Data? {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
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
