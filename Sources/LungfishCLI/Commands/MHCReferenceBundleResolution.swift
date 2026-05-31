import ArgumentParser
import Foundation
import LungfishIO

/// Shared helpers for genotyping subcommands that accept a `.lungfishmhcref`
/// reference bundle.
///
/// The three amplicon genotyping subcommands (`genotype`, `ont-genotype`, and
/// `ont-barcode-genotype`) all take the same `--reference` argument and the same
/// reference-resolving pipeline, so the `.lungfishmhcref` consume behaviour lives
/// here once instead of being duplicated per command.
enum MHCReferenceBundleResolution {
    /// Help text for the `--reference` option, documenting all three accepted
    /// reference forms including `.lungfishmhcref` bundles.
    static let referenceHelp = "Reference FASTA file, .lungfishref bundle, or .lungfishmhcref bundle (FASTA + paired haplotype definitions) used as the mapping target"

    /// Resolves the haplotype definition for a `.lungfishmhcref` reference bundle.
    ///
    /// - Returns `nil` when the reference is not an MHC reference bundle, leaving any
    ///   explicit haplotype flags to pass through unchanged.
    /// - When no explicit id is supplied, returns the bundle's default definition.
    /// - When an explicit id is supplied, returns that definition from the bundle, so a
    ///   non-default selection from a multi-definition bundle is honoured.
    /// - Throws a `ValidationError` naming the requested id and the available ids when the
    ///   explicit id is not paired with the bundle.
    static func resolveBundleHaplotypeDefinition(
        referenceURL: URL,
        explicitID: String?
    ) throws -> GenotypeHaplotypeDefinitionSet? {
        let standardizedURL = referenceURL.standardizedFileURL
        guard MHCAmpliconReferenceBundle.isBundleURL(standardizedURL) else {
            return nil
        }
        guard let explicitID else {
            return try MHCAmpliconReferenceBundle.defaultHaplotypeDefinition(in: standardizedURL)
        }
        let definitions = try MHCAmpliconReferenceBundle.haplotypeDefinitions(in: standardizedURL)
        guard let match = definitions.first(where: { $0.id == explicitID }) else {
            let bundleName = standardizedURL.deletingPathExtension().lastPathComponent
            let available = definitions.map(\.id).joined(separator: ", ")
            throw ValidationError(
                "Haplotype definition '\(explicitID)' is not in reference bundle '\(bundleName)'. Available: \(available)."
            )
        }
        return match
    }
}
