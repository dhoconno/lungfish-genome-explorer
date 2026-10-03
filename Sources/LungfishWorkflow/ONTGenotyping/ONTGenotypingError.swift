import Foundation
import LungfishCore
import LungfishIO

public enum ONTGenotypingError: Error, LocalizedError, Sendable, Equatable {
    case noInputs
    case missingInput(URL)
    case invalidReference(URL)
    case mappingFailed(String)
    case filteringFailed(sampleName: String, status: Int32, stderr: String)
    case reportWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "ONT genotyping requires at least one FASTQ input bundle or file."
        case .missingInput(let url):
            return "Input FASTQ does not exist: \(url.path)"
        case .invalidReference(let url):
            return "Reference source does not contain a readable FASTA payload: \(url.path)"
        case .mappingFailed(let message):
            return "ONT genotyping mapping failed: \(message)"
        case .filteringFailed(let sampleName, let status, let stderr):
            return "ONT genotyping filter failed for \(sampleName) with status \(status): \(stderr)"
        case .reportWriteFailed(let message):
            return "Failed to write ONT genotyping report: \(message)"
        }
    }
}
