import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

final class MappingDocumentStateBuilderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-document-state-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testBuildResolvesProjectLinksAndIncludesProvenanceContext() throws {
        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let inputFASTQ = projectURL.appendingPathComponent("Inputs/reads.fastq")
        let referenceFASTA = projectURL.appendingPathComponent("References/reference.fa")
        let sourceBundle = projectURL.appendingPathComponent("Sources/source.lungfishref", isDirectory: true)
        let outputDirectory = projectURL.appendingPathComponent("Analyses/sample-1", isDirectory: true)
        let viewerBundle = outputDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)

        try FileManager.default.createDirectory(at: inputFASTQ.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceFASTA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data().write(to: inputFASTQ)
        try ">chr1\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)

        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [inputFASTQ],
            referenceFASTAURL: referenceFASTA,
            sourceReferenceBundleURL: sourceBundle,
            projectURL: projectURL,
            outputDirectory: outputDirectory,
            sampleName: "sample",
            pairedEnd: false,
            threads: 8,
            includeSecondary: false,
            includeSupplementary: false,
            minimumMappingQuality: 17,
            advancedArguments: ["--eqx"]
        )

        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            sourceReferenceBundleURL: sourceBundle,
            viewerBundleURL: viewerBundle,
            bamURL: outputDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: outputDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 100,
            mappedReads: 91,
            unmappedReads: 9,
            wallClockSeconds: 12.5,
            contigs: []
        )

        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: try MappingProvenance.mapperInvocation(
                for: request,
                referenceLocator: ReferenceLocator(
                    referenceURL: referenceFASTA,
                    indexPrefixURL: outputDirectory.appendingPathComponent("reference-index")
                )
            ),
            normalizationInvocations: MappingProvenance.normalizationInvocations(
                rawAlignmentURL: outputDirectory.appendingPathComponent("sample.raw.sam"),
                outputDirectory: outputDirectory,
                sampleName: request.sampleName,
                threads: request.threads,
                minimumMappingQuality: request.minimumMappingQuality,
                includeSecondary: request.includeSecondary,
                includeSupplementary: request.includeSupplementary
            ),
            mapperVersion: "2.0.0",
            samtoolsVersion: "1.21"
        )

        let state = MappingDocumentStateBuilder.build(
            result: result,
            provenance: provenance,
            projectURL: projectURL
        )

        XCTAssertEqual(state.title, "sample-1")
        XCTAssertEqual(state.subtitle, "minimap2 • Oxford Nanopore • 91.0% mapped")
        XCTAssertEqual(state.sourceData, [
            .projectLink(name: "reads.fastq", targetURL: inputFASTQ.standardizedFileURL),
            .projectLink(name: "Source Reference Bundle", targetURL: sourceBundle.standardizedFileURL),
            .projectLink(name: "Reference FASTA", targetURL: referenceFASTA.standardizedFileURL)
        ])
        XCTAssertEqual(state.contextRows.first?.0, "Mapper")
        XCTAssertEqual(state.contextRows.first?.1, "minimap2")
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Preset" && $0.1 == "Oxford Nanopore" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Sample Name" && $0.1 == "sample" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Threads" && $0.1 == "8" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Minimum MAPQ" && $0.1 == "17" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Include Secondary" && $0.1 == "No" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Include Supplementary" && $0.1 == "No" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Advanced Options" && $0.1 == "--eqx" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Mapper Version" && $0.1 == "2.0.0" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "Samtools Version" && $0.1 == "1.21" }))
        XCTAssertTrue(state.contextRows.contains(where: { $0.0 == "samtools index" }))
        XCTAssertEqual(state.artifactRows.map(\.label), [
            "Sorted BAM",
            "BAM Index",
            "Viewer Bundle",
            "Mapping Result",
            "Legacy Alignment Result",
            "Mapping Provenance"
        ])
    }

    func testBuildFallsBackDeterministicallyWithoutProvenance() throws {
        let outputDirectory = tempRoot.appendingPathComponent("legacy-result", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: nil,
            bamURL: outputDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: outputDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 0,
            mappedReads: 0,
            unmappedReads: 0,
            wallClockSeconds: 0.5,
            contigs: []
        )

        let state = MappingDocumentStateBuilder.build(
            result: result,
            provenance: nil,
            projectURL: nil
        )

        XCTAssertEqual(state.contextRows.first?.0, "Provenance")
        XCTAssertEqual(state.contextRows.first?.1, "Unavailable")
        XCTAssertEqual(state.sourceData, [
            .missing(name: "FASTQ Inputs", originalPath: nil),
            .missing(name: "Source Reference Bundle", originalPath: nil),
            .missing(name: "Reference FASTA", originalPath: nil)
        ])
        XCTAssertEqual(state.subtitle, "minimap2 • Short-read • 0.0% mapped")
        XCTAssertNil(state.artifactRows[2].fileURL)
        XCTAssertEqual(state.artifactRows.last?.fileURL?.lastPathComponent, MappingProvenance.filename)
    }

    func testBuildIncludesFilteredAlignmentsArtifactWhenDerivedFolderExists() throws {
        let outputDirectory = tempRoot.appendingPathComponent("mapping-run", isDirectory: true)
        let viewerBundle = outputDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        let filteredDirectory = viewerBundle.appendingPathComponent("alignments/filtered", isDirectory: true)
        try FileManager.default.createDirectory(at: filteredDirectory, withIntermediateDirectories: true)

        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundle,
            bamURL: outputDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: outputDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 12,
            mappedReads: 10,
            unmappedReads: 2,
            wallClockSeconds: 1.2,
            contigs: []
        )

        let state = MappingDocumentStateBuilder.build(
            result: result,
            provenance: nil,
            projectURL: nil
        )

        XCTAssertTrue(
            state.artifactRows.contains(
                .init(label: "Filtered Alignments", fileURL: filteredDirectory)
            )
        )
    }

    func testSourceResolverPrefersProjectLinksAndFallsBackToFilesystem() throws {
        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let projectFile = projectURL.appendingPathComponent("Inputs/reads.fastq")
        let externalFile = tempRoot.appendingPathComponent("external.fastq")

        try FileManager.default.createDirectory(at: projectFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data().write(to: projectFile)
        try Data().write(to: externalFile)

        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "reads.fastq",
                path: projectFile.path,
                projectURL: projectURL
            ),
            .projectLink(name: "reads.fastq", targetURL: projectFile.standardizedFileURL)
        )
        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: externalFile.lastPathComponent,
                path: externalFile.path,
                projectURL: projectURL
            ),
            .filesystemLink(name: externalFile.lastPathComponent, fileURL: externalFile.standardizedFileURL)
        )
        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "missing.fastq",
                path: tempRoot.appendingPathComponent("missing.fastq").path,
                projectURL: projectURL
            ),
            .missing(name: "missing.fastq", originalPath: tempRoot.appendingPathComponent("missing.fastq").path)
        )
    }

    func testSourceResolverTargetsEnclosingBundlesForProjectFilesInsideFASTQAndReferenceBundles() throws {
        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let fastqBundle = projectURL.appendingPathComponent("Imports/sample.lungfishfastq", isDirectory: true)
        let fastqFile = fastqBundle.appendingPathComponent("reads.fastq.gz")
        let referenceBundle = projectURL.appendingPathComponent("References/reference.lungfishref", isDirectory: true)
        let referenceFASTA = referenceBundle.appendingPathComponent("reference.fa")

        try FileManager.default.createDirectory(at: fastqBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)
        try Data().write(to: fastqFile)
        try ">chr1\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "reads.fastq.gz",
                path: fastqFile.path,
                projectURL: projectURL
            ),
            .projectLink(name: "reads.fastq.gz", targetURL: fastqBundle.standardizedFileURL)
        )
        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "Reference FASTA",
                path: referenceFASTA.path,
                projectURL: projectURL
            ),
            .projectLink(name: "Reference FASTA", targetURL: referenceBundle.standardizedFileURL)
        )
    }

    func testSourceResolverTargetsAnalysisRowsForReferenceBundlesNestedInsideAnalyses() throws {
        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let analysisDirectory = projectURL.appendingPathComponent(
            "Analyses/spades-2026-01-15T13-00-00",
            isDirectory: true
        )
        let referenceBundle = analysisDirectory.appendingPathComponent("NC_045512.lungfishref", isDirectory: true)
        let referenceFASTA = referenceBundle.appendingPathComponent("genome/sequence.fa")

        try FileManager.default.createDirectory(at: referenceFASTA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ">chr1\nACGT\n".write(to: referenceFASTA, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "Source Reference Bundle",
                path: referenceBundle.path,
                projectURL: projectURL
            ),
            .projectLink(name: "Source Reference Bundle", targetURL: analysisDirectory.standardizedFileURL)
        )
        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "Reference FASTA",
                path: referenceFASTA.path,
                projectURL: projectURL
            ),
            .projectLink(name: "Reference FASTA", targetURL: analysisDirectory.standardizedFileURL)
        )
    }

    func testSourceResolverUsesCopiedBundleOriginPathForCanonicalReferenceNavigation() throws {
        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let sourceBundle = projectURL.appendingPathComponent("Downloads/NC_045512.lungfishref", isDirectory: true)
        let analysisDirectory = projectURL.appendingPathComponent(
            "Analyses/minimap2-2026-01-15T13-00-00",
            isDirectory: true
        )
        let copiedBundle = analysisDirectory.appendingPathComponent("NC_045512.lungfishref", isDirectory: true)
        let copiedFASTA = copiedBundle.appendingPathComponent("genome/sequence.fa.gz")

        try createReferenceBundle(
            at: sourceBundle,
            identifier: "com.ncbi.nc-045512",
            originBundlePath: nil
        )
        try createReferenceBundle(
            at: copiedBundle,
            identifier: "com.ncbi.nc-045512",
            originBundlePath: "@/Downloads/NC_045512.lungfishref"
        )

        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "Source Reference Bundle",
                path: copiedBundle.path,
                projectURL: projectURL
            ),
            .projectLink(name: "Source Reference Bundle", targetURL: sourceBundle.standardizedFileURL)
        )
        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "Reference FASTA",
                path: copiedFASTA.path,
                projectURL: projectURL
            ),
            .projectLink(name: "Reference FASTA", targetURL: sourceBundle.standardizedFileURL)
        )
    }

    func testSourceResolverRecoversCanonicalReferenceFromLegacyMappingSidecars() throws {
        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let sourceBundle = projectURL.appendingPathComponent("Downloads/TestGenome.lungfishref", isDirectory: true)
        let legacyAnalysis = projectURL.appendingPathComponent(
            "Analyses/minimap2-2026-01-15T13-00-00",
            isDirectory: true
        )
        let copiedBundle = legacyAnalysis.appendingPathComponent("TestGenome.lungfishref", isDirectory: true)
        let copiedFASTA = copiedBundle.appendingPathComponent("genome/sequence.fa.gz")

        try createReferenceBundle(
            at: sourceBundle,
            identifier: "com.example.testgenome",
            originBundlePath: nil
        )
        try createReferenceBundle(
            at: copiedBundle,
            identifier: "com.example.testgenome",
            originBundlePath: nil
        )

        let mappingResult = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: sourceBundle,
            viewerBundleURL: copiedBundle,
            bamURL: legacyAnalysis.appendingPathComponent("test.sorted.bam"),
            baiURL: legacyAnalysis.appendingPathComponent("test.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
        try Data().write(to: mappingResult.bamURL)
        try Data().write(to: mappingResult.baiURL)
        try mappingResult.save(to: legacyAnalysis)

        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "Source Reference Bundle",
                path: copiedBundle.path,
                projectURL: projectURL
            ),
            .projectLink(name: "Source Reference Bundle", targetURL: sourceBundle.standardizedFileURL)
        )
        XCTAssertEqual(
            MappingInspectorSourceResolver.resolve(
                name: "Reference FASTA",
                path: copiedFASTA.path,
                projectURL: projectURL
            ),
            .projectLink(name: "Reference FASTA", targetURL: sourceBundle.standardizedFileURL)
        )
    }

    private func createReferenceBundle(
        at bundleURL: URL,
        identifier: String,
        originBundlePath: String?
    ) throws {
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try Data().write(to: genomeDirectory.appendingPathComponent("sequence.fa.gz"))

        let manifest = BundleManifest(
            name: bundleURL.deletingPathExtension().lastPathComponent,
            identifier: identifier,
            description: nil,
            originBundlePath: originBundlePath,
            source: SourceInfo(
                organism: "Severe acute respiratory syndrome coronavirus 2",
                assembly: "NC_045512",
                assemblyAccession: "NC_045512",
                database: "NCBI"
            ),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 29_903,
                chromosomes: [
                    ChromosomeInfo(
                        name: "NC_045512",
                        length: 29_903,
                        offset: 0,
                        lineBases: 80,
                        lineWidth: 81,
                        aliases: []
                    )
                ]
            )
        )
        try manifest.save(to: bundleURL)
    }
}
