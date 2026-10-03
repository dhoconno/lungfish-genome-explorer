import Foundation
import Darwin
import LungfishCore
import LungfishIO

public enum ONTBarcodeDemuxGenotypingError: Error, LocalizedError, Sendable, Equatable {
    case missingInput(URL)
    case missingBarcodeDefinitions(URL)
    case missingBarcodeDefinitionsForONT
    case missingDemuxManifest(URL)
    case invalidReference(URL)
    case noFASTQSources(URL)
    case noInputFASTQs
    case unsupportedIlluminaInput(URL)
    case duplicateIlluminaSampleID(String)
    case duplicateIlluminaStagedFile(String)
    case ambiguousGenotypingMode
    case processTimedOut(tool: String, seconds: TimeInterval, stderr: String)
    case processFailed(tool: String, status: Int32, stderr: String)
    case filterFailed(status: Int32, stderr: String)
    case invalidFilterOutput(String)
    case invalidHaplotypeDefinition(String)
    case outputDirectoryOutsideProject(outputDirectory: URL, projectURL: URL)
    case ambiguousHaplotypeDefinition(definitionID: String)
    case invalidHaplotypeDefinitionForAssay(definitionID: String, assayID: String)
    case lockedReferenceDigestMismatch(expected: String, actual: String)
    case reportFailed(status: Int32, stderr: String)
    case invalidReportOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingInput(let url):
            return "Input FASTQ bundle or file does not exist: \(url.path)"
        case .missingBarcodeDefinitions(let url):
            return "Barcode definitions file does not exist: \(url.path)"
        case .missingBarcodeDefinitionsForONT:
            return "ONT barcode-demux genotyping requires a barcode definition CSV/TSV file."
        case .missingDemuxManifest(let url):
            return "Demultiplex manifest does not exist: \(url.path)"
        case .invalidReference(let url):
            return "Reference source does not contain a readable FASTA payload: \(url.path)"
        case .noFASTQSources(let url):
            return "No constituent FASTQ files could be resolved from: \(url.path)"
        case .noInputFASTQs:
            return "No input FASTQ files could be resolved for genotyping."
        case .unsupportedIlluminaInput(let url):
            return "Illumina genotyping requires each input to be an already merged single-FASTQ sample bundle. Import paired R1/R2 reads with the Illumina Amplicon Merge recipe first: \(url.path)"
        case .duplicateIlluminaSampleID(let sampleID):
            return "Two Illumina input bundles resolved to the same sample identifier \(sampleID); rename the inputs so their sanitized names are distinct."
        case .duplicateIlluminaStagedFile(let filename):
            return "Two Illumina input bundles resolved to the same staged FASTQ filename \(filename); rename the inputs so their sanitized names are distinct."
        case .ambiguousGenotypingMode:
            return "Could not infer genotyping mode. Choose ONT barcode demux or Illumina sample bundles explicitly."
        case .processTimedOut(let tool, let seconds, let stderr):
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "\(tool) timed out after \(Int(seconds)) seconds\(detail)"
        case .processFailed(let tool, let status, let stderr):
            return "\(tool) failed with status \(status): \(stderr)"
        case .filterFailed(let status, let stderr):
            return "Retained-read demultiplex filter failed with status \(status): \(stderr)"
        case .invalidFilterOutput(let text):
            return "Retained-read demultiplex filter did not return valid JSON: \(text)"
        case .invalidHaplotypeDefinition(let id):
            return "Unknown haplotype definition set: \(id)"
        case .outputDirectoryOutsideProject(let outputDirectory, let projectURL):
            return "Output directory \(outputDirectory.path) is outside project \(projectURL.path). "
                + "The run's work directory and operation history are bound to the project, so choose "
                + "an --output-dir inside the project or omit --project to bind the run to the output directory's parent."
        case .ambiguousHaplotypeDefinition(let definitionID):
            return "Haplotype definition set \(definitionID) exists in more than one assay; specify --haplotype-assay."
        case .invalidHaplotypeDefinitionForAssay(let definitionID, let assayID):
            return "Haplotype definition set \(definitionID) is not available for assay \(assayID)"
        case .lockedReferenceDigestMismatch(let expected, let actual):
            return "Locked preset reference digest mismatch: expected \(expected), observed \(actual)."
        case .reportFailed(let status, let stderr):
            return "ONT barcode genotype workbook report failed with status \(status): \(stderr)"
        case .invalidReportOutput(let text):
            return "ONT barcode genotype workbook report did not return valid JSON: \(text)"
        }
    }
}
