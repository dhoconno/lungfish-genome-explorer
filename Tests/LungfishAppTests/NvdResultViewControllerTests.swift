import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class NvdResultViewControllerTests: XCTestCase {
    func testSelectionSurvivesCachedReloadWithDuplicateContigAcrossSamples() {
        let vc = NvdResultViewController()
        _ = vc.view

        let bundleURL = URL(fileURLWithPath: "/project/Analyses/nvd-run-a", isDirectory: true)
        let manifest = NvdManifest(
            experiment: "exp-duplicate-contigs",
            sampleCount: 2,
            contigCount: 2,
            hitCount: 2,
            blastDbVersion: "db",
            snakemakeRunId: "run-a",
            sourceDirectoryPath: "/project",
            samples: [],
            cachedTopContigs: nil
        )

        vc.configureWithCachedRows(
            [
                Self.contigRow(sampleId: "sample-A", qseqid: "NODE_1"),
                Self.contigRow(sampleId: "sample-B", qseqid: "NODE_1"),
            ],
            manifest: manifest,
            bundleURL: bundleURL
        )

        vc.testSelectOutlineRow(1)
        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample-B"])

        vc.configureWithCachedRows(
            [
                Self.contigRow(sampleId: "sample-B", qseqid: "NODE_1"),
                Self.contigRow(sampleId: "sample-A", qseqid: "NODE_1"),
            ],
            manifest: manifest,
            bundleURL: bundleURL
        )

        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample-B"])
        XCTAssertEqual(vc.testOutlineSelectedRowIndexes(), IndexSet(integer: 0))
    }

    func testContextMenuValidationUsesIdentityBackedVisibleSelectionCount() throws {
        let fixture = try NvdMenuFixture(duplicateContigs: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        vc.onBlastVerification = { _, _ in }
        _ = vc.view
        vc.configure(database: fixture.database, manifest: fixture.manifest, bundleURL: fixture.bundleURL)

        vc.testSelectOutlineRow(1)
        XCTAssertEqual(vc.testSelectedOutlineContigSamples(), ["sample2"])

        vc.testSelectOutlineRowsWithoutIdentitySync(IndexSet([0, 1]))
        let state = vc.testContextMenuActionStateForFirstContig()

        XCTAssertEqual(state.identitySelectionCount, 1)
        XCTAssertEqual(state.menuSelectionCount, 1)
        XCTAssertTrue(state.blastEnabled)
    }

    func testContextMenuExposesSharedFastaActionsWhenCallbacksPresent() throws {
        let fixture = try NvdMenuFixture()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixture.rootURL)
        }

        let vc = NvdResultViewController()
        vc.onBlastVerification = { _, _ in }
        vc.onExportFASTARequested = { _ in }
        vc.onCreateBundleRequested = { _ in }
        vc.onRunOperationRequested = { _ in }
        _ = vc.view

        vc.configure(
            database: fixture.database,
            manifest: fixture.manifest,
            bundleURL: fixture.bundleURL
        )

        XCTAssertEqual(
            vc.testContextMenuTitlesForFirstContig().filter { !$0.isEmpty },
            [
                "Extract Reads…",
                "Extract Sequence…",
                "Verify with BLAST…",
                "Copy FASTA",
                "Export FASTA…",
                "Create Bundle…",
                "Run Operation…",
                "Copy Contig Name",
                "Copy Accession",
                "View Accession on NCBI",
                "Search PubMed",
            ]
        )
    }

    private static func contigRow(sampleId: String, qseqid: String) -> NvdContigRow {
        NvdContigRow(
            sampleId: sampleId,
            qseqid: qseqid,
            qlen: 100,
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            sseqid: "NC_000001.1",
            stitle: "Reference title",
            pident: 99.5,
            evalue: 1e-20,
            bitscore: 120,
            mappedReads: 10,
            readsPerBillion: 10_000
        )
    }
}

private struct NvdMenuFixture {
    let rootURL: URL
    let bundleURL: URL
    let manifest: NvdManifest
    let database: NvdDatabase

    init(duplicateContigs: Bool = false) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nvd-menu-tests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL.appendingPathComponent("fixture.nvd", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastaRelativePath = "sample1.fasta"
        let fastaURL = bundleURL.appendingPathComponent(fastaRelativePath)
        try """
        >contig_1
        AACCGGTT
        """.write(to: fastaURL, atomically: true, encoding: .utf8)
        let secondFastaRelativePath = "sample2.fasta"
        let secondFastaURL = bundleURL.appendingPathComponent(secondFastaRelativePath)
        try """
        >contig_1
        TTGGCCAA
        """.write(to: secondFastaURL, atomically: true, encoding: .utf8)

        let hit = NvdBlastHit(
            experiment: "exp-1",
            blastTask: "blastn",
            sampleId: "sample1",
            qseqid: "contig_1",
            qlen: 8,
            sseqid: "NC_000001.1",
            stitle: "Reference title",
            taxRank: "species",
            length: 8,
            pident: 100,
            evalue: 0,
            bitscore: 50,
            sscinames: "Example virus",
            staxids: "1234",
            blastDbVersion: "db",
            snakemakeRunId: "run-1",
            mappedReads: 10,
            totalReads: 1000,
            statDbVersion: "stats-1",
            adjustedTaxid: "1234",
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            hitRank: 1,
            readsPerBillion: 10_000_000
        )
        let duplicateHit = NvdBlastHit(
            experiment: "exp-1",
            blastTask: "blastn",
            sampleId: "sample2",
            qseqid: "contig_1",
            qlen: 8,
            sseqid: "NC_000002.1",
            stitle: "Reference title 2",
            taxRank: "species",
            length: 8,
            pident: 99,
            evalue: 0,
            bitscore: 45,
            sscinames: "Example virus",
            staxids: "1234",
            blastDbVersion: "db",
            snakemakeRunId: "run-1",
            mappedReads: 12,
            totalReads: 1000,
            statDbVersion: "stats-1",
            adjustedTaxid: "1234",
            adjustmentMethod: "dominant",
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            hitRank: 1,
            readsPerBillion: 12_000_000
        )

        let databaseURL = bundleURL.appendingPathComponent("nvd.sqlite")
        database = try NvdDatabase.create(
            at: databaseURL,
            hits: duplicateContigs ? [hit, duplicateHit] : [hit],
            samples: [
                NvdSampleMetadata(
                    sampleId: "sample1",
                    bamPath: "sample1.bam",
                    fastaPath: fastaRelativePath,
                    totalReads: 1000,
                    contigCount: 1,
                    hitCount: 1
                ),
            ] + (duplicateContigs ? [
                NvdSampleMetadata(
                    sampleId: "sample2",
                    bamPath: "sample2.bam",
                    fastaPath: secondFastaRelativePath,
                    totalReads: 1000,
                    contigCount: 1,
                    hitCount: 1
                ),
            ] : [])
        )

        manifest = NvdManifest(
            experiment: "exp-1",
            sampleCount: duplicateContigs ? 2 : 1,
            contigCount: duplicateContigs ? 2 : 1,
            hitCount: duplicateContigs ? 2 : 1,
            blastDbVersion: "db",
            snakemakeRunId: "run-1",
            sourceDirectoryPath: rootURL.path,
            samples: [
                NvdSampleSummary(
                    sampleId: "sample1",
                    contigCount: 1,
                    hitCount: 1,
                    totalReads: 1000,
                    bamRelativePath: "sample1.bam",
                    fastaRelativePath: fastaRelativePath
                ),
            ] + (duplicateContigs ? [
                NvdSampleSummary(
                    sampleId: "sample2",
                    contigCount: 1,
                    hitCount: 1,
                    totalReads: 1000,
                    bamRelativePath: "sample2.bam",
                    fastaRelativePath: secondFastaRelativePath
                ),
            ] : []),
            cachedTopContigs: nil
        )
    }
}
