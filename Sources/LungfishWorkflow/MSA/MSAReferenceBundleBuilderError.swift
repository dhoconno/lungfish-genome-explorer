import Foundation
import LungfishCore
import LungfishIO

public enum MSAReferenceBundleBuilderError: Error, LocalizedError, Equatable {
    case emptySelection
    case outputExists(URL)
    case unsupportedResidue(sequence: String, residue: Character)
    case missingCoordinate(sequence: String, alignmentColumn: Int)

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "MSA reference extraction produced no ungapped nucleotide sequences."
        case .outputExists(let url):
            return "Output bundle already exists: \(url.path)"
        case .unsupportedResidue(let sequence, let residue):
            return "MSA reference extraction only supports nucleotide sequences; \(sequence) contains unsupported residue '\(residue)'."
        case .missingCoordinate(let sequence, let alignmentColumn):
            return "MSA coordinate map for \(sequence) does not map alignment column \(alignmentColumn + 1) to an ungapped source coordinate."
        }
    }
}
