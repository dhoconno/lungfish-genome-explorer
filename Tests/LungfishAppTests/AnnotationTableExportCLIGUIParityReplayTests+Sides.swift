// AnnotationTableExportCLIGUIParityReplayTests+Sides.swift - The fixture, the sides and the compares of B2's parity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

// MARK: - The fixture and the drawer's collect step

extension AnnotationTableExportCLIGUIParityReplayTests {
    static func outputURL(in root: URL, _ format: ScientificTableFormat) -> URL {
        root.appendingPathComponent("table.\(format.rawValue)")
    }

    static func bundleURL(in root: URL) -> URL {
        root.appendingPathComponent(bundleName, isDirectory: true)
    }

    static func envelope(of output: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
    }

    static func envelope(in root: URL, _ parityCase: Case) throws -> ProvenanceEnvelope {
        try envelope(of: outputURL(in: root, parityCase.format))
    }

    /// `VariantEditFixture`'s bundle (three variants, two samples) with an annotation database of a one-line gene
    /// and a two-block transcript beside its variant track.
    static func makeFixture(_ root: URL) throws {
        let fixture = try VariantEditFixture.make(in: root, named: "fixture", withTrackManifest: true)
        let bed = root.appendingPathComponent("genes.bed")
        try ("chr1\t10\t60\tgene-a\t0\t+\t10\t60\t0,0,0\t1\t50\t0\tgene\tgene_id=gene-a\n"
            + "chr1\t100\t200\ttx-b\t0\t+\t100\t200\t0,0,0\t2\t20,30\t0,70\tmRNA\tgene=gene-a\n")
            .write(to: bed, atomically: true, encoding: .utf8)
        let annotations = fixture.bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotations, withIntermediateDirectories: true)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: annotations.appendingPathComponent("genes.db"))
        try FileManager.default.removeItem(at: bed)
        try BundleManifest(
            name: "fixture",
            identifier: "org.lungfish.test.annotation-table-parity",
            source: SourceInfo(organism: "Test", assembly: "fixture"),
            annotations: [AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb", databasePath: "annotations/genes.db")],
            variants: [VariantTrackInfo(
                id: trackID, name: VariantEditFixture.trackName, path: "variants.db", indexPath: "variants.db",
                databasePath: "variants.db", variantType: .snp, variantCount: 3
            )]
        ).save(to: fixture.bundleURL)
    }

    static let annotationColumns: [ScientificTableColumn] = [
        .init(id: "NameColumn", title: "Name"), .init(id: "TypeColumn", title: "Type"),
        .init(id: "ChromosomeColumn", title: "Chromosome"), .init(id: "StartColumn", title: "Start"),
        .init(id: "EndColumn", title: "End"), .init(id: "SizeColumn", title: "Size"),
        .init(id: "StrandColumn", title: "Strand"), .init(id: "TrackNameColumn", title: "Track"),
        .init(id: "attr_gene_id", title: "gene_id"), .init(id: "attr_gene", title: "gene"),
    ]
    static let variantColumns: [ScientificTableColumn] = [
        .init(id: "VariantIdColumn", title: "ID"), .init(id: "VariantChromColumn", title: "Chrom"),
        .init(id: "PositionColumn", title: "Position"), .init(id: "RefColumn", title: "Ref"),
        .init(id: "AltColumn", title: "Alt"), .init(id: "QualityColumn", title: "Quality"),
        .init(id: "FilterColumn", title: "Filter"), .init(id: "SamplesColumn", title: "Samples"),
        .init(id: "info_DP", title: "DP"), .init(id: "TrackNameColumn", title: "Track"),
        .init(id: AnnotationTableExport.callerSettingsColumnID, title: "Caller Settings"),
    ]
    static let genotypeColumns: [ScientificTableColumn] = [
        .init(id: "GTSampleColumn", title: "Sample"), .init(id: "GTVariantColumn", title: "Variant"),
        .init(id: "GTPositionColumn", title: "Position"), .init(id: "GTGenotypeColumn", title: "GT"),
        .init(id: "GTZygosityColumn", title: "Zygosity"), .init(id: "GTADColumn", title: "AD"),
        .init(id: "GTDPColumn", title: "DP"), .init(id: "GTABColumn", title: "AB"),
        .init(id: "gtinfo_DP", title: "DP (INFO)"),
    ]
    static let sampleColumns: [ScientificTableColumn] = [
        .init(id: "SampleVisibleColumn", title: "Visible"), .init(id: "SampleNameColumn", title: "Sample"),
        .init(id: "SampleDisplayNameColumn", title: "Display Name"), .init(id: "SampleSourceColumn", title: "Source"),
    ]

    /// What the drawer's `collect` closure gives for All Matching Rows of `tab`, with the inputs named per tab and the
    /// state frozen at the click. The annotation rows sort by end, descending, and the variant rows by position,
    /// descending, so the identities' order is not the database's.
    static func collect(_ tab: AnnotationTableExport.Tab, in root: URL) throws -> Collected {
        let bundle = bundleURL(in: root)
        let genes = bundle.appendingPathComponent("annotations/genes.db")
        let variants = bundle.appendingPathComponent("variants.db")
        let sources = AnnotationTableExportSources(
            manifestURL: bundle.appendingPathComponent(BundleManifest.filename), genomeURL: nil,
            annotationDatabases: [.init(trackID: "genes", url: genes)],
            variantDatabases: [.init(trackID: trackID, url: variants)],
            overlayURLsByTrack: [:], codingFeatureTrackIDs: nil
        )
        switch tab {
        case .annotations:
            let rows = try AnnotationTableAnnotationQueryRequest(
                databases: [(trackID: "genes", url: genes, trackName: "Genes")], allowedChromosomes: nil,
                nameFilter: "", types: [], query: .init(), databaseColumnFilters: [], allColumnFilters: [],
                numericSortKeys: ["start", "end", "size"], sortKey: "end", sortAscending: false
            ).run(shouldCancel: { false })
            return Collected(
                snapshot: .captureAnnotations(
                    rows, columns: annotationColumns, scope: .allMatching,
                    sourceURLs: try sources.urls(tab: "annotations", trackIDs: Set(rows.map(\.trackId))),
                    queryDescription: ["text": "", "sort": "end:descending"]
                ),
                table: AnnotationTableExportSelection(scope: "allMatching", columns: annotationColumns)
            )
        case .variants:
            let rows = try variantRows(variants)
            return Collected(
                snapshot: .captureVariants(
                    rows, columns: variantColumns, scope: .allMatching, numericInfoColumnIDs: [],
                    integerInfoColumnIDs: ["info_DP"],
                    sourceURLs: try sources.urls(tab: "variants", trackIDs: [trackID]),
                    queryDescription: ["text": "", "sort": "position:descending"],
                    resolvedText: AnnotationTableExport.variantResolvedText(
                        rows: rows, columns: variantColumns,
                        callerSettingsByTrack: [trackID: VariantCallerSettingsSummary.text(databaseURL: variants)],
                        resolverSnapshot: .empty
                    )
                ),
                table: AnnotationTableExportSelection(scope: "allMatching", columns: variantColumns, integerColumnIDs: ["info_DP"])
            )
        case .genotypes:
            let rows = try genotypeRows(try variantRows(variants), databaseURL: variants)
            return Collected(
                snapshot: .captureGenotypes(
                    rows, columns: genotypeColumns, scope: .allMatching, numericInfoColumnIDs: [],
                    integerInfoColumnIDs: ["gtinfo_DP"],
                    sourceURLs: try sources.urls(tab: "genotypes", trackIDs: Set(rows.map(\.trackId))),
                    queryDescription: ["text": "", "sort": "database-default:ascending"]
                ),
                table: AnnotationTableExportSelection(scope: "allMatching", columns: genotypeColumns, integerColumnIDs: ["gtinfo_DP"])
            )
        case .samples:
            let rows = try sampleRows(variants)
            return Collected(
                snapshot: .captureSamples(
                    rows, columns: sampleColumns, scope: .allMatching,
                    sourceURLs: try sources.urls(tab: "samples", trackIDs: []),
                    queryDescription: ["sort": "database-default:ascending"]
                ),
                table: AnnotationTableExportSelection(scope: "allMatching", columns: sampleColumns),
                editedValues: AnnotationTableDrawerView.sampleEditedValues(rows)
            )
        }
    }

    /// The drawer's All Matching variant query over the fixture's track.
    static func variantRows(_ databaseURL: URL) throws -> [AnnotationSearchIndex.SearchResult] {
        let database = try VariantDatabase(url: databaseURL)
        let context = AnnotationVariantQueryContext(
            databases: [(trackID, database)], trackNames: [trackID: VariantEditFixture.trackName],
            trackChromosomes: [trackID: ["chr1", "chr2"]], annotationDatabases: [],
            infoKeys: ["DP"], variantAliasMap: [:]
        )
        return try AnnotationTableVariantQueryRequest(
            context: context, query: .init(), types: [], infoFilters: [],
            selectedSamples: [], activeTokens: [], region: nil, geneList: nil,
            filterBookmarkedOnly: false, filterModerateOrHigher: false,
            withinSampleAFRange: nil, bookmarkedKeys: [], hiddenTrackIDs: [],
            variantColumnFilters: [], callerSettingsByTrack: [:],
            resolverSnapshot: .empty, numericColumnKeys: ["position"],
            sortKey: "position", sortAscending: false
        ).run(shouldCancel: { false })
    }

    /// The genotype rows of `variants`, built as the drawer's All Matching genotype path builds them.
    static func genotypeRows(
        _ variants: [AnnotationSearchIndex.SearchResult], databaseURL: URL
    ) throws -> [AnnotationTableDrawerView.GenotypeDisplayRow] {
        let database = try VariantDatabase(url: databaseURL)
        let ids = variants.compactMap(\.variantRowId)
        let genotypes = try database.genotypesForExport(variantRowIds: ids)
        let byID = Dictionary(uniqueKeysWithValues: variants.compactMap { row in row.variantRowId.map { ($0, row) } })
        var rows: [AnnotationTableDrawerView.GenotypeDisplayRow] = []
        for id in ids {
            guard let variant = byID[id] else { continue }
            for genotype in genotypes[id] ?? [] {
                rows.append(AnnotationTableDrawerView.GenotypeDisplayRow(
                    sampleName: genotype.sampleName, variantRowId: id,
                    variantID: variant.name, chromosome: variant.chromosome,
                    position: variant.start, ref: variant.ref ?? "", alt: variant.alt ?? "",
                    genotype: genotype.genotype ?? "./.",
                    zygosity: AnnotationTableDrawerView.GenotypeDisplayRow.classify(allele1: genotype.allele1, allele2: genotype.allele2),
                    alleleDepths: genotype.alleleDepths ?? "", depth: genotype.depth,
                    genotypeQuality: genotype.genotypeQuality,
                    alleleBalance: AnnotationTableDrawerView.GenotypeDisplayRow.computeAlleleBalance(from: genotype.alleleDepths),
                    infoDict: variant.infoDict ?? [:], trackId: trackID,
                    trackName: variant.trackName ?? trackID
                ))
            }
        }
        return rows
    }

    /// The sample rows as the drawer lists them, with SAMPLE_B hidden and SAMPLE_A given a display name.
    static func sampleRows(_ databaseURL: URL) throws -> [AnnotationTableDrawerView.SampleDisplayRow] {
        let database = try VariantDatabase(url: databaseURL)
        let sourceBySample = database.allSourceFiles()
        let stored = database.allSampleMetadata()
        let samples = stored.isEmpty ? database.sampleNames().map { (name: $0, metadata: [String: String]()) } : stored
        return samples.map { sample in
            let source = sourceBySample[sample.name] ?? ""
            return AnnotationTableDrawerView.SampleDisplayRow(
                rowKey: "\(sample.name)|\(source)", name: sample.name, sourceFile: source,
                isVisible: sample.name != "SAMPLE_B", metadata: sample.metadata,
                displayName: sample.name == "SAMPLE_A" ? "Animal A" : nil
            )
        }
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
