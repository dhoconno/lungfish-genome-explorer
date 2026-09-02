import Foundation

/// Which NCBI database an accession belongs to.
///
/// `fetch genome` resolves through the assembly database. A GenBank nucleotide
/// accession has no assembly record of its own, so that search silently lands
/// on the linked RefSeq assembly and returns a differently named sequence:
/// MN908947.3 comes back as NC_045512.2. The two are the same genome but carry
/// different FASTA headers, which breaks anything matching on sequence name.
/// Classifying the accession first keeps each kind on the database that holds
/// it.
public enum NCBIAccessionKind: Equatable, Sendable {
    /// An assembly accession: GCF_/GCA_ prefixed.
    case assembly
    /// A nucleotide accession, held in nuccore.
    case nucleotide

    /// Classifies `accession` by its prefix.
    ///
    /// Assembly accessions are the only ones with a reserved prefix, so
    /// everything else is treated as a nucleotide accession.
    public static func classify(_ accession: String) -> NCBIAccessionKind {
        let trimmed = accession.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.hasPrefix("GCF_") || trimmed.hasPrefix("GCA_") ? .assembly : .nucleotide
    }
}
