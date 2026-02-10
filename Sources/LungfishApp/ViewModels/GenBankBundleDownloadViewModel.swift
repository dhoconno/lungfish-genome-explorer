// GenBankBundleDownloadViewModel.swift - NCBI GenBank download and bundle building
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let genBankDownloadLogger = Logger(subsystem: "com.lungfish.browser", category: "GenBankBundleDownload")

/// Builds NCBI GenBank nucleotide downloads into `.lungfishref` bundles.
///
/// This implementation avoids MainActor-only bundle builders so it can run safely
/// while the NCBI browser sheet is open.
public final class GenBankBundleDownloadViewModel: @unchecked Sendable {

    private let ncbiService: NCBIService
    private let toolRunner: NativeToolRunner

    public init(
        ncbiService: NCBIService = NCBIService(),
        toolRunner: NativeToolRunner = .shared
    ) {
        self.ncbiService = ncbiService
        self.toolRunner = toolRunner
    }

    /// Validates that required tools are available before attempting a download.
    ///
    /// - Throws: `BundleBuildError.missingTools` if essential tools are missing.
    public func validateTools() async throws {
        try await BundleBuildHelpers.validateTools(using: toolRunner)
    }

    public func downloadAndBuild(
        accession: String,
        outputDirectory: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default

        // Pre-flight: verify tools are available
        progressHandler?(0.01, "Checking tools...")
        try await validateTools()

        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("lungfish-genbank-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        progressHandler?(0.02, "Resolving accession \(accession)...")
        genBankDownloadLogger.info("downloadAndBuild: Fetching raw GenBank for \(accession, privacy: .public)")

        let (genBankContent, resolvedAccession) = try await ncbiService.fetchRawGenBank(accession: accession)
        let genBankURL = tempDir.appendingPathComponent("\(resolvedAccession).gb")
        try genBankContent.write(to: genBankURL, atomically: true, encoding: .utf8)

        progressHandler?(0.12, "Parsing GenBank record \(resolvedAccession)...")

        let reader = try GenBankReader(url: genBankURL)
        let records = try await reader.readAll()
        guard let record = records.first else {
            throw DatabaseServiceError.parseError(message: "No sequence records found in GenBank response")
        }

        let bundleURL = BundleBuildHelpers.makeUniqueBundleURL(
            baseName: BundleBuildHelpers.sanitizedFilename(resolvedAccession),
            in: outputDirectory
        )
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        progressHandler?(0.25, "Writing FASTA...")

        let plainFASTA = genomeDir.appendingPathComponent("sequence.fa")
        try FASTAWriter(url: plainFASTA).write([record.sequence])

        progressHandler?(0.35, "Compressing FASTA (bgzip)...")

        let bgzipResult = try await toolRunner.bgzipCompress(inputPath: plainFASTA, keepOriginal: false)
        guard bgzipResult.isSuccess else {
            throw BundleBuildError.compressionFailed(bgzipResult.combinedOutput)
        }

        let compressedFASTA = genomeDir.appendingPathComponent("sequence.fa.gz")

        progressHandler?(0.45, "Indexing FASTA (samtools faidx)...")

        let faiResult = try await toolRunner.indexFASTA(fastaPath: compressedFASTA)
        guard faiResult.isSuccess else {
            throw BundleBuildError.indexingFailed(faiResult.combinedOutput)
        }

        let faiURL = compressedFASTA.appendingPathExtension("fai")
        let gziURL = compressedFASTA.appendingPathExtension("gzi")

        let chromosomes = try BundleBuildHelpers.parseFai(at: faiURL)
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }

        // Build chromosome sizes for annotation coordinate clipping
        let chromosomeSizes = chromosomes.map { ($0.name, $0.length) }
        let chromSizesURL = tempDir.appendingPathComponent("chrom.sizes")
        try BundleBuildHelpers.writeChromSizes(chromosomes, to: chromSizesURL)

        var annotationTracks: [AnnotationTrackInfo] = []
        if !record.annotations.isEmpty {
            progressHandler?(0.55, "Converting annotations...")

            do {
                // Write BED12+ directly from parsed GenBank annotations,
                // preserving ALL qualifiers (db_xref, product, protein_id, etc.)
                // and multi-interval (join) features as proper BED12 blocks.
                let bedURL = tempDir.appendingPathComponent("annotations.bed")
                writeGenBankAnnotationsToBED(
                    annotations: record.annotations,
                    chromName: record.locus.name,
                    to: bedURL
                )

                // Clip BED coordinates to chromosome boundaries (required for bedToBigBed)
                BundleBuildHelpers.clipBEDCoordinates(bedURL: bedURL, chromosomeSizes: chromosomeSizes)

                progressHandler?(0.65, "Creating annotation database...")

                // Create SQLite annotation database BEFORE stripping extra columns
                let dbURL = annotationsDir.appendingPathComponent("ncbi_genbank_annotations.db")
                let dbRecordCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
                genBankDownloadLogger.info("downloadAndBuild: Created annotation database with \(dbRecordCount) records")

                // Strip extra columns (13+) for bedToBigBed — it only handles standard BED12.
                BundleBuildHelpers.stripExtraBEDColumns(bedURL: bedURL, keepColumns: 12)

                progressHandler?(0.72, "Converting to BigBed...")

                let bigBedURL = annotationsDir.appendingPathComponent("ncbi_genbank_annotations.bb")
                let hasBedToBigBed = await toolRunner.isToolAvailable(.bedToBigBed)
                var usedBigBed = false

                if hasBedToBigBed {
                    let bigBedResult = try await toolRunner.convertBEDtoBigBed(
                        bedPath: bedURL,
                        chromSizesPath: chromSizesURL,
                        outputPath: bigBedURL
                    )

                    if bigBedResult.isSuccess {
                        usedBigBed = true
                    } else {
                        genBankDownloadLogger.warning("downloadAndBuild: bedToBigBed failed, keeping BED: \(bigBedResult.combinedOutput, privacy: .public)")
                    }
                } else {
                    genBankDownloadLogger.warning("downloadAndBuild: bedToBigBed unavailable, keeping BED")
                }

                // Use BigBed if available, otherwise copy BED as fallback
                let annotationPath: String
                if usedBigBed {
                    annotationPath = "annotations/ncbi_genbank_annotations.bb"
                    try? fileManager.removeItem(at: bedURL)
                } else {
                    let fallbackBedURL = annotationsDir.appendingPathComponent("ncbi_genbank_annotations.bed")
                    try fileManager.copyItem(at: bedURL, to: fallbackBedURL)
                    annotationPath = "annotations/ncbi_genbank_annotations.bed"
                }

                annotationTracks.append(
                    AnnotationTrackInfo(
                        id: "ncbi_genbank_annotations",
                        name: "NCBI GenBank Annotations",
                        description: "Converted from GenBank FEATURES",
                        path: annotationPath,
                        databasePath: dbRecordCount > 0 ? "annotations/ncbi_genbank_annotations.db" : nil,
                        annotationType: .gene,
                        featureCount: record.annotations.count,
                        source: "NCBI",
                        version: nil
                    )
                )
            } catch {
                genBankDownloadLogger.warning("downloadAndBuild: Annotation conversion failed (continuing without annotations): \(error.localizedDescription, privacy: .public)")
            }
        }

        progressHandler?(0.85, "Writing bundle manifest...")

        let genomeInfo = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: fileManager.fileExists(atPath: gziURL.path) ? "genome/sequence.fa.gz.gzi" : nil,
            totalLength: totalLength,
            chromosomes: chromosomes,
            md5Checksum: nil
        )

        let sourceInfo = SourceInfo(
            organism: record.sequence.description ?? record.definition ?? "Unknown",
            commonName: nil,
            taxonomyId: nil,
            assembly: record.sequence.name,
            assemblyAccession: resolvedAccession,
            database: "NCBI",
            sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(resolvedAccession)"),
            downloadDate: Date(),
            notes: "Downloaded from NCBI GenBank and converted to Lungfish reference bundle"
        )

        let bundleIdentifier = "org.ncbi.genbank.\(resolvedAccession.lowercased().replacingOccurrences(of: ".", with: "-"))"

        // Build metadata groups from GenBank record fields
        let metadataGroups = genBankRecordMetadataGroups(record: record, resolvedAccession: resolvedAccession)

        let manifest = BundleManifest(
            name: resolvedAccession,
            identifier: bundleIdentifier,
            description: record.definition,
            source: sourceInfo,
            genome: genomeInfo,
            annotations: annotationTracks,
            variants: [],
            tracks: [],
            metadata: metadataGroups.isEmpty ? nil : metadataGroups
        )

        let validationErrors = manifest.validate()
        if !validationErrors.isEmpty {
            throw BundleBuildError.validationFailed(validationErrors.map { $0.localizedDescription })
        }

        try manifest.save(to: bundleURL)

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        genBankDownloadLogger.info("downloadAndBuild: Bundle complete at \(bundleURL.path, privacy: .public)")
        return bundleURL
    }
}

// MARK: - GenBank Metadata Helpers

/// Builds metadata groups from a GenBank record for storage in the bundle manifest.
///
/// Creates two groups:
/// - **Record**: accession, version, definition, molecule type, topology, division, date
/// - **Sequence**: length, name, description
private func genBankRecordMetadataGroups(
    record: GenBankRecord,
    resolvedAccession: String
) -> [MetadataGroup] {
    var groups: [MetadataGroup] = []

    // Record group
    var recordItems: [MetadataItem] = []

    if let accession = record.accession {
        recordItems.append(MetadataItem(label: "Accession", value: accession))
    }
    if let version = record.version {
        recordItems.append(MetadataItem(label: "Version", value: version))
    }
    if let definition = record.definition {
        recordItems.append(MetadataItem(label: "Definition", value: definition))
    }
    recordItems.append(MetadataItem(label: "Molecule Type", value: record.locus.moleculeType.rawValue))
    recordItems.append(MetadataItem(label: "Topology", value: record.locus.topology.rawValue))
    if let division = record.locus.division {
        recordItems.append(MetadataItem(label: "Division", value: division))
    }
    if let date = record.locus.date {
        recordItems.append(MetadataItem(label: "Date", value: date))
    }

    if !recordItems.isEmpty {
        groups.append(MetadataGroup(name: "Record", items: recordItems))
    }

    // Sequence group
    var sequenceItems: [MetadataItem] = []

    sequenceItems.append(MetadataItem(label: "Length", value: formatGenBankBp(record.locus.length)))
    sequenceItems.append(MetadataItem(label: "Name", value: record.sequence.name))
    if let desc = record.sequence.description {
        sequenceItems.append(MetadataItem(label: "Description", value: desc))
    }

    if !sequenceItems.isEmpty {
        groups.append(MetadataGroup(name: "Sequence", items: sequenceItems))
    }

    return groups
}

/// Formats a base-pair count with appropriate units (bp, Kb, Mb, Gb).
private func formatGenBankBp(_ value: Int) -> String {
    if value >= 1_000_000_000 {
        return String(format: "%.1f Gb", Double(value) / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1f Mb", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1f Kb", Double(value) / 1_000)
    }
    return "\(value) bp"
}

// MARK: - Direct GenBank → BED12+ Conversion

/// Writes GenBank annotations directly to BED12+ format, preserving ALL qualifiers.
///
/// This bypasses the lossy GFF3Writer → AnnotationConverter pipeline. Each annotation
/// is written as a single BED12 line with proper block structure for multi-interval
/// (join) features. Column 13 holds the GenBank feature type and column 14 holds
/// all qualifiers as percent-encoded `key=value;key=value` pairs.
///
/// Source features are excluded (they span the entire sequence).
private func writeGenBankAnnotationsToBED(
    annotations: [SequenceAnnotation],
    chromName: String,
    to outputURL: URL
) {
    struct BEDEntry {
        let chromosome: String
        let start: Int
        let line: String
    }

    var entries: [BEDEntry] = []

    // Percent-encoding character set — must encode ; = \t \n % to preserve key=value;key=value format
    var allowedCharacters = CharacterSet.urlQueryAllowed
    allowedCharacters.remove(charactersIn: ";=\t\n%")

    for annotation in annotations {
        // Skip source features — they span the entire sequence
        if annotation.type == .source {
            continue
        }

        let chromosome = annotation.chromosome ?? chromName
        let intervals = annotation.intervals.sorted { $0.start < $1.start }
        let featureStart = intervals.first?.start ?? 0
        let featureEnd = intervals.last?.end ?? 0

        let name = annotation.name
        let score = 0
        let strand = annotation.strand.rawValue

        let thickStart = featureStart
        let thickEnd = featureEnd

        let color = annotation.type.defaultColor
        let r = Int(color.red * 255)
        let g = Int(color.green * 255)
        let b = Int(color.blue * 255)
        let itemRgb = "\(r),\(g),\(b)"

        // BED12 block structure for multi-interval (join) features
        let blockCount = intervals.count
        let blockSizes = intervals.map { "\($0.end - $0.start)" }.joined(separator: ",") + ","
        let blockStarts = intervals.map { "\($0.start - featureStart)" }.joined(separator: ",") + ","

        // Column 13: real GenBank feature type
        let featureType = annotation.qualifiers[GenBankReader.rawFeatureTypeQualifierKey]?.firstValue
            ?? annotation.type.rawValue

        // Column 14: all qualifiers as key=value;key=value (percent-encoded)
        let qualifierPairs: [String] = annotation.qualifiers
            .filter { $0.key != GenBankReader.rawFeatureTypeQualifierKey }
            .sorted { $0.key < $1.key }
            .map { key, qualifier in
                let joinedValues = qualifier.values.joined(separator: ",")
                let encodedValues = joinedValues.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? joinedValues
                return "\(key)=\(encodedValues)"
            }
        let qualifiersString = qualifierPairs.joined(separator: ";")

        let bedLine = [
            chromosome,
            String(featureStart),
            String(featureEnd),
            name,
            String(score),
            strand,
            String(thickStart),
            String(thickEnd),
            itemRgb,
            String(blockCount),
            blockSizes,
            blockStarts,
            featureType,
            qualifiersString
        ].joined(separator: "\t")

        entries.append(BEDEntry(chromosome: chromosome, start: featureStart, line: bedLine))
    }

    // Sort by chromosome then start position
    entries.sort { a, b in
        if a.chromosome != b.chromosome {
            return a.chromosome < b.chromosome
        }
        return a.start < b.start
    }

    let bedContent = entries.map(\.line).joined(separator: "\n")
    try? bedContent.write(to: outputURL, atomically: true, encoding: .utf8)

    genBankDownloadLogger.info("writeGenBankAnnotationsToBED: \(entries.count) features written")
}
