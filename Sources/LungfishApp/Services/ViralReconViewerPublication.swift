import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Registers the outputs of a finished Viral Recon run into the reference
/// bundle the viewport binds to.
///
/// The viewport never opens a loose BAM. It reads the `.lungfishref` manifest,
/// so an alignment that is not registered there is invisible however healthy the
/// file is. This is the step Viral Recon was missing: the pipeline wrote a
/// perfectly good sorted BAM and VCF, and nothing ever told the bundle about
/// them.
///
/// Registration reuses the same services the minimap2 path uses rather than
/// introducing a second publication route: `BAMImportService` for the alignment
/// and `VariantSQLiteImportCoordinator` for the variant database.
enum ViralReconViewerPublication {
    /// Publishes the ingested run into its reference bundle.
    ///
    /// Each output is registered independently. A run that produced variants but
    /// no alignment still publishes its variants, because a partial view is more
    /// useful than none and the pipeline is entitled to skip steps.
    ///
    /// - Returns: the reference bundle URL whose manifest now carries the tracks.
    @discardableResult
    static func publish(
        ingested: ViralReconResultIngest.Ingested,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let bundleURL = ingested.referenceBundleURL
        let inventory = ingested.inventory

        if let bam = inventory.sortedBAM, fileManager.fileExists(atPath: bam.path) {
            _ = try await BAMImportService.importBAM(
                bamURL: bam,
                bundleURL: bundleURL,
                name: "Viral Recon Alignment")
        }

        if let vcf = inventory.variantVCF, fileManager.fileExists(atPath: vcf.path) {
            try await registerVariants(vcfURL: vcf, bundleURL: bundleURL,
                                       sampleName: inventory.sampleName, fileManager: fileManager)
        }

        return bundleURL
    }

    /// Imports the iVar VCF into the bundle and records it in the manifest.
    ///
    /// The payload is copied in alongside its database so the bundle stays
    /// self-contained: a manifest that points outside itself breaks as soon as
    /// the raw results directory is moved.
    private static func registerVariants(
        vcfURL: URL,
        bundleURL: URL,
        sampleName: String,
        fileManager: FileManager
    ) async throws {
        let trackID = "viralrecon_ivar_\(UUID().uuidString.prefix(8))"
        let variantsDirectory = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try fileManager.createDirectory(at: variantsDirectory, withIntermediateDirectories: true)

        let payloadRelativePath = "variants/\(trackID).vcf.gz"
        let payloadURL = bundleURL.appendingPathComponent(payloadRelativePath)
        try fileManager.copyItem(at: vcfURL, to: payloadURL)

        // The tabix index travels with the payload when the pipeline wrote one.
        var indexRelativePath = ""
        let sourceIndex = vcfURL.appendingPathExtension("tbi")
        if fileManager.fileExists(atPath: sourceIndex.path) {
            indexRelativePath = payloadRelativePath + ".tbi"
            try fileManager.copyItem(
                at: sourceIndex,
                to: bundleURL.appendingPathComponent(indexRelativePath))
        }

        let databaseRelativePath = "variants/\(trackID).db"
        let importResult = try await VariantSQLiteImportCoordinator().importNormalizedVCF(
            request: VariantSQLiteImportRequest(
                normalizedVCFURL: payloadURL,
                outputDatabaseURL: bundleURL.appendingPathComponent(databaseRelativePath),
                sourceFile: vcfURL.lastPathComponent))

        // The VCF names its sequence with the pipeline's accession. The bundle
        // may spell the same sequence differently, and a mismatch silently hides
        // every variant, so the database is aligned to the bundle's names.
        let manifest = try BundleManifest.load(from: bundleURL)
        if let chromosomes = manifest.genome?.chromosomes, !chromosomes.isEmpty {
            let database = try VariantDatabase(url: importResult.databaseURL, readWrite: true)
            let mapping = chromosomeMapping(from: database.allChromosomes(), to: chromosomes)
            if !mapping.isEmpty {
                try database.renameChromosomes(mapping)
            }
        }

        let trackInfo = VariantTrackInfo(
            id: trackID,
            name: "\(sampleName) Variants",
            description: "iVar variants from Viral Recon",
            path: payloadRelativePath,
            indexPath: indexRelativePath,
            databasePath: databaseRelativePath,
            variantType: .mixed,
            variantCount: importResult.variantCount,
            source: "Viral Recon")

        try manifest.addingVariantTrack(trackInfo).save(to: bundleURL)
    }

    /// Matches VCF sequence names onto bundle sequence names.
    ///
    /// Only unambiguous matches are remapped. Renaming on a guess would move
    /// variants onto the wrong sequence, which is worse than showing none.
    private static func chromosomeMapping(
        from vcfChromosomes: [String],
        to bundleChromosomes: [ChromosomeInfo]
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        for vcfName in vcfChromosomes {
            if bundleChromosomes.contains(where: { $0.name == vcfName }) { continue }
            let candidates = bundleChromosomes.filter { bundle in
                bundle.aliases.contains(vcfName)
                    || bundle.name.hasPrefix(vcfName)
                    || vcfName.hasPrefix(bundle.name)
            }
            if candidates.count == 1 {
                mapping[vcfName] = candidates[0].name
            }
        }
        return mapping
    }
}
