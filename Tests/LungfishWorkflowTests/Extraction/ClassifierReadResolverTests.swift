// ClassifierReadResolverTests.swift — Unit tests for the unified classifier extraction actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishWorkflow
import LungfishIO
import LungfishCore
import LungfishTestSupport

final class ClassifierReadResolverTests: XCTestCase {

    // MARK: - resolveProjectRoot

    func testResolveProjectRoot_walksUpToLungfishMarker() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("resolver-root-\(UUID().uuidString)")
        let lungfishMarker = tempRoot.appendingPathComponent(".lungfish")
        let analyses = tempRoot.appendingPathComponent("analyses")
        let resultDir = analyses.appendingPathComponent("esviritu-20260401")
        try fm.createDirectory(at: lungfishMarker, withIntermediateDirectories: true)
        try fm.createDirectory(at: resultDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fakeResultPath = resultDir.appendingPathComponent("results.sqlite")
        fm.createFile(atPath: fakeResultPath.path, contents: Data())

        let resolved = ClassifierReadResolver.resolveProjectRoot(from: fakeResultPath)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            tempRoot.standardizedFileURL.path,
            "Expected to walk up to the .lungfish project root"
        )
    }

    func testResolveProjectRoot_noMarker_fallsBackToParentDirectory() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("resolver-nomarker-\(UUID().uuidString)")
        let resultDir = tempRoot.appendingPathComponent("loose-results")
        try fm.createDirectory(at: resultDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fakeResultPath = resultDir.appendingPathComponent("results.sqlite")
        fm.createFile(atPath: fakeResultPath.path, contents: Data())

        let resolved = ClassifierReadResolver.resolveProjectRoot(from: fakeResultPath)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            resultDir.standardizedFileURL.path,
            "Expected fallback to the result path's parent directory"
        )
    }

    func testResolveProjectRoot_directoryInput_walksUpFromDirectoryItself() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("resolver-dir-\(UUID().uuidString)")
        let lungfishMarker = tempRoot.appendingPathComponent(".lungfish")
        let resultDir = tempRoot.appendingPathComponent("analyses/esviritu-20260401")
        try fm.createDirectory(at: lungfishMarker, withIntermediateDirectories: true)
        try fm.createDirectory(at: resultDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let resolved = ClassifierReadResolver.resolveProjectRoot(from: resultDir)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            tempRoot.standardizedFileURL.path
        )
    }

    // MARK: - estimateReadCount

    func testEstimateReadCount_emptySelection_returnsZero() async throws {
        let resolver = ClassifierReadResolver()
        let count = try await resolver.estimateReadCount(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/nonexistent.sqlite"),
            selections: [],
            options: ExtractionOptions()
        )
        XCTAssertEqual(count, 0)
    }

    func testEstimateReadCount_allEmptySelectors_returnsZero() async throws {
        let resolver = ClassifierReadResolver()
        let count = try await resolver.estimateReadCount(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/nonexistent.sqlite"),
            selections: [
                ClassifierRowSelector(sampleId: "S1", accessions: [], taxIds: [])
            ],
            options: ExtractionOptions()
        )
        XCTAssertEqual(count, 0)
    }

    func testEstimateKraken2ReadCountLoadsPerSampleBatchResult() async throws {
        let sampleResult = try kraken2MiniResultPath()
        let classResult = try ClassificationResult.load(from: sampleResult)
        let taxon = try XCTUnwrap(
            classResult.tree.allNodes().first { $0.taxId != 0 && $0.readsClade > 0 },
            "kraken2-mini fixture has no taxa with classified reads"
        )

        let estimate = try await ClassifierReadResolver().estimateReadCount(
            tool: .kraken2,
            resultPath: sampleResult.deletingLastPathComponent(),
            selections: [
                ClassifierRowSelector(
                    sampleId: sampleResult.lastPathComponent,
                    accessions: [],
                    taxIds: [taxon.taxId]
                )
            ],
            options: ExtractionOptions()
        )

        XCTAssertEqual(estimate, taxon.readsClade)
    }

    func testEstimateKraken2ReadCountDoesNotDoubleCountSelectedDescendant() async throws {
        let sampleResult = try kraken2MiniResultPath()
        let classResult = try ClassificationResult.load(from: sampleResult)
        let ancestor = try XCTUnwrap(classResult.tree.node(taxId: 1))
        let descendant = try XCTUnwrap(classResult.tree.node(taxId: 1270))
        var currentParent = descendant.parent
        var isRealAncestor = false
        while let parent = currentParent {
            if parent === ancestor {
                isRealAncestor = true
                break
            }
            currentParent = parent.parent
        }
        XCTAssertTrue(isRealAncestor, "Fixture nodes must be related through TaxonNode.parent")
        XCTAssertGreaterThan(descendant.readsClade, 0)

        let estimate = try await ClassifierReadResolver().estimateReadCount(
            tool: .kraken2,
            resultPath: sampleResult,
            selections: [
                ClassifierRowSelector(
                    sampleId: nil,
                    accessions: [],
                    taxIds: [ancestor.taxId, descendant.taxId]
                )
            ],
            options: ExtractionOptions()
        )

        XCTAssertEqual(estimate, ancestor.readsClade)
    }

    /// BIO's ruling on Phase 2.12 lane 12.11, section 2. Genus 10 holds one read of its own and three in
    /// its species, so the exact estimate is 1, the reads the run will take, and the children estimate 4.
    func testAnExactSelectionEstimatesOnlyTheTaxonsOwnReads() async throws {
        let directory = try TestTempDirectory.make(prefix: "exact-estimate")
        defer { TestTempDirectory.cleanup(directory) }
        let kreport = directory.appendingPathComponent("classification.kreport")
        try [
            "100.00\t4\t0\tR\t1\troot", "100.00\t4\t1\tG\t10\t  Genus A",
            " 50.00\t2\t2\tS\t11\t    Species A1", " 25.00\t1\t1\tS\t12\t    Species A2",
        ].joined(separator: "\n").appending("\n").write(to: kreport, atomically: true, encoding: .utf8)
        let kraken = directory.appendingPathComponent("classification.kraken")
        try "C\tg1\t10\t10\t10:3\n".write(to: kraken, atomically: true, encoding: .utf8)
        try ClassificationResult(
            config: ClassificationConfig(
                inputFiles: [URL(string: "reads.fastq")!], isPairedEnd: false, databaseName: "Viral",
                databasePath: URL(string: ".")!, outputDirectory: URL(string: ".")!
            ),
            tree: try KreportParser.parse(url: kreport), reportURL: kreport, outputURL: kraken,
            brackenURL: nil, runtime: 1, toolVersion: "2.17.1", provenanceId: nil
        ).save(to: directory)

        var estimates: [TaxonScope: Int] = [:]
        for scope in TaxonScope.allCases {
            estimates[scope] = try await ClassifierReadResolver().estimateReadCount(
                tool: .kraken2,
                resultPath: directory,
                selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [10])],
                options: ExtractionOptions(taxonScope: scope)
            )
        }
        XCTAssertEqual(estimates, [.exact: 1, .children: 4])
    }

    // MARK: - resolveBAMURL (per-tool)

    /// Helper: creates a throwaway directory layout that looks like a real
    /// classifier result for the purpose of BAM-path resolution only.
    /// Does NOT create a functional BAM — just a file at the expected path
    /// so `FileManager.fileExists` returns true.
    private func makeFakeClassifierResult(
        tool: ClassifierTool,
        sampleId: String
    ) throws -> (resultPath: URL, expectedBAM: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fake-\(tool.rawValue)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        switch tool {
        case .esviritu:
            let bam = root.appendingPathComponent("\(sampleId).sorted.bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))  // fake BGZF magic
            return (resultPath: root.appendingPathComponent("esviritu.sqlite"), expectedBAM: bam)

        case .taxtriage:
            let subdir = root.appendingPathComponent("minimap2")
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            let bam = subdir.appendingPathComponent("\(sampleId).bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))
            return (resultPath: root.appendingPathComponent("taxtriage.sqlite"), expectedBAM: bam)

        case .naomgs:
            let dbURL = root.appendingPathComponent("naomgs.sqlite")
            var db: OpaquePointer?
            guard sqlite3_open_v2(
                dbURL.path,
                &db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK else {
                XCTFail("Failed to create NAO-MGS test database")
                throw NSError(domain: "ClassifierReadResolverTests", code: 1)
            }
            defer { sqlite3_close(db) }

            sqlite3_exec(
                db,
                """
                CREATE TABLE taxon_summaries (
                    sample TEXT NOT NULL,
                    tax_id INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    hit_count INTEGER NOT NULL,
                    unique_read_count INTEGER NOT NULL,
                    avg_identity REAL NOT NULL,
                    avg_bit_score REAL NOT NULL,
                    avg_edit_distance REAL NOT NULL,
                    pcr_duplicate_count INTEGER NOT NULL,
                    accession_count INTEGER NOT NULL,
                    top_accessions_json TEXT NOT NULL,
                    bam_path TEXT,
                    bam_index_path TEXT,
                    PRIMARY KEY (sample, tax_id)
                );
                """,
                nil,
                nil,
                nil
            )

            let subdir = root.appendingPathComponent("bams")
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            let bam = subdir.appendingPathComponent("\(sampleId).bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))
            sqlite3_exec(
                db,
                """
                INSERT INTO taxon_summaries (
                    sample, tax_id, name, hit_count, unique_read_count,
                    avg_identity, avg_bit_score, avg_edit_distance,
                    pcr_duplicate_count, accession_count, top_accessions_json,
                    bam_path, bam_index_path
                ) VALUES (
                    '\(sampleId)', 123, 'Test virus', 1, 1,
                    99.0, 100.0, 0.0,
                    0, 1, '["ACC001"]',
                    'bams/\(sampleId).bam', 'bams/\(sampleId).bam.bai'
                );
                """,
                nil,
                nil,
                nil
            )
            return (resultPath: dbURL, expectedBAM: bam)

        case .nvd:
            let bamDir = root.appendingPathComponent("bam")
            try fm.createDirectory(at: bamDir, withIntermediateDirectories: true)
            let bam = bamDir.appendingPathComponent("\(sampleId).filtered.bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))
            return (resultPath: root.appendingPathComponent("nvd.sqlite"), expectedBAM: bam)

        case .kraken2:
            fatalError("kraken2 is not a BAM-backed tool")
        }
    }

    func testResolveBAMURL_esviritu_findsSiblingSortedBAM() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .esviritu, sampleId: "SRR123")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .esviritu,
            sampleId: "SRR123",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_taxtriage_findsMinimap2Subdir() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .taxtriage, sampleId: "S01")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .taxtriage,
            sampleId: "S01",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_naomgs_findsBamsSubdir() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .naomgs, sampleId: "S02")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .naomgs,
            sampleId: "S02",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_nvd_findsSiblingBAM() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .nvd, sampleId: "SampleX")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .nvd,
            sampleId: "SampleX",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_missingBAM_throwsBamNotFound() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let resultPath = root.appendingPathComponent("esviritu.sqlite")
        let resolver = ClassifierReadResolver()

        do {
            _ = try await resolver.testingResolveBAMURL(
                tool: .esviritu,
                sampleId: "SRR999",
                resultPath: resultPath
            )
            XCTFail("Expected bamNotFound error")
        } catch ClassifierExtractionError.bamNotFound(let sampleId) {
            XCTAssertEqual(sampleId, "SRR999")
        } catch {
            XCTFail("Expected bamNotFound, got \(error)")
        }
    }

    func testResolveBAMURL_kraken2_throwsUnsupportedBAMTool() async throws {
        let resolver = ClassifierReadResolver()

        do {
            _ = try await resolver.testingResolveBAMURL(
                tool: .kraken2,
                sampleId: nil,
                resultPath: URL(fileURLWithPath: "/tmp/kraken2-result")
            )
            XCTFail("Expected unsupportedBAMTool error")
        } catch ClassifierExtractionError.unsupportedBAMTool(let tool) {
            XCTAssertEqual(tool, .kraken2)
        } catch {
            XCTFail("Expected unsupportedBAMTool, got \(error)")
        }
    }

    // MARK: - resolveBAMURL, the EsViritu database row (decision C4, row 434)

    /// A one-folder EsViritu result in a `TestTempDirectory`. `esviritu.sqlite` holds one detection row for
    /// `sampleId` that records `bamPath`. The caller writes the BAM files.
    private func makeEsVirituResult(
        sampleId: String,
        bamPath: String?
    ) throws -> (root: URL, resultPath: URL) {
        let root = try TestTempDirectory.make(prefix: "esviritu-recorded-bam")
        let resultPath = root.appendingPathComponent("esviritu.sqlite")
        try EsVirituDatabase.create(
            at: resultPath,
            rows: [EsVirituDetectionRow(
                sample: sampleId, virusName: "Test virus", description: nil, contigLength: 1_000, segment: nil,
                accession: "NC_000001.1", assembly: "ASM_\(sampleId)", assemblyLength: 1_000, kingdom: nil,
                phylum: nil, tclass: nil, torder: nil, family: nil, genus: nil, species: nil, subspecies: nil,
                rpkmf: 1, readCount: 10, uniqueReads: 10, coveredBases: 900, meanCoverage: 5,
                avgReadIdentity: 0.99, pi: nil, filteredReadsInSample: 100,
                bamPath: bamPath, bamIndexPath: bamPath.map { $0 + ".bai" }
            )],
            metadata: ["tool": "test"]
        )
        return (root, resultPath)
    }

    /// Writes a stand-in BAM, which only has to exist, at `relativePath` under `root`.
    @discardableResult
    private func writeStandInBAM(_ relativePath: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x1F, 0x8B]).write(to: url)
        return url
    }

    /// The BAM the resolver picks for `sampleId` in the EsViritu result at `resultPath`.
    private func resolveEsVirituBAM(_ sampleId: String, resultPath: URL) async throws -> URL {
        try await ClassifierReadResolver().testingResolveBAMURL(
            tool: .esviritu,
            sampleId: sampleId,
            resultPath: resultPath
        )
    }

    /// Asserts that resolving `sampleId` ends in `bamNotFound` for that sample.
    private func assertEsVirituBAMNotFound(
        _ sampleId: String,
        resultPath: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let url = try await resolveEsVirituBAM(sampleId, resultPath: resultPath)
            XCTFail("Expected bamNotFound, resolved \(url.path)", file: file, line: line)
        } catch ClassifierExtractionError.bamNotFound(let notFound) {
            XCTAssertEqual(notFound, sampleId, file: file, line: line)
        } catch {
            XCTFail("Expected bamNotFound, got \(error)", file: file, line: line)
        }
    }

    /// Asserts that resolving `sampleId` is refused with the words for a BAM that links out of the result (U36).
    private func assertEsVirituBAMOutsideResult(
        _ sampleId: String,
        resultPath: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let url = try await resolveEsVirituBAM(sampleId, resultPath: resultPath)
            XCTFail("Expected a BAM outside the result, resolved \(url.path)", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.outsideResultMessage(sampleId), file: file, line: line)
        }
    }

    /// Asserts that `url` and `expected` name the same file, whatever symlinks (`/var` is `/private/var`) lead there.
    private func assertSameFile(
        _ url: URL,
        _ expected: URL,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            url.resolvingSymlinksInPath().path,
            expected.resolvingSymlinksInPath().path,
            message,
            file: file,
            line: line
        )
    }

    /// Row 434. A one-folder result leaves its BAM at `<root>/bams/<sample>.third.filt.sorted.bam`, which no
    /// layout lookup for a sample id reaches. The database row records that path.
    func testResolveBAMURL_esviritu_oneFolderResult_usesRecordedBAMPath() async throws {
        let recorded = "bams/S1.third.filt.sorted.bam"
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
        defer { TestTempDirectory.cleanup(root) }
        let bam = try writeStandInBAM(recorded, under: root)

        assertSameFile(try await resolveEsVirituBAM("S1", resultPath: resultPath), bam)
    }

    /// Every entry under `root`, hidden ones included, with the bytes of each file. A folder maps to empty data.
    private func resultTreeContents(_ root: URL) throws -> [String: Data] {
        var contents: [String: Data] = [:]
        for subpath in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(subpath)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            contents[subpath] = try isDirectory.boolValue ? Data() : Data(contentsOf: url)
        }
        return contents
    }

    /// UX 6. Resolving reads `esviritu.sqlite` and writes nothing in the result, with no journal, `-wal` or `-shm`
    /// file and no changed byte, whether the result path names the database or the folder.
    func testResolveBAMURL_esviritu_oneFolderResult_writesNothingInTheResult() async throws {
        let recorded = "bams/S1.third.filt.sorted.bam"
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
        defer { TestTempDirectory.cleanup(root) }
        let bam = try writeStandInBAM(recorded, under: root)
        let before = try resultTreeContents(root)

        assertSameFile(try await resolveEsVirituBAM("S1", resultPath: resultPath), bam)
        assertSameFile(try await resolveEsVirituBAM("S1", resultPath: root), bam, "a folder result path")

        XCTAssertEqual(try resultTreeContents(root), before)
    }

    /// A batch result records `<sample>/bams/...`, which the layout lookups also reach, so it still resolves.
    func testResolveBAMURL_esviritu_batchResult_usesRecordedBAMPath() async throws {
        let recorded = "S1/bams/S1.third.filt.sorted.bam"
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
        defer { TestTempDirectory.cleanup(root) }
        let bam = try writeStandInBAM(recorded, under: root)

        assertSameFile(try await resolveEsVirituBAM("S1", resultPath: resultPath), bam)
    }

    /// Decision C4 tries the recorded path first, so it wins over a BAM that a layout lookup also reaches.
    func testResolveBAMURL_esviritu_recordedPathBeatsLayoutLookups() async throws {
        let recorded = "bams/S1.third.filt.sorted.bam"
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
        defer { TestTempDirectory.cleanup(root) }
        let bam = try writeStandInBAM(recorded, under: root)
        try writeStandInBAM("S1/bams/S1.third.filt.sorted.bam", under: root)

        assertSameFile(try await resolveEsVirituBAM("S1", resultPath: resultPath), bam)
    }

    /// A recorded path that leaves the result root is not read, as a `..` step or as an absolute path. The
    /// resolver falls back to its layout lookups, which find the legacy BAM beside the database.
    func testResolveBAMURL_esviritu_recordedPathOutsideRoot_fallsBackToLayoutLookups() async throws {
        let outside = try TestTempDirectory.make(prefix: "esviritu-outside")
        defer { TestTempDirectory.cleanup(outside) }
        let outsideBAM = try writeStandInBAM("S1.third.filt.sorted.bam", under: outside)

        for recorded in ["../\(outside.lastPathComponent)/S1.third.filt.sorted.bam", outsideBAM.path] {
            let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
            defer { TestTempDirectory.cleanup(root) }
            let legacy = try writeStandInBAM("S1.sorted.bam", under: root)

            assertSameFile(try await resolveEsVirituBAM("S1", resultPath: resultPath), legacy, recorded)
        }
    }

    /// A row that records no path, a path with no file and a path that names a folder all fall back to the
    /// layout lookups.
    func testResolveBAMURL_esviritu_recordedPathNotAFile_fallsBackToLayoutLookups() async throws {
        for recorded in [nil, "bams/S1.third.filt.sorted.bam", "bams"] as [String?] {
            let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
            defer { TestTempDirectory.cleanup(root) }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("bams"),
                withIntermediateDirectories: true
            )
            let legacy = try writeStandInBAM("S1.sorted.bam", under: root)

            assertSameFile(try await resolveEsVirituBAM("S1", resultPath: resultPath), legacy, recorded ?? "nil")
        }
    }

    /// A recorded symlink that points at a BAM inside the root resolves to that BAM. Only a symlink that leaves
    /// the root is refused.
    func testResolveBAMURL_esviritu_recordedSymlinkInsideRoot_resolvesToItsTarget() async throws {
        let recorded = "bams/S1.third.filt.sorted.bam"
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
        defer { TestTempDirectory.cleanup(root) }
        let target = try writeStandInBAM("store/S1.bam", under: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bams"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(recorded),
            withDestinationURL: target
        )

        let resolved = try await resolveEsVirituBAM("S1", resultPath: resultPath)
        assertSameFile(resolved, target)
        // SWIFT 6. samtools opens the path that was checked, the target's physical path, never the recorded symlink.
        XCTAssertEqual(resolved.path, CanonicalFilePath.path(for: target))
    }

    /// A recorded file that is a symlink to a BAM outside the result root is not read. No layout lookup finds a
    /// BAM for the sample, so the resolver ends at the refusal for a BAM outside the result (U36, it was `bamNotFound`).
    func testResolveBAMURL_esviritu_recordedSymlinkLeavingRoot_throwsBamOutsideResult() async throws {
        let outside = try TestTempDirectory.make(prefix: "esviritu-outside")
        defer { TestTempDirectory.cleanup(outside) }
        let outsideBAM = try writeStandInBAM("S1.bam", under: outside)
        let recorded = "bams/S1.third.filt.sorted.bam"
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
        defer { TestTempDirectory.cleanup(root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bams"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(recorded),
            withDestinationURL: outsideBAM
        )

        await assertEsVirituBAMOutsideResult("S1", resultPath: resultPath)
    }

    /// The same holds when the symlink is a folder on the way to the BAM, here `<root>/bams`.
    func testResolveBAMURL_esviritu_recordedPathThroughFolderSymlinkLeavingRoot_throwsBamOutsideResult() async throws {
        let outside = try TestTempDirectory.make(prefix: "esviritu-outside")
        defer { TestTempDirectory.cleanup(outside) }
        try writeStandInBAM("S1.third.filt.sorted.bam", under: outside)
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: "bams/S1.third.filt.sorted.bam")
        defer { TestTempDirectory.cleanup(root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("bams"),
            withDestinationURL: outside
        )

        await assertEsVirituBAMOutsideResult("S1", resultPath: resultPath)
    }

    // MARK: - resolveBAMURL, a BAM that links out of the result root (U36, 2.8 row 274, 2.9 W4)

    /// One way a result can hold a link to a BAM outside its root, for each place a lookup looks for a BAM.
    private struct LinkedLayout {
        let label: String
        let tool: ClassifierTool
        /// The sample id the resolver is asked for, nil for the single-sample scan.
        let sampleId: String?
        /// Where the BAM sits inside the result, relative to its root.
        let bamPath: String
        /// A folder above the BAM, relative to the root, that is the link. The BAM keeps its place below it in the target.
        var linkedFolder: String?
        /// What the result's database records for the sample, or nil when the layout has no row to read.
        var recorded: String?
        /// False when no lookup names the BAM, so only a listing of a folder outside the result would find it.
        var namesTheBAM = true
    }

    private struct LinkedResult {
        let root: URL
        let resultPath: URL
        let outside: URL
        /// The BAM outside the result that the link leads to.
        let outsideBAM: URL
    }

    /// One layout for each place a lookup finds a BAM, so a link out of the root is tried at every one of them.
    private static let linkedLayouts: [LinkedLayout] = {
        let standard = "S1/bams/S1.third.filt.sorted.bam"
        return [
            LinkedLayout(label: "EsViritu batch, recorded", tool: .esviritu, sampleId: "S1", bamPath: standard, recorded: standard),
            LinkedLayout(label: "EsViritu batch, standard name", tool: .esviritu, sampleId: "S1", bamPath: standard),
            LinkedLayout(label: "EsViritu batch, bams scan", tool: .esviritu, sampleId: "S1", bamPath: "S1/bams/S1.custom.sorted.bam"),
            LinkedLayout(label: "EsViritu batch, bams folder", tool: .esviritu, sampleId: "S1", bamPath: standard, linkedFolder: "S1/bams", recorded: standard),
            LinkedLayout(label: "EsViritu batch, sample folder", tool: .esviritu, sampleId: "S1", bamPath: "S1/bams/S1.custom.sorted.bam", linkedFolder: "S1", namesTheBAM: false),
            LinkedLayout(label: "EsViritu flat legacy", tool: .esviritu, sampleId: "S1", bamPath: "S1.sorted.bam"),
            LinkedLayout(label: "EsViritu temp legacy", tool: .esviritu, sampleId: "S1", bamPath: "S1_temp/S1.sorted.bam"),
            LinkedLayout(label: "EsViritu single-sample scan", tool: .esviritu, sampleId: nil, bamPath: "S1.sorted.bam"),
            LinkedLayout(label: "TaxTriage minimap2", tool: .taxtriage, sampleId: "S1", bamPath: "minimap2/S1.bam"),
            LinkedLayout(label: "TaxTriage minimap2 scan", tool: .taxtriage, sampleId: "S1", bamPath: "minimap2/S1.S1.dwnld.references.bam"),
            LinkedLayout(label: "TaxTriage minimap2 folder", tool: .taxtriage, sampleId: "S1", bamPath: "minimap2/S1.bam", linkedFolder: "minimap2"),
            LinkedLayout(label: "NAO-MGS bams", tool: .naomgs, sampleId: "S1", bamPath: "bams/S1.bam"),
            LinkedLayout(label: "NAO-MGS bams sorted", tool: .naomgs, sampleId: "S1", bamPath: "bams/S1.sorted.bam"),
            LinkedLayout(label: "NAO-MGS recorded path", tool: .naomgs, sampleId: "S1", bamPath: "custom/S1.bam", recorded: "custom/S1.bam"),
            LinkedLayout(label: "NVD bam", tool: .nvd, sampleId: "S1", bamPath: "bam/S1.filtered.bam"),
            LinkedLayout(label: "NVD bam sorted", tool: .nvd, sampleId: "S1", bamPath: "bam/S1.filtered.sorted.bam"),
            LinkedLayout(label: "NVD recorded path", tool: .nvd, sampleId: "S1", bamPath: "custom/S1.bam", recorded: "custom/S1.bam"),
        ]
    }()

    /// A NAO-MGS `hits.sqlite` with one taxon row for `sampleId` whose `bam_path` is `recordedBAM`.
    private func makeNaoMgsDatabase(at url: URL, sampleId: String, recordedBAM: String) throws {
        let hit = NaoMgsVirusHit(
            sample: sampleId, seqId: "\(sampleId)_read", taxId: 2_697_049, bestAlignmentScore: 120,
            cigar: "150M", queryStart: 0, queryEnd: 150, refStart: 0, refEnd: 150,
            readSequence: String(repeating: "A", count: 150), readQuality: String(repeating: "I", count: 150),
            subjectSeqId: "NC_045512.2", subjectTitle: "SARS-CoV-2", bitScore: 250, eValue: 1e-50,
            percentIdentity: 98.5, editDistance: 2, fragmentLength: 300, isReverseComplement: false,
            pairStatus: "CP", queryLength: 150
        )
        try NaoMgsDatabase.create(at: url, hits: [hit])
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "ClassifierReadResolverTests", code: 2)
        }
        let update = "UPDATE taxon_summaries SET bam_path = '\(recordedBAM)' WHERE sample = '\(sampleId)'"
        XCTAssertEqual(sqlite3_exec(db, update, nil, nil, nil), SQLITE_OK)
    }

    /// A result of `layout.tool` whose BAM is a link to a file in a second folder outside the result. The link sits at
    /// `layout.bamPath`, or at `layout.linkedFolder` above it, which then leads to the second folder.
    private func makeLinkedResult(_ layout: LinkedLayout) throws -> LinkedResult {
        let fm = FileManager.default
        let sampleId = layout.sampleId ?? "S1"
        let outside = try TestTempDirectory.make(prefix: "linked-outside")
        let belowLink = layout.linkedFolder.map { String(layout.bamPath.dropFirst($0.count + 1)) }
            ?? URL(fileURLWithPath: layout.bamPath).lastPathComponent
        let outsideBAM = try writeStandInBAM(belowLink, under: outside)
        let root: URL
        let resultPath: URL
        switch layout.tool {
        case .esviritu:
            let made = try makeEsVirituResult(sampleId: sampleId, bamPath: layout.recorded)
            root = made.root
            resultPath = made.resultPath
        case .taxtriage:
            root = try TestTempDirectory.make(prefix: "linked-taxtriage")
            resultPath = root.appendingPathComponent("taxtriage.sqlite")
        case .naomgs:
            root = try TestTempDirectory.make(prefix: "linked-naomgs")
            resultPath = root.appendingPathComponent("hits.sqlite")
            if let recorded = layout.recorded {
                try makeNaoMgsDatabase(at: resultPath, sampleId: sampleId, recordedBAM: recorded)
            }
        case .nvd:
            root = try TestTempDirectory.make(prefix: "linked-nvd")
            resultPath = root.appendingPathComponent("hits.sqlite")
            if let recorded = layout.recorded {
                try NvdDatabase.create(at: resultPath, hits: [], samples: [NvdSampleMetadata(
                    sampleId: sampleId, bamPath: recorded, fastaPath: "\(sampleId).fasta",
                    totalReads: 1, contigCount: 0, hitCount: 0
                )])
            }
        case .kraken2:
            preconditionFailure("kraken2 is not a BAM-backed tool")
        }
        let linkURL = root.appendingPathComponent(layout.linkedFolder ?? layout.bamPath)
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: layout.linkedFolder == nil ? outsideBAM : outside)
        return LinkedResult(root: root, resultPath: resultPath, outside: outside, outsideBAM: outsideBAM)
    }

    private func removeLinkedResult(_ result: LinkedResult) {
        TestTempDirectory.cleanup(result.root)
        TestTempDirectory.cleanup(result.outside)
    }

    /// What the resolver does for the BAM of `layout`, with the thrown error kept for the caller to read.
    private func resolveLinkedBAM(_ layout: LinkedLayout, in result: LinkedResult) async -> Result<URL, Error> {
        do {
            return .success(try await ClassifierReadResolver().testingResolveBAMURL(
                tool: layout.tool,
                sampleId: layout.sampleId,
                resultPath: result.resultPath
            ))
        } catch {
            return .failure(error)
        }
    }

    // MARK: A link out of the root is dropped (U36 item 2)

    /// The words of the refusal for a BAM that links out of the result, UX Q-U5.
    private static func outsideResultMessage(_ sample: String) -> String {
        "The BAM file of sample '\(sample)' is a link to a file outside this result folder, and LGE extracts reads only from BAM files inside it. Replace the link with a copy of the file and try again."
    }

    /// The words of the refusal for a BAM that is missing, which this lane keeps.
    private static func notFoundMessage(_ sample: String) -> String {
        "No BAM file found for sample '\(sample)'. The classifier result may be corrupted or imported without the underlying alignment data."
    }

    /// Asserts that the BAM of `layout` is refused for its sample, with the words for a BAM outside the result when a
    /// lookup names it and with the words for a missing BAM otherwise, and that the refusal writes nothing in the
    /// result (UX 6).
    private func assertLinkedBAMRefused(
        _ layout: LinkedLayout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let result = try makeLinkedResult(layout)
        defer { removeLinkedResult(result) }
        let before = try resultTreeContents(result.root)
        let sample = layout.sampleId ?? "(single)"
        switch await resolveLinkedBAM(layout, in: result) {
        case .success(let resolved):
            XCTFail("\(layout.label) resolved \(resolved.path)", file: file, line: line)
        case .failure(let error):
            let expected = layout.namesTheBAM ? Self.outsideResultMessage(sample) : Self.notFoundMessage(sample)
            XCTAssertEqual(error.localizedDescription, expected, layout.label, file: file, line: line)
        }
        XCTAssertEqual(try resultTreeContents(result.root), before, "\(layout.label) wrote in the result", file: file, line: line)
    }

    /// A batch result whose BAM links out of the root is refused like a one-folder result with the same link, and both
    /// refusals say that the BAM is outside the result.
    func testLinkedBAM_batchResultAndOneFolderResultAreRefusedAlike() async throws {
        let name = "S1.third.filt.sorted.bam"
        try await assertLinkedBAMRefused(LinkedLayout(
            label: "batch", tool: .esviritu, sampleId: "S1", bamPath: "S1/bams/\(name)", recorded: "S1/bams/\(name)"
        ))
        try await assertLinkedBAMRefused(LinkedLayout(
            label: "one folder", tool: .esviritu, sampleId: "S1", bamPath: "bams/\(name)", recorded: "bams/\(name)"
        ))
    }

    /// Every place a lookup finds a BAM drops a link out of the root: the layout lookups of the four tools, the
    /// folders they list, and the NAO-MGS and NVD paths that their databases record. A BAM that only a listing of a
    /// folder outside the result would find is not read, and is reported as missing.
    func testLinkedBAM_everyLayoutLookupDropsALinkOutOfTheRoot() async throws {
        for layout in Self.linkedLayouts {
            try await assertLinkedBAMRefused(layout)
        }
    }

    /// A candidate that links out is dropped, and the next candidate that stays inside the root is used.
    func testLinkedBAM_aLinkOutOfTheRootIsDroppedForTheNextCandidate() async throws {
        let layout = LinkedLayout(
            label: "batch", tool: .esviritu, sampleId: "S1", bamPath: "S1/bams/S1.third.filt.sorted.bam"
        )
        let result = try makeLinkedResult(layout)
        defer { removeLinkedResult(result) }
        let inside = try writeStandInBAM("S1/bams/S1.other.sorted.bam", under: result.root)

        let resolved = try await resolveLinkedBAM(layout, in: result).get()
        assertSameFile(resolved, inside)
        XCTAssertTrue(CanonicalFilePath.isPath(resolved, within: result.root))
    }

    /// The single-sample scan offers every `*.sorted.bam` it finds, so links out of the root do not hide a BAM inside.
    func testLinkedBAM_singleSampleScanSkipsLinksOutOfTheRoot() async throws {
        let outside = try TestTempDirectory.make(prefix: "linked-outside")
        defer { TestTempDirectory.cleanup(outside) }
        let outsideBAM = try writeStandInBAM("out.bam", under: outside)
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: nil)
        defer { TestTempDirectory.cleanup(root) }
        for index in 1...8 {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("a\(index).sorted.bam"),
                withDestinationURL: outsideBAM
            )
        }
        let inside = try writeStandInBAM("bams/z.sorted.bam", under: root)

        let resolved = try await ClassifierReadResolver().testingResolveBAMURL(
            tool: .esviritu,
            sampleId: nil,
            resultPath: resultPath
        )
        assertSameFile(resolved, inside)
    }

    // MARK: The refusal's own words (U36 item 3)

    /// The refusal is its own case, so a caller can tell a BAM outside the result from a BAM that is missing.
    func testLinkedBAM_theRefusalIsItsOwnCase() async throws {
        let layout = LinkedLayout(
            label: "batch", tool: .esviritu, sampleId: "S1", bamPath: "S1/bams/S1.third.filt.sorted.bam"
        )
        let result = try makeLinkedResult(layout)
        defer { removeLinkedResult(result) }
        do {
            let url = try await resolveEsVirituBAM("S1", resultPath: result.resultPath)
            XCTFail("Expected bamOutsideResult, resolved \(url.path)")
        } catch ClassifierExtractionError.bamOutsideResult(let sampleId) {
            XCTAssertEqual(sampleId, "S1")
        } catch {
            XCTFail("Expected bamOutsideResult, got \(error)")
        }
    }

    /// A BAM that is missing keeps the words of `bamNotFound`, which is the true cause then.
    func testLinkedBAM_aMissingBAMKeepsItsWords() async throws {
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: "S1/bams/S1.third.filt.sorted.bam")
        defer { TestTempDirectory.cleanup(root) }
        await assertEsVirituBAMNotFound("S1", resultPath: resultPath)
        do {
            _ = try await resolveEsVirituBAM("S1", resultPath: resultPath)
            XCTFail("Expected bamNotFound")
        } catch {
            XCTAssertEqual(error.localizedDescription, Self.notFoundMessage("S1"))
        }
    }

    /// A link whose target is missing names no BAM, so the refusal is `bamNotFound` and not the one for a BAM outside.
    func testLinkedBAM_aLinkWithNoTargetIsReportedMissing() async throws {
        let outside = try TestTempDirectory.make(prefix: "linked-outside")
        defer { TestTempDirectory.cleanup(outside) }
        let name = "S1.third.filt.sorted.bam"
        let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: "S1/bams/\(name)")
        defer { TestTempDirectory.cleanup(root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("S1/bams"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("S1/bams/\(name)"),
            withDestinationURL: outside.appendingPathComponent("missing.bam")
        )
        await assertEsVirituBAMNotFound("S1", resultPath: resultPath)
    }

    /// A recorded path that leaves the root, as a `..` step or as an absolute path, is a BAM outside the result when
    /// the file exists there and no candidate stays inside. With a candidate inside, the existing fallback pin holds.
    func testLinkedBAM_aRecordedPathOutsideTheRootIsRefusedAsOutside() async throws {
        let outside = try TestTempDirectory.make(prefix: "linked-outside")
        defer { TestTempDirectory.cleanup(outside) }
        let outsideBAM = try writeStandInBAM("S1.third.filt.sorted.bam", under: outside)
        for recorded in ["../\(outside.lastPathComponent)/S1.third.filt.sorted.bam", outsideBAM.path] {
            let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: recorded)
            defer { TestTempDirectory.cleanup(root) }
            await assertEsVirituBAMOutsideResult("S1", resultPath: resultPath)
        }
    }

    /// The single-sample scan lists the result with a directory enumerator, which does not enter a folder link.
    func testLinkedBAM_singleSampleScanDoesNotEnterALinkedFolder() async throws {
        let layout = LinkedLayout(
            label: "scan", tool: .esviritu, sampleId: nil, bamPath: "linked/S1.sorted.bam", linkedFolder: "linked"
        )
        let result = try makeLinkedResult(layout)
        defer { removeLinkedResult(result) }
        switch await resolveLinkedBAM(layout, in: result) {
        case .success(let resolved):
            XCTFail("The scan entered the linked folder and resolved \(resolved.path)")
        case .failure(let error):
            guard case ClassifierExtractionError.bamNotFound(let sampleId) = error else {
                return XCTFail("Expected bamNotFound, got \(error)")
            }
            XCTAssertEqual(sampleId, "(single)")
        }
    }

    /// Foundation's listing by URL does not follow a folder link, so a BAM below a linked `bams` folder is found only
    /// under its standard name. A BAM with another name is not found, and the refusal is `bamNotFound`.
    func testLinkedBAM_linkedBamsFolderIsNotListed() async throws {
        let layout = LinkedLayout(
            label: "bams folder, other name", tool: .esviritu, sampleId: "S1",
            bamPath: "S1/bams/S1.custom.sorted.bam", linkedFolder: "S1/bams"
        )
        let result = try makeLinkedResult(layout)
        defer { removeLinkedResult(result) }
        await assertEsVirituBAMNotFound("S1", resultPath: result.resultPath)
    }

    /// A link that stays inside the root keeps resolving to the target it names, for a file and for a folder. Foundation's
    /// listing by URL does not follow a folder link, so only the standard name is found through one.
    func testLinkedBAM_linkInsideTheRootResolvesToItsTarget() async throws {
        for linksFolder in [false, true] {
            let (root, resultPath) = try makeEsVirituResult(sampleId: "S1", bamPath: nil)
            defer { TestTempDirectory.cleanup(root) }
            let name = "S1.third.filt.sorted.bam"
            let target = try writeStandInBAM("store/bams/\(name)", under: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("S1"), withIntermediateDirectories: true)
            let linkURL = root.appendingPathComponent(linksFolder ? "S1/bams" : "S1/bams/\(name)")
            if !linksFolder {
                try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(
                at: linkURL,
                withDestinationURL: linksFolder ? target.deletingLastPathComponent() : target
            )
            let resolved = try await resolveEsVirituBAM("S1", resultPath: resultPath)
            assertSameFile(resolved, target, linksFolder ? "a folder link" : "a file link")
            // SWIFT 6. samtools opens the path that was checked, the target's physical path, never the link.
            XCTAssertEqual(resolved.path, CanonicalFilePath.path(for: target))
        }
    }

    // MARK: - extractViaBAM end-to-end (real samtools)

    /// Path to the sarscov2 test fixture BAM (exists in Tests/Fixtures/sarscov2/).
    private func sarscov2FixtureBAM() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // tests/LungfishWorkflowTests/Extraction/ClassifierReadResolverTests.swift
        // ↑ we walk up 4 levels to repo root, then into Tests/Fixtures/sarscov2
        let repoRoot = thisFile
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let bam = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        guard FileManager.default.fileExists(atPath: bam.path) else {
            throw XCTSkip("sarscov2 test BAM not present at \(bam.path)")
        }
        return bam
    }

    /// Set up a fake "nvd" result directory pointing at the sarscov2 fixture BAM
    /// by symlinking the fixture BAM + index into the expected naming pattern.
    private func makeSarscov2ResultFixture(tool: ClassifierTool, sampleId: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("s2fixture-\(tool.rawValue)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let fixtureBAM = try sarscov2FixtureBAM()
        let fixtureBAI = fixtureBAM.deletingPathExtension().appendingPathExtension("bam.bai")
        let fixtureBAIFallback = URL(fileURLWithPath: fixtureBAM.path + ".bai")
        let actualBAIFixture: URL
        if fm.fileExists(atPath: fixtureBAIFallback.path) {
            actualBAIFixture = fixtureBAIFallback
        } else if fm.fileExists(atPath: fixtureBAI.path) {
            actualBAIFixture = fixtureBAI
        } else {
            throw XCTSkip("sarscov2 BAI not present")
        }

        let bamDest: URL
        switch tool {
        case .nvd:
            try fm.createDirectory(at: root.appendingPathComponent("bam"), withIntermediateDirectories: true)
            bamDest = root.appendingPathComponent("bam/\(sampleId).filtered.bam")
        case .esviritu:
            bamDest = root.appendingPathComponent("\(sampleId).sorted.bam")
        case .taxtriage:
            try fm.createDirectory(at: root.appendingPathComponent("minimap2"), withIntermediateDirectories: true)
            bamDest = root.appendingPathComponent("minimap2/\(sampleId).bam")
        case .naomgs:
            try fm.createDirectory(at: root.appendingPathComponent("bams"), withIntermediateDirectories: true)
            bamDest = root.appendingPathComponent("bams/\(sampleId).sorted.bam")
        case .kraken2:
            fatalError("kraken2 not BAM-backed")
        }
        try fm.copyItem(at: fixtureBAM, to: bamDest)
        try fm.copyItem(at: actualBAIFixture, to: URL(fileURLWithPath: bamDest.path + ".bai"))
        return root.appendingPathComponent("fake-result.sqlite")
    }

    private func makeTestFileProvenance(
        destination: String = "file",
        format: CopyFormat = .fastq
    ) -> ExtractionFileProvenance {
        ExtractionFileProvenance(
            workflowName: "lungfish app classifier read extraction",
            toolName: "Lungfish.app",
            argv: [
                "lungfish",
                "extract",
                "reads",
                "--by-classifier",
                "--tool", "nvd",
                "--read-format", format.rawValue,
            ],
            explicitOptions: [
                "tool": .string("nvd"),
                "format": .string(format.rawValue),
                "destination": .string(destination),
            ],
            defaults: [
                "format": .string("fastq"),
                "includeUnmappedMates": .boolean(false),
            ],
            resolved: [
                "samtoolsExcludeFlags": .integer(ExtractionOptions().samtoolsExcludeFlags),
            ]
        )
    }

    func testExtractViaBAM_nvd_producesFASTQFromFixture() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "s2")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        // Dig out the actual reference name from the BAM so we can target it.
        // For sarscov2 this is "MN908947.3" per TestFixtures, but we read
        // from the index to avoid hard-coding.
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).fastq")
        defer {
            try? FileManager.default.removeItem(at: tempOut)
            try? FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: tempOut))
        }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "s2", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(
                format: .fastq,
                includeUnmappedMates: false,
                fileProvenance: makeTestFileProvenance()
            ),
            destination: .file(tempOut)
        )

        if case .file(let url, let n) = outcome {
            XCTAssertEqual(url.standardizedFileURL.path, tempOut.standardizedFileURL.path)
            XCTAssertGreaterThan(n, 0, "Expected non-zero reads from sarscov2 fixture")
            let envelope = try XCTUnwrap(
                ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: tempOut))
            )
            XCTAssertEqual(envelope.workflowName, "lungfish app classifier read extraction")
            XCTAssertEqual(envelope.output?.path, tempOut.path)
            XCTAssertEqual(envelope.output?.format, .fastq)
            XCTAssertNotNil(envelope.output?.checksumSHA256)
            XCTAssertEqual(envelope.options.explicit["tool"]?.stringValue, "nvd")
            XCTAssertEqual(envelope.options.explicit["outputPath"]?.fileValue?.path, tempOut.path)
            XCTAssertEqual(envelope.options.resolvedDefaults["readCount"]?.integerValue, n)
            XCTAssertGreaterThan(envelope.options.resolvedDefaults["sourceCount"]?.integerValue ?? 0, 0)
            XCTAssertTrue(envelope.argv.contains(tempOut.path))
            XCTAssertNotNil(
                envelope.files.first { $0.role == .input && $0.path.hasSuffix("s2.filtered.bam") },
                "Expected the provenance sidecar to record the resolved source BAM"
            )
        } else {
            XCTFail("Expected .file outcome, got \(outcome)")
        }
    }

    func testExtractViaBAM_multiSample_concatenatesOutputs() async throws {
        let resultPathA = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "A")
        let rootA = resultPathA.deletingLastPathComponent()
        let resultPathB = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "B")
        let rootB = resultPathB.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        // Same-root multi-sample: copy sample B's BAM into root A so both
        // samples live under the same result path, per spec.
        let bamDirA = rootA.appendingPathComponent("bam")
        try FileManager.default.copyItem(
            at: rootB.appendingPathComponent("bam/B.filtered.bam"),
            to: bamDirA.appendingPathComponent("B.filtered.bam")
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: rootB.appendingPathComponent("bam/B.filtered.bam").path + ".bai"),
            to: URL(fileURLWithPath: bamDirA.appendingPathComponent("B.filtered.bam").path + ".bai")
        )

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [
                ClassifierRowSelector(sampleId: "A", accessions: [region], taxIds: []),
                ClassifierRowSelector(sampleId: "B", accessions: [region], taxIds: []),
            ],
            options: ExtractionOptions(),
            destination: .file(tempOut)
        )
        XCTAssertGreaterThan(outcome.readCount, 0)
    }

    /// Extract sample A alone, sample B alone, and A+B together; assert
    /// count(A+B) == count(A) + count(B). Catches concatenation bugs and the
    /// stem-collision risk where two samples share the same sidecar prefix.
    func testExtractViaBAM_multiSample_countEquivalence() async throws {
        let resultPathA = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "A")
        let rootA = resultPathA.deletingLastPathComponent()
        let resultPathB = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "B")
        let rootB = resultPathB.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        // Copy sample B's BAM into root A so the combined extraction can
        // resolve both samples from the same result path.
        let bamDirAeq = rootA.appendingPathComponent("bam")
        try FileManager.default.copyItem(
            at: rootB.appendingPathComponent("bam/B.filtered.bam"),
            to: bamDirAeq.appendingPathComponent("B.filtered.bam")
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: rootB.appendingPathComponent("bam/B.filtered.bam").path + ".bai"),
            to: URL(fileURLWithPath: bamDirAeq.appendingPathComponent("B.filtered.bam").path + ".bai")
        )

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let resolver = ClassifierReadResolver()

        let outA = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).fastq")
        let outB = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).fastq")
        let outAB = FileManager.default.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString).fastq")
        defer {
            try? FileManager.default.removeItem(at: outA)
            try? FileManager.default.removeItem(at: outB)
            try? FileManager.default.removeItem(at: outAB)
        }

        let outcomeA = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [ClassifierRowSelector(sampleId: "A", accessions: [region], taxIds: [])],
            options: ExtractionOptions(),
            destination: .file(outA)
        )
        let outcomeB = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [ClassifierRowSelector(sampleId: "B", accessions: [region], taxIds: [])],
            options: ExtractionOptions(),
            destination: .file(outB)
        )
        let outcomeAB = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [
                ClassifierRowSelector(sampleId: "A", accessions: [region], taxIds: []),
                ClassifierRowSelector(sampleId: "B", accessions: [region], taxIds: []),
            ],
            options: ExtractionOptions(),
            destination: .file(outAB)
        )

        XCTAssertGreaterThan(outcomeA.readCount, 0)
        XCTAssertGreaterThan(outcomeB.readCount, 0)
        XCTAssertEqual(
            outcomeAB.readCount,
            outcomeA.readCount + outcomeB.readCount,
            "Combined A+B extract should equal the sum of per-sample counts"
        )
    }

    /// Exercises the `options.format == .fasta` path. Verifies the output is a
    /// well-formed FASTA (`>` header lines alternating with sequence lines).
    /// `convertFASTQToFASTA` has ~40 lines of hand-rolled byte munging that
    /// was previously completely untested.
    func testExtractViaBAM_fastaFormat_producesValidFASTA() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "fa")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).fasta")
        defer {
            try? FileManager.default.removeItem(at: tempOut)
            try? FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: tempOut))
        }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "fa", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(
                format: .fasta,
                includeUnmappedMates: false,
                fileProvenance: makeTestFileProvenance(format: .fasta)
            ),
            destination: .file(tempOut)
        )

        guard case .file(let url, let n) = outcome else {
            XCTFail("Expected .file outcome, got \(outcome)")
            return
        }
        XCTAssertGreaterThan(n, 0)

        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty, "FASTA output is empty")

        // Parse as UTF-8 lines and verify FASTA structure: header lines start
        // with '>', each header is followed by exactly one sequence line (the
        // resolver's converter discards the `+` and quality lines from the
        // FASTQ). Require at least one complete record.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertFalse(lines.isEmpty, "FASTA has no lines")
        XCTAssertEqual(lines.count % 2, 0, "FASTA should have an even number of header+sequence lines")

        var recordCount = 0
        for (i, line) in lines.enumerated() {
            if i % 2 == 0 {
                XCTAssertTrue(line.first == ">", "Expected header at line \(i), got: \(line)")
                recordCount += 1
            } else {
                XCTAssertFalse(line.first == ">", "Expected sequence at line \(i), got header: \(line)")
                XCTAssertFalse(line.isEmpty, "Empty sequence at line \(i)")
            }
        }
        XCTAssertGreaterThan(recordCount, 0, "No FASTA records parsed")
        XCTAssertEqual(recordCount, n, "FASTA record count should match outcome.readCount")

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: tempOut))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app classifier read extraction")
        XCTAssertEqual(envelope.output?.format, .fasta)
        XCTAssertEqual(envelope.options.explicit["format"]?.stringValue, "fasta")
        XCTAssertEqual(envelope.options.resolvedDefaults["outputFormat"]?.stringValue, "fasta")
        XCTAssertEqual(envelope.options.resolvedDefaults["readCount"]?.integerValue, n)
    }

    /// Exercises the `includeUnmappedMates: true` path. The sarscov2 fixture
    /// may not contain unmapped mates, so this test primarily pins the API
    /// surface: both flag settings should succeed and produce a non-zero
    /// count. `false` is `0xD04` (unmapped, secondary, duplicate and supplementary records excluded),
    /// `true` is `0xD00` (the same, keeping unmapped mates).
    func testExtractViaBAM_includeUnmappedMates_succeeds() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "um")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("um-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "um", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(format: .fastq, includeUnmappedMates: true),
            destination: .file(tempOut)
        )

        guard case .file(_, let n) = outcome else {
            XCTFail("Expected .file outcome, got \(outcome)")
            return
        }
        XCTAssertGreaterThan(n, 0, "Expected non-zero reads with includeUnmappedMates=true")
    }

    // MARK: - Shared Kraken2 source resolution

    private func makeKraken2ClassResult(
        in dir: URL,
        inputFiles: [URL],
        originalInputFiles: [URL]?,
        outputDirectory: URL
    ) throws -> ClassificationResult {
        let kreport = dir.appendingPathComponent("classification.kreport")
        try "100.00\t10\t0\tR\t1\troot\n".write(to: kreport, atomically: true, encoding: .utf8)
        let kraken = dir.appendingPathComponent("classification.kraken")
        try "C\tread1\t1\t150\t0:150\n".write(to: kraken, atomically: true, encoding: .utf8)

        var config = ClassificationConfig(
            inputFiles: inputFiles,
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: dir,
            confidence: 0.0,
            minimumHitGroups: 2,
            threads: 1,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: outputDirectory
        )
        config.originalInputFiles = originalInputFiles

        return ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: kreport),
            reportURL: kreport,
            outputURL: kraken,
            brackenURL: nil,
            runtime: 1.0,
            toolVersion: "2.1.3",
            provenanceId: UUID()
        )
    }

    /// Every read file a result's extraction and BLAST read, through
    /// ``KrakenResultReadSources``, the one resolver the app and the CLI use.
    private func kraken2SourceFiles(_ result: ClassificationResult, in root: URL) async throws -> [URL] {
        try await KrakenResultReadSources.resolve(
            result: result,
            materializationDirectory: root.appendingPathComponent("materialized", isDirectory: true)
        ).urls
    }

    func testResolveKraken2SourceResolvesBundleOriginalToItsPayload() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("k2src-bundle-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let bundle = root.appendingPathComponent("sample.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let payload = bundle.appendingPathComponent("sample.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: payload, atomically: true, encoding: .utf8)

        // inputFiles points at a materialized temp that no longer exists.
        let deletedTemp = root.appendingPathComponent("materialized-gone.fastq")

        let result = try makeKraken2ClassResult(
            in: root,
            inputFiles: [deletedTemp],
            originalInputFiles: [bundle],
            outputDirectory: root
        )

        let resolved = try await kraken2SourceFiles(result, in: root)
        XCTAssertEqual(
            resolved,
            [payload.standardizedFileURL],
            "A .lungfishfastq original must resolve to the payload file inside the bundle"
        )
    }

    func testResolveKraken2SourcePrefersOriginalWhenInputFilesWereDeleted() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("k2src-original-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("original.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: original, atomically: true, encoding: .utf8)
        let deletedTemp = root.appendingPathComponent("materialized-gone.fastq")

        let result = try makeKraken2ClassResult(
            in: root,
            inputFiles: [deletedTemp],
            originalInputFiles: [original],
            outputDirectory: root
        )

        let resolved = try await kraken2SourceFiles(result, in: root)
        XCTAssertEqual(resolved, [original.standardizedFileURL])
    }

    func testResolveKraken2SourceFallsBackToPlainInputFile() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("k2src-plain-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let plain = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: plain, atomically: true, encoding: .utf8)

        let result = try makeKraken2ClassResult(
            in: root,
            inputFiles: [plain],
            originalInputFiles: nil,
            outputDirectory: root
        )

        let resolved = try await kraken2SourceFiles(result, in: root)
        XCTAssertEqual(resolved, [plain.standardizedFileURL])
    }

    func testResolveKraken2SourceThrowsWhenNothingIsResolvable() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("k2src-none-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let result = try makeKraken2ClassResult(
            in: root,
            inputFiles: [root.appendingPathComponent("gone.fastq")],
            originalInputFiles: nil,
            outputDirectory: root
        )

        do {
            _ = try await kraken2SourceFiles(result, in: root)
            XCTFail("a result whose inputs are all gone has no source")
        } catch ClassifierExtractionError.kraken2SourceMissing {
        }
    }

    // MARK: - Bundle destination directory

    func testBundleDestinationDirectoryRoutesToExtractionsUnderProjectRoot() throws {
        let fm = FileManager.default
        let projectRoot = fm.temporaryDirectory
            .appendingPathComponent("proj-imports-\(UUID().uuidString).lungfish")
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: projectRoot) }

        let dir = try ClassifierReadResolver.bundleDestinationDirectory(projectRoot: projectRoot)

        XCTAssertEqual(dir.lastPathComponent, "Extractions")
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL, projectRoot.standardizedFileURL)
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "Extractions/ must be created if missing")
    }

    func testBundleDestinationDirectoryHonoursAnExplicitExtractionsSelection() throws {
        // If the caller already pointed at an Extractions directory, don't nest
        // a second Extractions inside it.
        let fm = FileManager.default
        let projectRoot = fm.temporaryDirectory
            .appendingPathComponent("proj-imports2-\(UUID().uuidString).lungfish")
        let imports = projectRoot.appendingPathComponent("Extractions", isDirectory: true)
        try fm.createDirectory(at: imports, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: projectRoot) }

        let dir = try ClassifierReadResolver.bundleDestinationDirectory(projectRoot: imports)
        XCTAssertEqual(dir.standardizedFileURL, imports.standardizedFileURL)
    }

    // MARK: - Destination routing

    func testDestination_bundle_createsLungfishfastqUnderProjectRoot() async throws {
        let fm = FileManager.default
        let projectRoot = fm.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)")
        let lungfishDir = projectRoot.appendingPathComponent(".lungfish")
        try fm.createDirectory(at: lungfishDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: projectRoot) }

        // Stand up an NVD fake result INSIDE the project so resolveProjectRoot walks up correctly.
        let resultDir = projectRoot.appendingPathComponent("analyses/nvd-20260401")
        let resultBamDir = resultDir.appendingPathComponent("bam")
        try fm.createDirectory(at: resultBamDir, withIntermediateDirectories: true)
        let fixtureBAM = try sarscov2FixtureBAM()
        let fixtureBAI: URL = {
            let bai = URL(fileURLWithPath: fixtureBAM.path + ".bai")
            if fm.fileExists(atPath: bai.path) { return bai }
            return fixtureBAM.deletingPathExtension().appendingPathExtension("bam.bai")
        }()
        let bamDest = resultBamDir.appendingPathComponent("s2.filtered.bam")
        try fm.copyItem(at: fixtureBAM, to: bamDest)
        try fm.copyItem(at: fixtureBAI, to: URL(fileURLWithPath: bamDest.path + ".bai"))
        let resultPath = resultDir.appendingPathComponent("fake.sqlite")

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(bamURL: fixtureBAM, runner: .shared)
        guard let region = bamRefs.first else { throw XCTSkip("no BAM refs") }

        let metadata = ExtractionMetadata(
            sourceDescription: "sarscov2-fixture",
            toolName: "NVD",
            parameters: ["accession": region]
        )

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "s2", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: projectRoot,
                displayName: "sarscov2-test-extract",
                metadata: metadata
            )
        )

        guard case .bundle(let bundleURL, let n) = outcome else {
            XCTFail("Expected .bundle outcome, got \(outcome)")
            return
        }
        XCTAssertTrue(bundleURL.pathExtension == "lungfishfastq",
                      "Expected .lungfishfastq bundle, got \(bundleURL.lastPathComponent)")
        XCTAssertTrue(bundleURL.path.hasPrefix(projectRoot.path),
                      "Bundle must land under the project root: \(bundleURL.path)")
        XCTAssertFalse(bundleURL.path.contains("/.lungfish/.tmp/"),
                      "Bundle must NOT land in .lungfish/.tmp/")
        XCTAssertEqual(
            bundleURL.deletingLastPathComponent().lastPathComponent,
            "Extractions",
            "Classifier extraction bundles must land in <project>/Extractions/ (derived data, kept apart from sequence imports), not at the project root"
        )
        XCTAssertGreaterThan(n, 0)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadataURL = bundleURL.appendingPathComponent("extraction-metadata.json")
        let extractionMetadata = try decoder.decode(
            ExtractionMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        XCTAssertEqual(extractionMetadata.parameters["classifierExtractionOutputLayout"], "single_file")
        XCTAssertEqual(extractionMetadata.parameters["classifierExtractionOutputPairingMode"], "single_end")
        XCTAssertEqual(extractionMetadata.parameters["classifierExtractionOutputFormat"], "fastq")
        XCTAssertEqual(extractionMetadata.parameters["classifierExtractionReadCountUnit"], "reads")

        let fastqURL = try XCTUnwrap(
            try fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "fastq" }
        )
        let persisted = try XCTUnwrap(FASTQMetadataStore.load(for: fastqURL))
        XCTAssertEqual(persisted.ingestion?.pairingMode, .singleEnd)

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))
        XCTAssertEqual(provenance.workflowName, "Classifier Read Extraction")
        XCTAssertEqual(provenance.options.resolvedDefaults["readCount"], .integer(n))
        XCTAssertEqual(provenance.options.resolvedDefaults["outputFormat"], .string("fastq"))
        XCTAssertTrue(provenance.files.contains {
            $0.role == .input && $0.path == bamDest.standardizedFileURL.path
                && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == fastqURL.standardizedFileURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
        XCTAssertTrue(provenance.outputs.contains {
            $0.path == metadataURL.standardizedFileURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil
        })
    }

    /// Since Phase 2.12 lane 12.11 the clipboard and share rows run `lungfish-cli extract reads
    /// --by-classifier` and copy its file (`ClassifierExtractionCopyRoute`), so the resolver refuses both
    /// destinations before it reads or writes anything.
    func testTheClipboardAndShareDestinationsAreRefusedBeforeAnyWork() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-result-\(UUID().uuidString)")
        for destination in [ExtractionDestination.clipboard(format: .fastq, cap: 10_000), .share(tempDirectory: missing)] {
            do {
                _ = try await ClassifierReadResolver().resolveAndExtract(
                    tool: .nvd,
                    resultPath: missing,
                    selections: [ClassifierRowSelector(sampleId: "s", accessions: ["NC_1"], taxIds: [])],
                    options: ExtractionOptions(format: .fastq),
                    destination: destination
                )
                XCTFail("\(destination) is refused")
            } catch let error as ClassifierExtractionError {
                guard case .unsupportedCopyDestination = error else {
                    XCTFail("\(destination) is refused with the typed case, not \(error)")
                    continue
                }
                XCTAssertEqual(
                    error.errorDescription, "Clipboard / share destinations are not supported from the CLI",
                    "\(destination): the words the command prints for the same refusal"
                )
                XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "\(destination): nothing is written")
            }
        }
    }

    // MARK: - extractViaKraken2

    /// Path to the committed kraken2-mini per-sample fixture.
    private func kraken2MiniResultPath() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("Tests/Fixtures/kraken2-mini/SRR35517702")
    }

    func testExtractViaKraken2_fixtureProducesFASTQ() async throws {
        let classificationDir = try kraken2MiniResultPath()

        // We need at least one tax ID that has reads assigned. Load the tree
        // and pick the first non-zero clade count.
        let classResult = try ClassificationResult.load(from: classificationDir)
        let taxon = try XCTUnwrap(
            classResult.tree.allNodes().first(where: { $0.readsClade > 0 && $0.taxId != 0 }),
            "kraken2-mini fixture has no taxa with classified reads"
        )

        let tempOut = FileManager.default.temporaryDirectory.appendingPathComponent("k2out-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .kraken2,
            resultPath: classificationDir,
            selections: [
                ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [taxon.taxId])
            ],
            options: ExtractionOptions(),
            destination: .file(tempOut)
        )

        guard case .file(let url, let n) = outcome else {
            XCTFail("Expected .file outcome, got \(outcome)")
            return
        }
        XCTAssertEqual(url.standardizedFileURL.path, tempOut.standardizedFileURL.path)
        XCTAssertGreaterThan(n, 0, "Expected non-zero reads for taxon \(taxon.taxId)")
    }

    func testExtractViaKraken2BatchScopesTaxaToEachSample() async throws {
        let firstSample = try kraken2MiniResultPath()
        let batchRoot = firstSample.deletingLastPathComponent()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-batch-scoped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let outputURL = outputDir.appendingPathComponent("scoped.fastq")

        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: batchRoot,
            selections: [
                ClassifierRowSelector(
                    sampleId: "SRR35517702",
                    taxIds: [1270]
                ),
                ClassifierRowSelector(
                    sampleId: "SRR35517703",
                    taxIds: [1]
                ),
            ],
            options: ExtractionOptions(),
            destination: .file(outputURL)
        )

        guard case .file(let writtenURL, let readCount) = outcome else {
            return XCTFail("Expected .file outcome, got \(outcome)")
        }
        XCTAssertEqual(readCount, 3)
        let output = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertFalse(output.contains("@SRR35517702_classified_1\n"))
        XCTAssertTrue(output.contains("@SRR35517702_classified_2\n"))
        XCTAssertTrue(output.contains("@SRR35517703_classified_1\n"))
        XCTAssertTrue(output.contains("@SRR35517703_classified_2\n"))
    }

    func testExtractViaKraken2RejectsMixedSingleAndBatchSelectors() async throws {
        let sampleResult = try kraken2MiniResultPath()
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-mixed-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        do {
            _ = try await ClassifierReadResolver().resolveAndExtract(
                tool: .kraken2,
                resultPath: sampleResult.deletingLastPathComponent(),
                selections: [
                    ClassifierRowSelector(sampleId: nil, taxIds: [1270]),
                    ClassifierRowSelector(sampleId: "SRR35517703", taxIds: [1]),
                ],
                options: ExtractionOptions(),
                destination: .file(outputDir.appendingPathComponent("mixed.fastq"))
            )
            XCTFail("Expected mixed selector modes to be rejected")
        } catch ClassifierExtractionError.mixedSampleSelectionModes {
            XCTAssertEqual(
                ClassifierExtractionError.mixedSampleSelectionModes.localizedDescription,
                "Cannot combine single-sample and batch-sample selections in one extraction."
            )
        } catch {
            XCTFail("Expected mixedSampleSelectionModes, got \(error)")
        }
    }

    // MARK: - R3-R3ML-10: countFASTQRecords trailing-newline undercounting

    func testCountFASTQRecordsCountsLastRecordWithoutTrailingNewline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("countFASTQRecords-no-trailing-newline-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: url) }

        // Two complete 4-line records; the second (last) record's quality line has no
        // trailing "\n" -- simulating an upstream tool that omits the final LF.
        let content = "@r1\nACGT\n+\nIIII\n@r2\nACGT\n+\nIIII"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let resolver = ClassifierReadResolver()
        let count = try await resolver.testingCountFASTQRecords(in: url)

        XCTAssertEqual(count, 2, "the last record must still be counted even without a trailing newline")
    }

    func testCountFASTQRecordsCountsCorrectlyWithTrailingNewline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("countFASTQRecords-trailing-newline-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: url) }

        let content = "@r1\nACGT\n+\nIIII\n@r2\nACGT\n+\nIIII\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let resolver = ClassifierReadResolver()
        let count = try await resolver.testingCountFASTQRecords(in: url)

        XCTAssertEqual(count, 2, "well-formed newline-terminated FASTQ must still count correctly")
    }

    func testCountFASTQRecordsReturnsZeroForEmptyFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("countFASTQRecords-empty-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: url) }

        FileManager.default.createFile(atPath: url.path, contents: nil)

        let resolver = ClassifierReadResolver()
        let count = try await resolver.testingCountFASTQRecords(in: url)

        XCTAssertEqual(count, 0, "an empty file must not be counted as a phantom trailing record")
    }
}
