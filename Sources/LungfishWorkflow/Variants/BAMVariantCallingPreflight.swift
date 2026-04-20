import Foundation
import LungfishCore
import LungfishIO

public enum BAMVariantCallingContigValidation: String, Sendable, Codable, Equatable {
    case exactMatch = "exact-match"
    case matchedByAlias = "matched-by-alias"
}

public struct BAMVariantCallingPreflightResult: Sendable {
    public let manifest: BundleManifest
    public let alignmentTrack: AlignmentTrackInfo
    public let genome: GenomeInfo
    public let alignmentURL: URL
    public let alignmentIndexURL: URL
    public let referenceFASTAURL: URL
    public let referenceFAIURL: URL
    public let bamReferenceSequences: [SAMParser.ReferenceSequence]
    public let referenceNameMap: [String: String]
    public let contigValidation: BAMVariantCallingContigValidation

    public init(
        manifest: BundleManifest,
        alignmentTrack: AlignmentTrackInfo,
        genome: GenomeInfo,
        alignmentURL: URL,
        alignmentIndexURL: URL,
        referenceFASTAURL: URL,
        referenceFAIURL: URL,
        bamReferenceSequences: [SAMParser.ReferenceSequence],
        referenceNameMap: [String: String],
        contigValidation: BAMVariantCallingContigValidation
    ) {
        self.manifest = manifest
        self.alignmentTrack = alignmentTrack
        self.genome = genome
        self.alignmentURL = alignmentURL
        self.alignmentIndexURL = alignmentIndexURL
        self.referenceFASTAURL = referenceFASTAURL
        self.referenceFAIURL = referenceFAIURL
        self.bamReferenceSequences = bamReferenceSequences
        self.referenceNameMap = referenceNameMap
        self.contigValidation = contigValidation
    }
}

public enum BAMVariantCallingPreflightError: Error, LocalizedError, Equatable {
    case missingAlignmentTrack(String)
    case missingBundleGenome
    case missingAlignmentFile(String)
    case missingReferenceFASTA(String)
    case missingReferenceFAI(String)
    case missingAlignmentIndex(String)
    case unresolvedReference(String)
    case referenceLengthMismatch(String, String, Int64, Int64)
    case referenceMD5Mismatch(String, String)
    case ivarRequiresPrimerTrimConfirmation
    case medakaRequiresModelMetadata
    case medakaCouldNotVerifyONTMetadata
    case bamHeaderReadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAlignmentTrack(let trackID):
            return "Alignment track was not found in the bundle manifest: \(trackID)"
        case .missingBundleGenome:
            return "Bundle does not expose a reference genome."
        case .missingAlignmentFile(let path):
            return "Alignment file is missing: \(path)"
        case .missingReferenceFASTA(let path):
            return "Reference FASTA is missing from the bundle: \(path)"
        case .missingReferenceFAI(let path):
            return "Reference FASTA index is missing from the bundle: \(path)"
        case .missingAlignmentIndex(let path):
            return "Alignment index is missing: \(path)"
        case .unresolvedReference(let name):
            return "Alignment reference '\(name)' does not match any bundle chromosome or alias."
        case .referenceLengthMismatch(let bamName, let bundleName, let expected, let observed):
            return "Alignment reference '\(bamName)' resolved to bundle chromosome '\(bundleName)' but lengths differ (\(expected) vs \(observed))."
        case .referenceMD5Mismatch(let expected, let observed):
            return "Reference checksum mismatch: bundle md5 is \(expected), BAM header M5 is \(observed)."
        case .ivarRequiresPrimerTrimConfirmation:
            return "iVar requires explicit confirmation that primer trimming has already been applied."
        case .medakaRequiresModelMetadata:
            return "Medaka requires ONT model metadata before the run can start."
        case .medakaCouldNotVerifyONTMetadata:
            return "Medaka could not verify ONT/basecaller metadata in this BAM. Use a BAM that preserves ONT model information or choose a different caller."
        case .bamHeaderReadFailed(let detail):
            return "Failed to read BAM header references: \(detail)"
        }
    }
}

public actor BAMVariantCallingPreflight {
    public typealias BAMReferenceReader = @Sendable (URL) async throws -> [SAMParser.ReferenceSequence]
    public typealias BAMHeaderReader = @Sendable (URL) async throws -> String

    private let bamReferenceReader: BAMReferenceReader
    private let bamHeaderReader: BAMHeaderReader

    public init(
        bamReferenceReader: @escaping BAMReferenceReader = BAMVariantCallingPreflight.readBAMReferenceSequences(alignmentURL:),
        bamHeaderReader: @escaping BAMHeaderReader = BAMVariantCallingPreflight.readBAMHeader(alignmentURL:)
    ) {
        self.bamReferenceReader = bamReferenceReader
        self.bamHeaderReader = bamHeaderReader
    }

    public func validate(
        _ request: BundleVariantCallingRequest
    ) async throws -> BAMVariantCallingPreflightResult {
        if request.caller == .ivar, !request.ivarPrimerTrimConfirmed {
            throw BAMVariantCallingPreflightError.ivarRequiresPrimerTrimConfirmation
        }
        if request.caller == .medaka,
           request.medakaModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw BAMVariantCallingPreflightError.medakaRequiresModelMetadata
        }

        let manifest = try BundleManifest.load(from: request.bundleURL)
        guard let alignmentTrack = manifest.alignments.first(where: { $0.id == request.alignmentTrackID }) else {
            throw BAMVariantCallingPreflightError.missingAlignmentTrack(request.alignmentTrackID)
        }
        guard let genome = manifest.genome else {
            throw BAMVariantCallingPreflightError.missingBundleGenome
        }

        let bundle = ReferenceBundle(url: request.bundleURL, manifest: manifest)
        let alignmentPath: String
        do {
            alignmentPath = try bundle.resolveAlignmentPath(alignmentTrack)
        } catch let error as ReferenceBundleError {
            switch error {
            case .missingFile:
                throw BAMVariantCallingPreflightError.missingAlignmentFile(alignmentTrack.sourcePath)
            default:
                throw error
            }
        }
        let alignmentURL = URL(fileURLWithPath: alignmentPath)
        guard FileManager.default.fileExists(atPath: alignmentURL.path) else {
            throw BAMVariantCallingPreflightError.missingAlignmentFile(alignmentURL.path)
        }
        let alignmentIndexPath: String
        do {
            alignmentIndexPath = try bundle.resolveAlignmentIndexPath(alignmentTrack)
        } catch let error as ReferenceBundleError {
            switch error {
            case .missingFile:
                throw BAMVariantCallingPreflightError.missingAlignmentIndex(alignmentTrack.indexPath)
            default:
                throw error
            }
        }
        let alignmentIndexURL = URL(fileURLWithPath: alignmentIndexPath)
        guard FileManager.default.fileExists(atPath: alignmentIndexURL.path) else {
            throw BAMVariantCallingPreflightError.missingAlignmentIndex(alignmentIndexURL.path)
        }

        let referenceFASTAURL = request.bundleURL.appendingPathComponent(genome.path)
        guard FileManager.default.fileExists(atPath: referenceFASTAURL.path) else {
            throw BAMVariantCallingPreflightError.missingReferenceFASTA(genome.path)
        }
        let referenceFAIURL = request.bundleURL.appendingPathComponent(genome.indexPath)
        guard FileManager.default.fileExists(atPath: referenceFAIURL.path) else {
            throw BAMVariantCallingPreflightError.missingReferenceFAI(genome.indexPath)
        }

        let bamReferenceSequences = try await bamReferenceReader(alignmentURL)
        let referenceNameMap = try resolveReferenceNameMap(
            bamReferenceSequences: bamReferenceSequences,
            bundleChromosomes: genome.chromosomes
        )
        let contigValidation: BAMVariantCallingContigValidation =
            referenceNameMap.contains { $0.key != $0.value } ? .matchedByAlias : .exactMatch

        try validateMD5IfAvailable(
            bamReferenceSequences: bamReferenceSequences,
            genome: genome
        )
        if request.caller == .medaka {
            let bamHeaderText = try await bamHeaderReader(alignmentURL)
            try validateMedakaHeaderIfNeeded(
                request: request,
                bamHeaderText: bamHeaderText
            )
        }

        return BAMVariantCallingPreflightResult(
            manifest: manifest,
            alignmentTrack: alignmentTrack,
            genome: genome,
            alignmentURL: alignmentURL,
            alignmentIndexURL: alignmentIndexURL,
            referenceFASTAURL: referenceFASTAURL,
            referenceFAIURL: referenceFAIURL,
            bamReferenceSequences: bamReferenceSequences,
            referenceNameMap: referenceNameMap,
            contigValidation: contigValidation
        )
    }

    private func resolveReferenceNameMap(
        bamReferenceSequences: [SAMParser.ReferenceSequence],
        bundleChromosomes: [ChromosomeInfo]
    ) throws -> [String: String] {
        let aliasMap = mapVCFChromosomes(bamReferenceSequences.map(\.name), toBundleChromosomes: bundleChromosomes)
        var resolved: [String: String] = [:]

        for sequence in bamReferenceSequences {
            let bundleName: String
            if bundleChromosomes.contains(where: { $0.name == sequence.name }) {
                bundleName = sequence.name
            } else if let mapped = aliasMap[sequence.name] {
                bundleName = mapped
            } else {
                throw BAMVariantCallingPreflightError.unresolvedReference(sequence.name)
            }

            guard let chromosome = bundleChromosomes.first(where: { $0.name == bundleName }) else {
                throw BAMVariantCallingPreflightError.unresolvedReference(sequence.name)
            }
            guard chromosome.length == sequence.length else {
                throw BAMVariantCallingPreflightError.referenceLengthMismatch(
                    sequence.name,
                    chromosome.name,
                    chromosome.length,
                    sequence.length
                )
            }
            resolved[sequence.name] = chromosome.name
        }

        return resolved
    }

    private func validateMD5IfAvailable(
        bamReferenceSequences: [SAMParser.ReferenceSequence],
        genome: GenomeInfo
    ) throws {
        guard genome.chromosomes.count == 1,
              bamReferenceSequences.count == 1,
              let expected = genome.md5Checksum?.lowercased(),
              !expected.isEmpty,
              let observed = bamReferenceSequences[0].md5?.lowercased(),
              !observed.isEmpty else {
            return
        }
        guard expected == observed else {
            throw BAMVariantCallingPreflightError.referenceMD5Mismatch(expected, observed)
        }
    }

    private func validateMedakaHeaderIfNeeded(
        request: BundleVariantCallingRequest,
        bamHeaderText: String
    ) throws {
        guard request.caller == .medaka else {
            return
        }
        guard let requestedModel = request.medakaModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedModel.isEmpty else {
            throw BAMVariantCallingPreflightError.medakaRequiresModelMetadata
        }

        let readGroups = SAMParser.parseReadGroups(from: bamHeaderText)
        let normalizedHeader = bamHeaderText.lowercased()
        let hasONTPlatform = readGroups.contains { group in
            guard let platform = group.platform?.lowercased() else { return false }
            return platform.contains("ont")
                || platform.contains("oxford")
                || platform.contains("nanopore")
        } || normalizedHeader.contains("pl:ont")

        guard hasONTPlatform else {
            throw BAMVariantCallingPreflightError.medakaCouldNotVerifyONTMetadata
        }

        let normalizedModel = requestedModel.lowercased()
        let headerFields = readGroups.flatMap { group in
            [group.description, group.platformUnit, group.center].compactMap { $0?.lowercased() }
        }
        let modelVerified = normalizedHeader.contains(normalizedModel)
            || headerFields.contains(where: { $0.contains(normalizedModel) })

        guard modelVerified else {
            throw BAMVariantCallingPreflightError.medakaCouldNotVerifyONTMetadata
        }
    }

    public static func readBAMHeader(
        alignmentURL: URL
    ) async throws -> String {
        let result = try await NativeToolRunner.shared.run(
            .samtools,
            arguments: ["view", "-H", alignmentURL.path]
        )
        guard result.isSuccess else {
            throw BAMVariantCallingPreflightError.bamHeaderReadFailed(result.stderr)
        }
        return result.stdout
    }

    public static func readBAMReferenceSequences(
        alignmentURL: URL
    ) async throws -> [SAMParser.ReferenceSequence] {
        SAMParser.parseReferenceSequences(from: try await readBAMHeader(alignmentURL: alignmentURL))
    }
}
