import Foundation
import LungfishIO

public enum FullLengthONTPBAAArtifactDecision: Equatable, Sendable {
    case reuse(FASTQPBAAStoredArtifact)
    case runAndSave
    case runWithoutSaving
}

public enum FullLengthONTPBAAArtifactPlanner {
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case missingCompatibleArtifact(String)

        public var errorDescription: String? {
            switch self {
            case .missingCompatibleArtifact(let path):
                return "No compatible saved pbAA artifact exists for \(path). Use a compatible artifact, choose Use Compatible, or rerun pbAA."
            }
        }
    }

    public static func signature(
        inputURL: URL,
        preparedFASTQURL: URL,
        guideFASTAURL: URL,
        request: FullLengthONTMHCGenotypingRunRequest,
        pbaaRequest: PBAAClusteringRunRequest
    ) throws -> FASTQPBAAArtifactSignature {
        try FASTQPBAAArtifactSignature(
            sourceFASTQ: .fingerprint(
                url: inputURL,
                displayPath: inputURL.standardizedFileURL.path
            ),
            preparedReads: .fingerprint(
                url: preparedFASTQURL,
                displayPath: preparedFASTQURL.standardizedFileURL.path
            ),
            guide: .fingerprint(
                url: guideFASTAURL,
                displayPath: guideFASTAURL.standardizedFileURL.path
            ),
            preprocessing: FASTQPBAAPreprocessingSignature(
                orientReference: try request.orientReferenceURL.map {
                    try .fingerprint(url: $0, displayPath: $0.standardizedFileURL.path)
                },
                forwardPrimer: try request.forwardPrimerURL.map {
                    try .fingerprint(url: $0, displayPath: $0.standardizedFileURL.path)
                },
                reversePrimer: try request.reversePrimerURL.map {
                    try .fingerprint(url: $0, displayPath: $0.standardizedFileURL.path)
                },
                minimumLength: request.minimumLength,
                maximumLength: request.maximumLength
            ),
            clustering: FASTQPBAAClusteringSignature(
                pbaaToolVersion: pbaaRequest.containerPins.pbaa.toolVersion,
                workflowSchemaVersion: PBAAContainerPins.workflowSchemaVersion,
                seed: pbaaRequest.seed,
                extraArguments: pbaaRequest.extraArguments,
                extraArgumentsText: pbaaRequest.extraArgumentsText,
                pbaaContainerReference: pbaaRequest.containerPins.pbaa.reference,
                pbaaContainerExpectedDigest: pbaaRequest.containerPins.pbaa.expectedDigest,
                samtoolsContainerReference: pbaaRequest.containerPins.samtools.reference,
                samtoolsContainerExpectedDigest: pbaaRequest.containerPins.samtools.expectedDigest
            )
        )
    }

    public static func decision(
        inputURL: URL,
        signature: FASTQPBAAArtifactSignature,
        mode: FullLengthONTPBAAClusterSourceMode
    ) throws -> FullLengthONTPBAAArtifactDecision {
        guard FASTQBundle.isBundleURL(inputURL) else {
            if mode == .requireExisting {
                throw Error.missingCompatibleArtifact(inputURL.standardizedFileURL.path)
            }
            return .runWithoutSaving
        }
        if mode == .rerunAll {
            return .runAndSave
        }

        let compatibleArtifacts = try FASTQPBAAArtifactStore.compatibleArtifacts(
            in: inputURL,
            matching: signature
        )
        if let newest = compatibleArtifacts.first {
            return .reuse(newest)
        }
        if mode == .requireExisting {
            throw Error.missingCompatibleArtifact(inputURL.standardizedFileURL.path)
        }
        return .runAndSave
    }
}
