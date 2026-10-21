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

    // MARK: - The second bundle, with a genome, coding features and an iVar track (review of 12.39 B2, Fix 4)

    static let ivarTrackID = "ivar"
    static let plainTrackID = "plain"
    static let cdsTrackID = "cds"
    /// chr1 of the second bundle, 120 bases. The forward CDS `cdsF` is [10,40) and [60,90), 20 codons from ATG. The
    /// reverse CDS `cdsR` is [96,117), the reverse complement of ATG CAT GGC TTA ACG CCA GAT.
    static let derivedGenome = [
        "TTGCACGTAA", "ATGAAAGCTGAATTTCCCGGTACCCTGAAG", "GTAAGTCCCTTTGGAACAAG",
        "GATTGGCATTCAGGGCGTTACAACCCAGCC", "ATCAGT", "ATCTGGCGTTAAGCCATGCAT", "CGA",
    ].joined()

    static let derivedVariantColumns: [ScientificTableColumn] = [
        .init(id: "VariantIdColumn", title: "ID"), .init(id: "VariantChromColumn", title: "Chrom"),
        .init(id: "PositionColumn", title: "Position"), .init(id: "RefColumn", title: "Ref"),
        .init(id: "AltColumn", title: "Alt"), .init(id: "QualityColumn", title: "Quality"),
        .init(id: "FilterColumn", title: "Filter"), .init(id: "SamplesColumn", title: "Samples"),
        .init(id: "info_AF", title: "AF"), .init(id: "info_DP", title: "DP"),
        .init(id: "info_ALT_FREQ", title: "ALT_FREQ"), .init(id: "info_ALT_QUAL", title: "ALT_QUAL"),
        .init(id: "TrackNameColumn", title: "Track"),
        .init(id: AnnotationTableExport.callerSettingsColumnID, title: "Caller Settings"),
        .init(id: AnnotationTableDrawerView.codingFeatureColumn.rawValue, title: "Gene / Protein"),
        .init(id: AnnotationTableDrawerView.consequenceColumn.rawValue, title: "Consequence"),
        .init(id: AnnotationTableDrawerView.aaChangeColumn.rawValue, title: "AA Change"),
    ]
    static let derivedNumericColumnIDs: Set<String> = ["info_AF", "info_ALT_FREQ", "info_ALT_QUAL"]

    /// The second bundle: the genome with its index, an annotation database of the two CDS, an iVar track whose
    /// manifest source is `iVar` and whose `path` is the overlay VCF, and a plain track. The iVar track holds a
    /// variant outside every CDS, an indel in `cdsF`, a synonymous change in its first block, a missense change in its
    /// second block and a missense change in `cdsR`. The plain track holds one variant in the intron. With `addsChr2`
    /// the genome gains `chr2`, the track `cds` its `chr2` CDS, a second track `cds2` follows it with its own
    /// database, and the iVar track gains the `chr2` calls (`+CDSShapes.swift`).
    static func makeDerivedFixture(_ root: URL, addsChr2: Bool = false) throws {
        let fileManager = FileManager.default
        let bundle = bundleURL(in: root)
        for folder in ["genome", "annotations", "variants"] {
            try fileManager.createDirectory(at: bundle.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        try (">chr1\n" + derivedGenome + "\n" + (addsChr2 ? ">chr2\n" + chr2Genome + "\n" : "")).write(
            to: bundle.appendingPathComponent("genome/sequence.fa"), atomically: true, encoding: .utf8
        )
        try ("chr1\t120\t6\t120\t121\n" + (addsChr2 ? chr2IndexLine : "")).write(
            to: bundle.appendingPathComponent("genome/sequence.fa.fai"), atomically: true, encoding: .utf8
        )
        let bed = root.appendingPathComponent("cds.bed")
        try ("chr1\t10\t90\tcdsF\t0\t+\t10\t90\t0,0,0\t2\t30,30\t0,50\tCDS\tgene=geneF\n"
            + "chr1\t96\t117\tcdsR\t0\t-\t96\t117\t0,0,0\t1\t21\t0\tCDS\tgene=geneR\n" + (addsChr2 ? chr2CDSLines : ""))
            .write(to: bed, atomically: true, encoding: .utf8)
        _ = try AnnotationDatabase.createFromBED(bedURL: bed, outputURL: bundle.appendingPathComponent("annotations/cds.db"))
        try fileManager.removeItem(at: bed)
        if addsChr2 {
            let secondBED = root.appendingPathComponent("cds2.bed")
            try chr2CDS2Lines.write(to: secondBED, atomically: true, encoding: .utf8)
            _ = try AnnotationDatabase.createFromBED(bedURL: secondBED, outputURL: bundle.appendingPathComponent("annotations/cds2.db"))
            try fileManager.removeItem(at: secondBED)
        }

        let format = "GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ"
        let calls: [DerivedCall] = [
            (4, "C", "G", "SNP", 90, "1"), (14, "AA", "A", "INDEL", 50, "0.5"), (31, "T", "C", "SNP", 200, "0.75"),
            (65, "G", "C", "SNP", 120, "0.5"), (110, "C", "T", "SNP", 80, "0.25"),
        ]
        let line = { (chromosome: String, call: DerivedCall) in
            "\(chromosome)\t\(call.position)\t.\t\(call.ref)\t\(call.alt)\t.\tPASS\tTYPE=\(call.type)\t\(format)\t"
                + "1:\(call.depth):0:0:0:\(call.depth):1:66:\(call.frequency)"
        }
        let body = (calls.map { line("chr1", $0) } + (addsChr2 ? chr2Calls.map { line("chr2", $0) } : []))
            .joined(separator: "\n")
        let ivarVCF = bundle.appendingPathComponent("variants/ivar.vcf")
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tsample-a\n\(body)\n"
            .write(to: ivarVCF, atomically: true, encoding: .utf8)
        let plainVCF = bundle.appendingPathComponent("variants/plain.vcf")
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tPLAIN_S\nchr1\t50\t.\tT\tA\t40\tPASS\tDP=9\tGT\t0/1\n"
            .write(to: plainVCF, atomically: true, encoding: .utf8)
        for (vcf, name) in [(ivarVCF, "ivar"), (plainVCF, "plain")] {
            try VariantDatabase.createFromVCF(
                vcfURL: vcf, outputURL: bundle.appendingPathComponent("variants/\(name).db"),
                parseGenotypes: true, sourceFile: "\(name).vcf", progressHandler: nil
            )
        }
        try BundleManifest(
            name: "fixture",
            identifier: "org.lungfish.test.annotation-table-parity-derived",
            source: SourceInfo(organism: "Test", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai", totalLength: 120 + (addsChr2 ? Int64(chr2Genome.count) : 0),
                chromosomes: [ChromosomeInfo(name: "chr1", length: 120, offset: 6, lineBases: 120, lineWidth: 121)]
                    + (addsChr2 ? [chr2Info] : [])
            ),
            annotations: [AnnotationTrackInfo(id: cdsTrackID, name: "CDS", path: "annotations/cds.bb", databasePath: "annotations/cds.db")]
                + (addsChr2 ? [AnnotationTrackInfo(id: cds2TrackID, name: "CDS 2", path: "annotations/cds2.bb", databasePath: "annotations/cds2.db")] : []),
            variants: [
                VariantTrackInfo(
                    id: ivarTrackID, name: "iVar calls", path: "variants/ivar.vcf", indexPath: "variants/ivar.db",
                    databasePath: "variants/ivar.db", variantCount: calls.count + (addsChr2 ? chr2Calls.count : 0), source: "iVar"
                ),
                VariantTrackInfo(
                    id: plainTrackID, name: "Plain calls", path: "variants/plain.vcf", indexPath: "variants/plain.db",
                    databasePath: "variants/plain.db", variantCount: 1
                ),
            ]
        ).save(to: bundle)
    }

    /// The input paths below a side root that a case's record names, sorted. On the second bundle they follow the tab,
    /// and the variants and genotypes tabs name only the tracks their rows came from, the samples tab every variant
    /// database, and only the variants tab the CDS database and the genome.
    static func expectedInputs(_ parityCase: Case) -> [String] {
        let bundle = "/\(bundleName)/"
        guard parityCase.derived else {
            return parityCase.tab == .annotations
                ? [bundle + "annotations/genes.db", bundle + "manifest.json"]
                : [bundle + "manifest.json", bundle + "variants.db"]
        }
        var names = ["manifest.json"]
        switch parityCase.tab {
        case .annotations: names += ["annotations/cds.db"]
        case .variants:
            names += ["annotations/cds.db", "genome/sequence.fa", "variants/ivar.db", "variants/ivar.vcf"]
            if parityCase.showsPlainTrack { names.append("variants/plain.db") }
            if parityCase.addsChr2 { names.append("annotations/cds2.db") }
        case .genotypes: names += ["variants/ivar.db", "variants/ivar.vcf"]
        case .samples: names += ["variants/ivar.db", "variants/plain.db"]
        }
        return names.map { bundle + $0 }.sorted()
    }

    static func collectCase(_ parityCase: Case, in root: URL) async throws -> Collected {
        if parityCase.bundleWide { return try await collectBundleWide(parityCase, in: root) }
        if parityCase.derived { return try await collectDerived(parityCase, in: root) }
        return try collect(parityCase.tab, in: root)
    }

    /// The coding bases of `annotation` read from `derivedGenome` here: the exons in order on the forward strand, and
    /// the reverse complement of the exons from the last on the reverse strand, with the frame at the first base.
    /// This is the context the viewer caches for a CDS it shows whole, and the leaf does not read it. It is never nil,
    /// and the call site wraps it, so no fixture CDS falls back to the leaf's own derivation without a sign
    /// (Optional 4 of the 12.39 fix-2 review).
    static func explicitCodingContext(_ annotation: SequenceAnnotation) -> VariantTableCodingFeatures.Context {
        let genome = Array(derivedGenome)
        var bases: [Character] = []
        var positions: [Int] = []
        for interval in annotation.intervals.sorted(by: { $0.start < $1.start }) {
            for position in interval.start..<interval.end {
                bases.append(genome[position])
                positions.append(position)
            }
        }
        if annotation.strand == .reverse {
            let complement: [Character: Character] = ["A": "T", "T": "A", "C": "G", "G": "C"]
            bases = bases.reversed().map { complement[$0] ?? $0 }
            positions.reverse()
        }
        return (codingBases: bases, codingGenomePositions: positions, phaseOffset: 0, codonTable: .standard, codonsBeforeFirstRead: 0)
    }

    /// The samples of every variant database, the first database naming a sample and source winning.
    static func derivedSampleRows(_ databases: [URL]) throws -> [AnnotationTableDrawerView.SampleDisplayRow] {
        var seen = Set<String>()
        return try databases.flatMap { try sampleRows($0) }.filter { seen.insert($0.rowKey).inserted }
    }

    /// What the drawer's `collect` closure gives for All Matching Rows of the tab on the second bundle. The variant
    /// rows carry the iVar FORMAT values of the overlay `iVarSources` loads, the variants tab shows the three derived
    /// columns resolved from coding features built with `explicitCodingContext`, and the selection names the region
    /// and the annotation track of those features.
    static func collectDerived(_ parityCase: Case, in root: URL) async throws -> Collected {
        let folder = Self.bundleURL(in: root)
        let manifest = try BundleManifest.load(from: folder)
        let bundle = ReferenceBundle(url: folder, manifest: manifest)
        let cds = folder.appendingPathComponent("annotations/cds.db")
        let ivarDB = folder.appendingPathComponent("variants/ivar.db")
        let plainDB = folder.appendingPathComponent("variants/plain.db")
        let handles = [
            (trackId: ivarTrackID, db: try VariantDatabase(url: ivarDB)),
            (trackId: plainTrackID, db: try VariantDatabase(url: plainDB)),
        ]
        var aliasMaps = BundleChromosomeAliasMaps()
        aliasMaps.reset(chromosomes: manifest.genome?.chromosomes ?? [])
        let overlay = await VariantFormatOverlayLoader.load(
            sources: VariantFormatOverlaySource.iVarSources(bundle: bundle, databases: handles, aliasMaps: &aliasMaps)
        )
        let chr2 = parityCase.addsChr2 ? try chr2ViewerFeatures(bundle: bundle) : nil
        let features = try chr2?.features ?? VariantTableCodingFeatures.features(
            annotations: try bundle.getAnnotationsSync(trackId: cdsTrackID, region: GenomicRegion(chromosome: "chr1", start: 0, end: 120)),
            fallbackChromosome: "chr1",
            chromosomeName: { bundle.chromosome(named: $0)?.name ?? $0 },
            context: { Optional(explicitCodingContext($0)) }
        )
        let codingFeatureRegion = chr2?.region
            ?? AnnotationTableFeatureRegion(chromosome: "chr1", start: 0, end: 120, trackIDs: [cdsTrackID])
        let resolver = try VariantTableExportResolverSnapshot(
            features: features, variantChromosomeAliasMap: [:],
            referenceChromosomeAliases: VariantTableCodingFeatures.referenceAliases(chromosomes: manifest.genome?.chromosomes ?? []),
            referenceBundle: bundle
        ).preparingForBackgroundExport()
        let sources = AnnotationTableExportSources(
            manifestURL: folder.appendingPathComponent(BundleManifest.filename),
            genomeURL: folder.appendingPathComponent("genome/sequence.fa"),
            annotationDatabases: [.init(trackID: cdsTrackID, url: cds)]
                + (parityCase.addsChr2 ? [.init(trackID: cds2TrackID, url: folder.appendingPathComponent("annotations/cds2.db"))] : []),
            variantDatabases: [.init(trackID: ivarTrackID, url: ivarDB), .init(trackID: plainTrackID, url: plainDB)],
            overlayURLsByTrack: Dictionary(grouping: overlay.sourceIdentities, by: \.trackID)
                .mapValues { identities in identities.map(\.url).sorted { $0.path < $1.path } },
            codingFeatureTrackIDs: parityCase.tab == .variants ? codingFeatureRegion.trackIDs : nil
        )
        switch parityCase.tab {
        case .annotations:
            let rows = try AnnotationTableAnnotationQueryRequest(
                databases: [(trackID: cdsTrackID, url: cds, trackName: "CDS")], allowedChromosomes: nil,
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
        case .variants, .genotypes:
            let rows = try AnnotationTableVariantQueryRequest(
                context: AnnotationVariantQueryContext(
                    databases: handles, trackNames: [ivarTrackID: "iVar calls", plainTrackID: "Plain calls"],
                    trackChromosomes: [ivarTrackID: parityCase.addsChr2 ? ["chr1", "chr2"] : ["chr1"], plainTrackID: ["chr1"]],
                    annotationDatabases: [],
                    infoKeys: ["AF", "ALT_FREQ", "ALT_QUAL", "DP", "TYPE"], variantAliasMap: [:], formatOverlay: overlay
                ),
                query: .init(), types: [], infoFilters: [],
                selectedSamples: [], activeTokens: [], region: nil, geneList: nil,
                filterBookmarkedOnly: false, filterModerateOrHigher: false,
                withinSampleAFRange: nil, bookmarkedKeys: [], hiddenTrackIDs: parityCase.showsPlainTrack ? [] : [plainTrackID],
                variantColumnFilters: [], callerSettingsByTrack: [:],
                resolverSnapshot: resolver, numericColumnKeys: ["position"],
                sortKey: "position", sortAscending: false
            ).run(shouldCancel: { false }, preparedResolverSnapshot: resolver)
            if parityCase.tab == .genotypes {
                let genotypes = try genotypeRows(rows, databaseURL: ivarDB, trackID: ivarTrackID)
                return Collected(
                    snapshot: .captureGenotypes(
                        genotypes, columns: genotypeColumns, scope: .allMatching, numericInfoColumnIDs: [],
                        integerInfoColumnIDs: ["gtinfo_DP"],
                        sourceURLs: try sources.urls(tab: "genotypes", trackIDs: Set(genotypes.map(\.trackId))),
                        queryDescription: ["text": "", "sort": "database-default:ascending"]
                    ),
                    table: AnnotationTableExportSelection(scope: "allMatching", columns: genotypeColumns, integerColumnIDs: ["gtinfo_DP"])
                )
            }
            let callerSettings = [
                ivarTrackID: VariantCallerSettingsSummary.text(databaseURL: ivarDB),
                plainTrackID: VariantCallerSettingsSummary.text(databaseURL: plainDB),
            ]
            return Collected(
                snapshot: .captureVariants(
                    rows, columns: derivedVariantColumns, scope: .allMatching,
                    numericInfoColumnIDs: derivedNumericColumnIDs, integerInfoColumnIDs: ["info_DP"],
                    sourceURLs: try sources.urls(tab: "variants", trackIDs: Set(rows.map(\.trackId))),
                    queryDescription: [
                        "text": "", "sort": "position:descending", "derivedVariantFeatureCount": String(resolver.features.count),
                    ],
                    resolvedText: AnnotationTableExport.variantResolvedText(
                        rows: rows, columns: derivedVariantColumns, callerSettingsByTrack: callerSettings,
                        resolverSnapshot: resolver
                    )
                ),
                table: AnnotationTableExportSelection(
                    scope: "allMatching", columns: derivedVariantColumns,
                    numericColumnIDs: derivedNumericColumnIDs.sorted(), integerColumnIDs: ["info_DP"],
                    variantChromosomeAliases: [:], codingFeatureRegion: codingFeatureRegion
                )
            )
        case .samples:
            let rows = try derivedSampleRows([ivarDB, plainDB])
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

    /// The genotype rows of `variants`, built as the drawer's All Matching genotype path builds them.
    static func genotypeRows(
        _ variants: [AnnotationSearchIndex.SearchResult], databaseURL: URL,
        trackID: String = AnnotationTableExportCLIGUIParityReplayTests.trackID
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
