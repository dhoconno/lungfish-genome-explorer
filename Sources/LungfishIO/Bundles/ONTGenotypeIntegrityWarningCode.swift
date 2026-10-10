import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeIntegrityWarningCode: String, Codable, Equatable, Sendable {
    case candidateArtifactManifestSchemaUnsupported = "candidate-artifact-manifest-schema-unsupported"
    case candidateArtifactIncompleteDeclaration = "candidate-artifact-incomplete-declaration"
    case candidateArtifactPathInvalid = "candidate-artifact-path-invalid"
    case candidateArtifactMissing = "candidate-artifact-missing"
    case candidateArtifactNotRegularFile = "candidate-artifact-not-regular-file"
    case candidateArtifactSizeMismatch = "candidate-artifact-size-mismatch"
    case candidateArtifactChecksumMismatch = "candidate-artifact-checksum-mismatch"
    case candidateArtifactTooLarge = "candidate-artifact-too-large"
    case candidateArtifactMalformedJSON = "candidate-artifact-malformed-json"
    case candidateArtifactSchemaUnsupported = "candidate-artifact-schema-unsupported"
    case candidateArtifactDocumentReferenceMismatch = "candidate-artifact-document-reference-mismatch"
    case candidateArtifactMalformedFASTA = "candidate-artifact-malformed-fasta"
    case candidateArtifactMissingFASTARecord = "candidate-artifact-missing-fasta-record"
    case candidateArtifactDuplicateFASTARecord = "candidate-artifact-duplicate-fasta-record"
    case candidateArtifactExtraFASTARecord = "candidate-artifact-extra-fasta-record"
    case candidateArtifactSequenceChecksumMismatch = "candidate-artifact-sequence-checksum-mismatch"
    /// Duplicate long-summary rows for one animal, locus and allele were
    /// collapsed to one occurrence when the result was built (D5b).
    case duplicateCallRowsCollapsed = "duplicate-call-rows-collapsed"
    /// Full-length calls whose reference record names no allele or gene keep
    /// the locus their sequence name gives (N9).
    case referenceLocusUnresolved = "reference-locus-unresolved"
    /// Reference records whose allele prefix and gene name different loci.
    /// The calls take the allele's locus (N9).
    case referenceLocusConflict = "reference-locus-conflict"
}
