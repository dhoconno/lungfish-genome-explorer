// FetchGenomeNucleotideBundle.swift - The bundle lungfish-cli fetch genome builds for a nucleotide record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The bundle `fetch genome` builds for a nucleotide accession, from the record's FASTA and GFF3
/// through `NativeBundleBuilder`, as before Phase 2.10.
///
/// It stays off `GenBankDownloadBundleBuilder` on purpose. That builder names the sequence by the
/// record's LOCUS name (`MN908947`), where this one names it from the FASTA header, the accession
/// with its version (`MN908947.3`), which primer BEDs and VCFs called against the record match on.
/// Lane A44 M2 asks BIO to rule on the naming before the leaf moves (report, deviation 1).
struct FetchGenomeNucleotideBundle: Sendable {
    let request: FetchGenomeRequest
    let reporter: FetchGenomeReporter

    struct Built: Sendable {
        let bundleURL: URL
        let organism: String
        let sources: [GenomeDownloadBundleBuilder.FetchedSource]
    }

    /// Builds the bundle of `accession` in a scratch folder of `workFolder` and returns it there.
    /// The caller moves or merges it and removes `scratch`.
    func build(
        _ accession: String,
        name: String?,
        scratch: URL,
        service: NCBIService,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Built {
        reporter.info("Fetching nucleotide record \(accession)...")
        let fastaData = try await service.efetch(database: .nucleotide, ids: [accession], format: .fasta)
        guard let fasta = String(data: fastaData, encoding: .utf8), fasta.hasPrefix(">") else {
            throw CLIError.networkError(reason: "Nucleotide record not found: \(accession)")
        }
        // The header names the sequence every downstream consumer matches on, so it is read from
        // the record rather than assumed to be the query.
        let header = fasta.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let sequenceName = header.dropFirst().split(separator: " ").first.map(String.init) ?? accession
        let organism = header.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
        let fastaURL = scratch.appendingPathComponent("sequence.fna")
        try fastaData.write(to: fastaURL)
        var sources = [GenomeDownloadBundleBuilder.FetchedSource.describing(
            .fasta, from: GenBankDownloadBundleBuilder.recordURL(accession: accession, format: "fasta"), file: fastaURL)]
        try Task.checkCancellation()

        // Annotations are best-effort. Not every nucleotide record carries a GFF3, and a bundle
        // without one is still usable.
        var gffURL: URL?
        reporter.info("Downloading annotations (GFF3)...")
        if let gffData = try? await service.efetch(database: .nucleotide, ids: [accession], format: .gff3),
           let gffText = String(data: gffData, encoding: .utf8),
           gffText.contains("##gff-version") {
            let url = scratch.appendingPathComponent("annotations.gff3")
            try gffData.write(to: url)
            gffURL = url
            sources.append(.describing(.gff3, from: GenBankDownloadBundleBuilder.recordURL(accession: accession, format: "gff3"), file: url))
        } else {
            reporter.warning("Annotations not available for \(accession)")
        }
        try Task.checkCancellation()

        let stagingURL = scratch.appendingPathComponent("bundle-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let config = BuildConfiguration(
            name: name ?? sequenceName,
            identifier: "com.ncbi.\(sequenceName.lowercased().replacingOccurrences(of: ".", with: "-"))",
            fastaURL: fastaURL,
            annotationFiles: gffURL.map { [AnnotationInput(url: $0, name: "genes")] } ?? [],
            variantFiles: [],
            signalFiles: [],
            outputDirectory: stagingURL,
            source: SourceInfo(
                organism: organism.isEmpty ? sequenceName : organism,
                commonName: nil,
                taxonomyId: nil,
                // A nucleotide record has no assembly. The sequence name is the identifier that
                // matters to consumers of this bundle.
                assembly: sequenceName,
                assemblyAccession: nil,
                database: "NCBI",
                sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(sequenceName)"),
                downloadDate: Date(),
                notes: nil
            ),
            compressFASTA: true
        )
        let builder = await NativeBundleBuilder()
        let bundleURL = try await builder.build(configuration: config) { _, fraction, message in
            progress(fraction, message)
        }
        try Self.aliasBareAccession(in: bundleURL)
        return Built(bundleURL: bundleURL, organism: organism.isEmpty ? sequenceName : organism, sources: sources)
    }

    /// Lists the accession without its version as an alias of a one-sequence bundle's sequence,
    /// whose name stays the accession with its version (BIO on lane A44 M3-2, T3). A file or an
    /// older bundle that names the bare accession, as the LOCUS name of the in-process GenBank
    /// download does, then still resolves. A name with no version keeps the manifest as built.
    static func aliasBareAccession(in bundleURL: URL) throws {
        let manifest = try BundleManifest.load(from: bundleURL)
        guard let genome = manifest.genome else { return }
        let chromosomes = BundleBuildHelpers.addSingleSequenceAccessionAliases(
            to: genome.chromosomes, accessions: genome.chromosomes.map(\.name))
        guard chromosomes != genome.chromosomes else { return }
        let aliased = GenomeInfo(
            path: genome.path, indexPath: genome.indexPath, gzipIndexPath: genome.gzipIndexPath,
            totalLength: genome.totalLength, chromosomes: chromosomes, md5Checksum: genome.md5Checksum)
        // Swapping the genome through the manifest's own merge keeps every other field, and the save
        // makes the browser summary again from the aliased sequence.
        let withAliases = BundleManifest(
            name: manifest.name, identifier: manifest.identifier, source: manifest.source,
            genome: aliased, annotations: manifest.annotations, recordStore: nil)
        try manifest.mergingGenomeAndAnnotations(from: withAliases, preferredName: manifest.name).save(to: bundleURL)
    }
}
