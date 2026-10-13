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
        return Built(bundleURL: bundleURL, organism: organism.isEmpty ? sequenceName : organism, sources: sources)
    }
}
