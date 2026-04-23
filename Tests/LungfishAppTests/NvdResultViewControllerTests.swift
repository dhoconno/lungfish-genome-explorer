import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class NvdResultViewControllerTests: XCTestCase {
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
}

private struct NvdMenuFixture {
    let rootURL: URL
    let bundleURL: URL
    let manifest: NvdManifest
    let database: NvdDatabase

    init() throws {
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

        let databaseURL = bundleURL.appendingPathComponent("nvd.sqlite")
        database = try NvdDatabase.create(
            at: databaseURL,
            hits: [hit],
            samples: [
                NvdSampleMetadata(
                    sampleId: "sample1",
                    bamPath: "sample1.bam",
                    fastaPath: fastaRelativePath,
                    totalReads: 1000,
                    contigCount: 1,
                    hitCount: 1
                )
            ]
        )

        manifest = NvdManifest(
            experiment: "exp-1",
            sampleCount: 1,
            contigCount: 1,
            hitCount: 1,
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
                )
            ],
            cachedTopContigs: nil
        )
    }
}
