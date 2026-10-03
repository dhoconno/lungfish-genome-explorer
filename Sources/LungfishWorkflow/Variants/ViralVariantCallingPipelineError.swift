import Foundation
import LungfishCore
import LungfishIO
import os.log

public enum ViralVariantCallingPipelineError: Error, LocalizedError, Equatable {
    case medakaRequiresModelMetadata
    case workspaceSetupFailed(String)
    case referenceStagingFailed(String)
    case alignmentStagingFailed(String)
    case fastqReconstructionFailed(String)
    case callerExecutionFailed(String)
    case missingCallerOutput(String)
    case normalizationFailed(String)
    case compressionFailed(String)
    case indexingFailed(String)
    case reservedAdvancedArgument(String)
    case platformUnknown(String)
    case clair3ModelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .medakaRequiresModelMetadata:
            return "Medaka requires ONT model metadata before the run can start."
        case .platformUnknown(let message):
            return message
        case .clair3ModelUnavailable(let message):
            return message
        case .workspaceSetupFailed(let detail):
            return "Failed to prepare the variant-calling workspace: \(detail)"
        case .referenceStagingFailed(let detail):
            return "Failed to stage the reference FASTA: \(detail)"
        case .alignmentStagingFailed(let detail):
            return "Failed to stage the alignment inputs: \(detail)"
        case .fastqReconstructionFailed(let detail):
            return "Failed to reconstruct FASTQ input for Medaka: \(detail)"
        case .callerExecutionFailed(let detail):
            return "Variant caller execution failed: \(detail)"
        case .missingCallerOutput(let path):
            return "Variant caller did not produce the expected VCF output: \(path)"
        case .normalizationFailed(let detail):
            return "Failed to normalize the caller VCF output: \(detail)"
        case .compressionFailed(let detail):
            return "Failed to bgzip-compress the normalized VCF: \(detail)"
        case .indexingFailed(let detail):
            return "Failed to create the tabix index: \(detail)"
        case .reservedAdvancedArgument(let message):
            return message
        }
    }
}
