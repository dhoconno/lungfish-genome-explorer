import XCTest
@testable import LungfishCore
@testable import LungfishIO

final class ReferenceSequenceScannerTests: XCTestCase {

    private func makeTempProject() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RefScanTests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempDir.appendingPathComponent("project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        return projectURL
    }

    // MARK: - scanAll

    func testMHCReferenceBundleIsOneNamedChoiceWithoutSourceSnapshots() async throws {
        for folder in ["Reference allele databases", ReferenceSequenceFolder.folderName] {
            let project = try makeTempProject()
            defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
            let bundle = project.appendingPathComponent(folder)
                .appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
            let fasta = try makeMHCReferenceBundle(at: bundle)
            let standalone = project.appendingPathComponent("Other reference.fasta")
            try ">other\nTGCA\n".write(to: standalone, atomically: true, encoding: .utf8)

            let synchronous = ReferenceSequenceScanner.scanAll(in: project)
            var asynchronous: [ReferenceCandidate] = []
            for await candidate in ReferenceSequenceScanner.scan(in: project) {
                asynchronous.append(candidate)
            }
            for candidates in [synchronous, asynchronous] {
                XCTAssertEqual(candidates.count, 2, "Only the MHC bundle and the genuine standalone reference belong in the picker")
                let candidate = try XCTUnwrap(candidates.first { $0.fastaURL.resolvingSymlinksInPath() == fasta.resolvingSymlinksInPath() })
                XCTAssertEqual(candidate.sourceBundleURL?.resolvingSymlinksInPath(), bundle.resolvingSymlinksInPath())
                XCTAssertEqual(candidate.displayName, "MCM MHC MiSeq — 22 September 2026")
                XCTAssertTrue(candidates.contains { $0.fastaURL.resolvingSymlinksInPath() == standalone.resolvingSymlinksInPath() })
                XCTAssertFalse(candidates.contains { $0.displayName == "reference" })
            }
        }
    }

    func testBrokenMHCBundleDoesNotExposeArchivedReferencesAsFallbacks() async throws {
        let project = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let bundle = project.appendingPathComponent("Broken.lungfishmhcref", isDirectory: true)
        let fasta = try makeMHCReferenceBundle(at: bundle)
        try FileManager.default.removeItem(at: fasta)
        XCTAssertTrue(ReferenceSequenceScanner.scanAll(in: project).isEmpty)
        var candidates: [ReferenceCandidate] = []
        for await candidate in ReferenceSequenceScanner.scan(in: project) { candidates.append(candidate) }
        XCTAssertTrue(candidates.isEmpty)
    }

    private func makeMHCReferenceBundle(at bundle: URL) throws -> URL {
        let fasta = bundle.appendingPathComponent("reference/Embedded.lungfishref/reference.fasta")
        let retainedSource = bundle.appendingPathComponent("sources/prepared/reference.fasta")
        for path in [fasta, retainedSource] {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ">allele\nACGT\n".write(to: path, atomically: true, encoding: .utf8)
        }
        try MHCAmpliconReferenceBundle.writeManifest(.init(
            name: "MCM MHC MiSeq — 22 September 2026",
            referenceFastaPath: "reference/Embedded.lungfishref/reference.fasta",
            haplotypeDefinitionPaths: [], defaultHaplotypeDefinitionID: nil,
            metrics: .init(referenceCount: 1, haplotypeDefinitionCount: 0),
            createdAt: "2026-09-22T00:00:00Z"
        ), to: bundle)
        return fasta
    }

    func testScanAllReturnsEmptyForEmptyProject() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllFindsProjectReferences() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a reference
        let fastaURL = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: fastaURL, into: projectURL, displayName: "Test Ref")

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.displayName, "Test Ref")
        XCTAssertEqual(results.first?.sourceCategory, .projectReferences)
    }

    func testScanAllFindsStandaloneFASTAFiles() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a standalone FASTA directly in the project
        let fastaURL = projectURL.appendingPathComponent("standalone.fasta")
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        let standalone = results.filter { $0.sourceCategory == .standaloneFASTAFiles }
        XCTAssertEqual(standalone.count, 1)
        XCTAssertEqual(standalone.first?.displayName, "standalone")
    }

    func testScanAllFindsFaGzFiles() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a .fa.gz file (just the extension matters for discovery)
        let fastaURL = projectURL.appendingPathComponent("genome.fa.gz")
        try Data().write(to: fastaURL)

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        let standalone = results.filter { $0.sourceCategory == .standaloneFASTAFiles }
        XCTAssertEqual(standalone.count, 1)
        XCTAssertEqual(standalone.first?.displayName, "genome.fa")
    }

    func testScanAllSortsByCategory() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create standalone FASTA
        try ">s\nA\n".write(
            to: projectURL.appendingPathComponent("standalone.fasta"),
            atomically: true, encoding: .utf8
        )

        // Create project reference
        let tmpFasta = projectURL.deletingLastPathComponent().appendingPathComponent("ref.fasta")
        try ">s\nA\n".write(to: tmpFasta, atomically: true, encoding: .utf8)
        try ReferenceSequenceFolder.importReference(from: tmpFasta, into: projectURL, displayName: "Project Ref")

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertEqual(results.count, 2)
        // Project references should come first
        XCTAssertEqual(results.first?.sourceCategory, .projectReferences)
        XCTAssertEqual(results.last?.sourceCategory, .standaloneFASTAFiles)
    }

    func testScanAllSkipsLungfishfastqBundles() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create a .lungfishfastq directory with a FASTA inside (shouldn't be scanned)
        let bundleDir = projectURL.appendingPathComponent("data.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try ">s\nA\n".write(
            to: bundleDir.appendingPathComponent("ref.fasta"),
            atomically: true, encoding: .utf8
        )

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertTrue(results.isEmpty)
    }

    func testScanAllLimitsRecursionDepth() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        // Create deeply nested FASTA (depth 6 — beyond limit)
        var deepDir = projectURL
        for i in 0..<6 {
            deepDir = deepDir.appendingPathComponent("level\(i)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try ">s\nA\n".write(
            to: deepDir.appendingPathComponent("deep.fasta"),
            atomically: true, encoding: .utf8
        )

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        XCTAssertTrue(results.isEmpty, "Should not find FASTA beyond depth limit")
    }

    func testScanAllUsesManifestedGenomePathAndSkipsAppleDoubleSidecars() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let bundleURL = projectURL
            .appendingPathComponent("Zhang pan-genomes", isDirectory: true)
            .appendingPathComponent("MF0214_2.lungfishref", isDirectory: true)
        let genomeDirectory = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)

        let fastaURL = genomeDirectory.appendingPathComponent("sequence.fa.gz")
        let appleDoubleURL = genomeDirectory.appendingPathComponent("._sequence.fa.gz")
        let fastaIndexURL = genomeDirectory.appendingPathComponent("sequence.fa.gz.fai")
        try Data("gzip-placeholder".utf8).write(to: fastaURL)
        try Data("appledouble".utf8).write(to: appleDoubleURL)
        try Data("index-placeholder".utf8).write(to: fastaIndexURL)

        let manifest = BundleManifest(
            name: "MF0214_2",
            identifier: "org.lungfish.MF0214_2",
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 0,
                chromosomes: []
            )
        )
        try manifest.save(to: bundleURL)

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        let candidate = try XCTUnwrap(results.first { $0.displayName == "MF0214_2" })

        XCTAssertEqual(candidate.sourceCategory, .genomeBundles)
        XCTAssertEqual(candidate.fastaURL.standardizedFileURL, fastaURL.standardizedFileURL)
        XCTAssertFalse(candidate.fastaURL.lastPathComponent.hasPrefix("._"))
    }

    func testScanAllUsesManifestGenomePathOutsideLegacyGenomeDirectory() throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let bundleURL = projectURL
            .appendingPathComponent("Reference Bundles", isDirectory: true)
            .appendingPathComponent("CustomLayout.lungfishref", isDirectory: true)
        let sequenceDirectory = bundleURL.appendingPathComponent("assemblies", isDirectory: true)
        try FileManager.default.createDirectory(at: sequenceDirectory, withIntermediateDirectories: true)

        let fastaURL = sequenceDirectory.appendingPathComponent("custom-layout.fa.gz")
        let fastaIndexURL = sequenceDirectory.appendingPathComponent("custom-layout.fa.gz.fai")
        try Data("gzip-placeholder".utf8).write(to: fastaURL)
        try Data("index-placeholder".utf8).write(to: fastaIndexURL)

        let manifest = BundleManifest(
            name: "CustomLayout",
            identifier: "org.lungfish.CustomLayout",
            source: SourceInfo(organism: "Test organism", assembly: "Custom layout"),
            genome: GenomeInfo(
                path: "assemblies/custom-layout.fa.gz",
                indexPath: "assemblies/custom-layout.fa.gz.fai",
                totalLength: 0,
                chromosomes: []
            )
        )
        try manifest.save(to: bundleURL)

        let results = ReferenceSequenceScanner.scanAll(in: projectURL)
        let candidate = results.first { $0.displayName == "CustomLayout" }

        XCTAssertEqual(candidate?.fastaURL.standardizedFileURL, fastaURL.standardizedFileURL)
        XCTAssertEqual(candidate?.sourceCategory, .genomeBundles)
    }

    // MARK: - inferRole

    func testInferRolePrimer() {
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/primers.fasta")), "primer")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/oligo-set.fa")), "primer")
    }

    func testInferRoleContaminant() {
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/contaminants.fasta")), "contaminant")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/host-genome.fa")), "contaminant")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/phix174.fasta")), "contaminant")
    }

    func testInferRoleReference() {
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/genome.fasta")), "reference")
        XCTAssertEqual(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/my-reference.fa")), "reference")
    }

    func testInferRoleUnknown() {
        XCTAssertNil(ReferenceSequenceScanner.inferRole(for: URL(fileURLWithPath: "/sample-data.fasta")))
    }

    // MARK: - AsyncStream scan

    func testAsyncStreamScanFindsReferences() async throws {
        let projectURL = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        try ">s\nA\n".write(
            to: projectURL.appendingPathComponent("ref.fasta"),
            atomically: true, encoding: .utf8
        )

        var found: [ReferenceCandidate] = []
        for await candidate in ReferenceSequenceScanner.scan(in: projectURL) {
            found.append(candidate)
        }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.displayName, "ref")
    }
}
