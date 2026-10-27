// EsVirituDetectionExport.swift - The EsViritu detections export that the viewer and its CLI leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The EsViritu detections export (Phase 2.12 lane 12.31, ARCH ruling 1.1 row A1, BIO ruling on 12.31 G1).
///
/// The view and `esviritu export detections` order the batch's assemblies with these functions, and the viewer
/// exports' leaves name the metadata files with them, so the view and each leaf agree on the rows and on the
/// record's inputs.
public enum EsVirituDetectionExport {
    /// The leaf's path under `lungfish-cli` (ARCH ruling 1.1, row A1).
    public static let commandPath = ["esviritu", "export", "detections"]
    /// The workflow name the leaf's record carries (ARCH ruling 1.4).
    public static let workflowName = "lungfish esviritu export detections"
    /// The batch database of a result folder, which the viewer opens and the leaf reads.
    public static let databaseFileName = "esviritu.sqlite"

    /// The leaf's invocation for a view state, with absolute standardized paths. The begin helper passes its
    /// `arguments()` to the runner and to the row's command, and the leaf records its `canonicalArgv()`.
    public static func invocation(
        resultURL: URL,
        samples: [String],
        metadataColumns: [String],
        format: ViewerExportDelimitedFormat,
        outputURL: URL,
        force: Bool,
        emitsEvents: Bool = true
    ) -> ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: commandPath,
            input: resultURL.standardizedFileURL.path,
            state: ViewerTableExportState(samples: samples, metadataColumns: metadataColumns),
            outputFormat: format.rawValue,
            output: outputURL.standardizedFileURL.path,
            force: force,
            emitsEvents: emitsEvents
        )
    }

    /// Orders batch assemblies by read count, highest first, then by sample id and then by assembly accession, so
    /// assemblies with tied read counts keep one order from launch to launch.
    public static func assemblyPrecedes(_ lhs: ViralAssembly, _ rhs: ViralAssembly) -> Bool {
        if lhs.totalReads != rhs.totalReads {
            return lhs.totalReads > rhs.totalReads
        }
        let lhsSample = lhs.contigs.first?.sampleId ?? ""
        let rhsSample = rhs.contigs.first?.sampleId ?? ""
        if lhsSample != rhsSample {
            return lhsSample < rhsSample
        }
        return lhs.assembly < rhs.assembly
    }

    /// The sample metadata files of a result folder, the table and its edit journal, that an export reads when it
    /// writes a metadata column. Empty when it writes none. A caller keeps only the files that exist.
    public static func metadataInputURLs(in resultURL: URL, writesMetadata: Bool) -> [URL] {
        guard writesMetadata else { return [] }
        let folder = resultURL.appendingPathComponent("metadata", isDirectory: true)
        return [
            folder.appendingPathComponent("sample_metadata.tsv"),
            folder.appendingPathComponent("sample_metadata_edits.json"),
        ]
    }
}

extension EsVirituDetectionExport {
    /// Builds delimited export content from all detections.
    public static func buildDelimitedExport(
        result: LungfishIO.EsVirituResult,
        separator: String,
        metadataHeaders: [String],
        metadataValuesBySample: [String: [String]]
    ) -> String {
        var lines: [String] = []

        var headers = [
            "Sample ID", "Virus Name", "Accession", "Assembly", "Kingdom", "Phylum",
            "Class", "Order", "Family", "Genus", "Species", "Subspecies",
            "Read Count", "RPKMF", "Coverage", "Identity", "Covered Bases",
            "Nucleotide Diversity", "Assembly Length", "Filtered Reads",
            "Segment", "Length",
        ]
        // Append visible metadata column headers
        headers.append(contentsOf: metadataHeaders)
        lines.append(headers.joined(separator: separator))

        for detection in result.detections {
            var row = [
                escapeField(detection.sampleId, separator: separator),
                escapeField(detection.name, separator: separator),
                detection.accession,
                detection.assembly,
                escapeField(detection.kingdom ?? "", separator: separator),
                escapeField(detection.phylum ?? "", separator: separator),
                escapeField(detection.tclass ?? "", separator: separator),
                escapeField(detection.order ?? "", separator: separator),
                escapeField(detection.family ?? "", separator: separator),
                escapeField(detection.genus ?? "", separator: separator),
                escapeField(detection.species ?? "", separator: separator),
                escapeField(detection.subspecies ?? "", separator: separator),
                "\(detection.readCount)",
                String(format: "%.2f", detection.rpkmf),
                String(format: "%.2f", detection.meanCoverage),
                ViralDetection.identityText(detection.avgReadIdentity),
                "\(detection.coveredBases)",
                String(format: "%.6f", detection.pi),
                "\(detection.assemblyLength)",
                "\(detection.filteredReadsInSample)",
                detection.segment ?? "",
                "\(detection.length)",
            ]
            for value in metadataValuesBySample[detection.sampleId] ?? [] {
                row.append(escapeField(value, separator: separator))
            }
            lines.append(row.joined(separator: separator))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes a field for CSV output.
    private static func escapeField(_ value: String, separator: String) -> String {
        guard separator == "," else { return value }
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}

// MARK: - Reading a batch database

extension EsVirituDetectionExport {
    /// The key a batch database's rows are grouped by, one per sample and assembly. The viewer's
    /// `batchAssemblyLookup` uses the same text.
    public static func groupKey(sample: String, assembly: String) -> String {
        "\(sample)\t\(assembly)"
    }

    /// One database row as the contig the viewer shows. A missing number reads 0 and a missing description is empty.
    public static func detection(from row: EsVirituDetectionRow) -> ViralDetection {
        ViralDetection(
            sampleId: row.sample,
            name: row.virusName,
            description: row.description ?? "",
            length: row.contigLength ?? 0,
            segment: row.segment,
            accession: row.accession,
            assembly: row.assembly,
            assemblyLength: row.assemblyLength ?? 0,
            kingdom: row.kingdom,
            phylum: row.phylum,
            tclass: row.tclass,
            order: row.torder,
            family: row.family,
            genus: row.genus,
            species: row.species,
            subspecies: row.subspecies,
            rpkmf: row.rpkmf ?? 0,
            readCount: row.readCount,
            coveredBases: row.coveredBases ?? 0,
            meanCoverage: row.meanCoverage ?? 0,
            avgReadIdentity: row.avgReadIdentity ?? 0,
            pi: row.pi ?? 0,
            filteredReadsInSample: row.filteredReadsInSample ?? 0
        )
    }

    /// The rows of one sample and assembly as the assembly the viewer shows, with its contigs in the rows' order.
    /// RPKMF and mean depth are measured over the whole assembly (``ViralAssembly/esVirituRPKMF(of:)`` and
    /// ``ViralAssembly/meanDepth(of:)``), as `EsVirituDetectionParser.groupByAssembly` measures them for one sample.
    /// Identity is the mean over the assembly's reads, weighted by read count. Nil for no rows.
    public static func assembly(from group: [EsVirituDetectionRow]) -> ViralAssembly? {
        guard let first = group.first else { return nil }
        let totalReads = group.reduce(0) { $0 + $1.readCount }
        let contigs = group.map(detection(from:))
        let weightedIdentity: Double
        if totalReads > 0 {
            weightedIdentity = ViralAssembly.readWeightedMean(of: contigs, totalReads: totalReads) { $0.avgReadIdentity }
        } else {
            weightedIdentity = 0
        }
        return ViralAssembly(
            assembly: first.assembly,
            assemblyLength: first.assemblyLength ?? 0,
            name: first.virusName,
            family: first.family,
            genus: first.genus,
            species: first.species,
            totalReads: totalReads,
            rpkmf: ViralAssembly.esVirituRPKMF(of: contigs),
            meanCoverage: ViralAssembly.meanDepth(of: contigs),
            avgReadIdentity: weightedIdentity,
            contigs: contigs
        )
    }

    /// Every assembly of a batch database's rows, keyed by ``groupKey(sample:assembly:)``. Each assembly's contigs
    /// keep the rows' database order.
    public static func assemblyLookup(rows: [EsVirituDetectionRow]) -> [String: ViralAssembly] {
        var grouped: [String: [EsVirituDetectionRow]] = [:]
        for row in rows {
            grouped[groupKey(sample: row.sample, assembly: row.assembly), default: []].append(row)
        }
        return grouped.compactMapValues(assembly(from:))
    }

    /// The assemblies of the selected samples in a lookup keyed by ``groupKey(sample:assembly:)``, in the viewer's
    /// order (``assemblyPrecedes(_:_:)``).
    public static func assemblies(
        in lookup: [String: ViralAssembly],
        selectedSamples: Set<String>
    ) -> [ViralAssembly] {
        lookup
            .compactMap { key, value in
                guard let sampleId = key.split(separator: "\t", maxSplits: 1).first.map(String.init),
                      selectedSamples.contains(sampleId) else { return nil }
                return value
            }
            .sorted(by: assemblyPrecedes)
    }

    /// The sample id a batch result names, which is the one selected sample, else `batch`.
    public static func resultSampleId(selectedSamples: [String]) -> String {
        selectedSamples.count == 1 ? (selectedSamples.first ?? "batch") : "batch"
    }

    /// The result the viewer shows for the selected samples of a batch database, holding the detections an export
    /// writes in the viewer's order. It holds no coverage windows, taxonomy profile, run time or tool version, which
    /// no export reads.
    public static func batchResult(
        rows: [EsVirituDetectionRow],
        selectedSamples: [String]
    ) -> LungfishIO.EsVirituResult {
        let ordered = Self.assemblies(in: assemblyLookup(rows: rows), selectedSamples: Set(selectedSamples))
        let detections = ordered.flatMap(\.contigs)
        return LungfishIO.EsVirituResult(
            sampleId: resultSampleId(selectedSamples: selectedSamples),
            detections: detections,
            assemblies: ordered,
            taxProfile: [],
            coverageWindows: [],
            totalFilteredReads: detections.map(\.filteredReadsInSample).max() ?? 0,
            detectedFamilyCount: Set(detections.compactMap(\.family)).count,
            detectedSpeciesCount: Set(detections.compactMap(\.species)).count,
            runtime: nil,
            toolVersion: nil
        )
    }

    /// The visible metadata columns in the store's column order, and each sample's values in that order, as
    /// `MetadataColumnController.exportHeaders` and `exportValues(for:)` give them. A sample with no record or no
    /// value gets an empty field. Empty with no store.
    public static func metadataTable(
        store: SampleMetadataStore?,
        visibleColumns: Set<String>,
        sampleIds: some Swift.Sequence<String>
    ) -> (headers: [String], valuesBySample: [String: [String]]) {
        guard let store else { return ([], [:]) }
        let headers = store.columnNames.filter { visibleColumns.contains($0) }
        var valuesBySample: [String: [String]] = [:]
        for sampleId in sampleIds {
            valuesBySample[sampleId] = headers.map { store.records[sampleId]?[$0] ?? "" }
        }
        return (headers, valuesBySample)
    }
}
