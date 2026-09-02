import Foundation

/// The reference Viral Recon always uses.
///
/// Viral Recon is a SARS-CoV-2 tool. Every bundled primer scheme declares that
/// organism and names MN908947.3 as canonical, so a primer scheme cannot apply
/// to any other genome. The reference is therefore fixed here rather than
/// chosen by the user or matched against project bundles.
public enum ViralReconReferenceCatalog {
    /// The only accession Viral Recon runs against.
    public static let canonicalAccession = "MN908947.3"

    /// Bundle directory name for the canonical accession.
    public static var bundleFilename: String { "\(canonicalAccession).lungfishref" }

    /// Where the canonical bundle lives inside a project.
    public static func bundleURL(inProject projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(bundleFilename, isDirectory: true)
    }

    /// Accessions that are the same genome but carry a different sequence
    /// identifier. Recorded so a caller can explain why one is refused. These
    /// are never substituted for the canonical accession: the primer BED is
    /// written against MN908947.3, so an alignment against another identifier
    /// leaves the trimming step with nothing to match.
    public static let equivalentAccessions: Set<String> = ["NC_045512.2", "NC_045512"]
}
