// SalmonQuantRouteResultTests.swift - The result, the refusals and the record of salmon quant (Phase 5.1 lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension SalmonQuantRouteTests {
    /// A count table as rows by id, each with its values by column name.
    func table(_ url: URL) throws -> [String: [String: Double]] {
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let header = try XCTUnwrap(lines.first)
        var rows: [String: [String: Double]] = [:]
        for cells in lines.dropFirst() {
            rows[cells[0]] = Dictionary(uniqueKeysWithValues: zip(header.dropFirst(), cells.dropFirst().map { Double($0) ?? .nan }))
        }
        return rows
    }

    // MARK: - Row 3, gene sums and not-host genes

    func testGeneSumsOfTheC1FixtureEqualNumReadsSummedByGeneAndERCCIsNotHost() async throws {
        let set = try await makeSetAndIndex()
        let result = try await quant([try pairBundle("A"), try pairBundle("B")], set: set).resultURL
        let (_, gene) = try fixtureGenes()
        let genes = try table(result.appendingPathComponent("counts/genes.counts.tsv"))
        for (sample, run) in [("A", "SRR896663"), ("B", "SRR896743")] {
            let rows = try String(contentsOf: RNASeqFixtures.salmonRun(run).appendingPathComponent("quant.sf"), encoding: .utf8)
                .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            let reads = try XCTUnwrap(rows.first?.firstIndex(of: "NumReads"))
            var expected: [String: Double] = [:]
            for cells in rows.dropFirst() { expected[gene[cells[0]] ?? "?", default: 0] += Double(cells[reads]) ?? .nan }
            XCTAssertEqual(Set(genes.keys), Set(expected.keys), "one row a gene of the set's transcript table")
            for (id, sum) in expected {
                XCTAssertEqual(genes[id]?[sample] ?? -1, sum, accuracy: 1e-9 * max(1, sum), "\(sample) \(id)")
            }
        }
        let data = try Data(contentsOf: result.appendingPathComponent(RNASeqResultManifest.filename))
        let manifest = try JSONDecoder().decode(RNASeqResultManifest.self, from: data)
        let ercc = Set(gene.values.filter { $0.hasPrefix("ERCC-") })
        XCTAssertEqual(ercc.count, 92)
        XCTAssertEqual(Set(manifest.notHost), ercc)
        XCTAssertEqual(manifest.origin.kind, .quantified)
        XCTAssertEqual(manifest.referenceSet?.id, set)
        XCTAssertEqual(manifest.counts.first { $0.path == "counts/genes.counts.tsv" }?.unit, .estimated)
        let geneRows = try String(contentsOf: result.appendingPathComponent("genes.tsv"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let notHost = try XCTUnwrap(geneRows.first?.firstIndex(of: "not_host"))
        for cells in geneRows.dropFirst() {
            XCTAssertEqual(cells[notHost], ercc.contains(cells[0]) ? "true" : "false", cells[0])
        }
    }

    // MARK: - Row 4, refusals before any process

    func testAMixedLayoutIsRefusedInWordsBeforeAnyProcessStarts() async throws {
        let set = try await makeSetAndIndex()
        do {
            _ = try await quant([fixtures.mixedRoot], set: set)
            XCTFail("a mixed stream was counted")
        } catch {
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("mixed-root"), words)
            XCTAssertTrue(words.contains("read pairs and single reads"), words)
        }
        XCTAssertEqual(logLines(), [], "no salmon process started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtures.projectURL.appendingPathComponent("Analyses").path))
    }

    func testAMissingIndexIsRefusedInWordsThatNameTheIndexCommand() async throws {
        let set = try await makeSet().manifest.id
        do {
            _ = try await quant([try pairBundle("A")], set: set)
            XCTFail("quant ran with no index")
        } catch {
            let words = error.localizedDescription
            XCTAssertTrue(words.contains("lungfish-cli rnaseq index --set \(set)"), words)
        }
        XCTAssertEqual(logLines(), [], "quant built no index and started no salmon")
    }

    // MARK: - Not red first

    func testTheRecordIsCompleteWithOneSalmonStepASampleAndTheScriptsArgv() async throws {
        let set = try await makeSetAndIndex()
        let outcome = try await quant([try pairBundle("A"), try pairBundle("B")], set: set)
        let envelope = try record(outcome.resultURL)
        XCTAssertEqual(ProvenanceCompleteness.issues(in: envelope), [])
        let steps = envelope.steps.filter { $0.toolName == "salmon" }
        XCTAssertEqual(steps.count, 2)
        for step in steps {
            XCTAssertEqual(Array(step.argv.prefix(3)), ["salmon", "quant", "-i"])
            XCTAssertEqual(step.argv[3], outcome.index.indexURL.path)
            XCTAssertEqual(Array(step.argv[4...6]), ["-l", "A", "-1"])
            XCTAssertEqual(step.argv.count, 14, "-1 r1 -2 r2 -p 2 -o dir and no other option: \(step.argv)")
            XCTAssertEqual(step.argv[8], "-2")
            XCTAssertEqual(Array(step.argv[10...12]), ["-p", "2", "-o"])
            XCTAssertEqual(text(step, "duplicates"), "Duplicates: kept. LGE removes duplicates only with UMIs.")
            XCTAssertEqual(text(step, "instrument"), "Instrument: Not recorded")
            XCTAssertEqual(step.managedToolID, ManagedToolID(rawValue: "salmon"))
        }
        let quantCalls = logLines().filter { $0.hasPrefix("quant ") }
        XCTAssertEqual(quantCalls.count, 2)
        XCTAssertFalse(quantCalls.contains { $0.contains("Bias") }, "no bias flag: \(quantCalls)")
        let resolved = envelope.options.resolvedDefaults
        for (key, hash) in zip(["index_seq_hash", "index_name_hash", "index_decoy_seq_hash", "index_decoy_name_hash"],
                               ["seq1", "name1", "dseq1", "dname1"]) {
            XCTAssertEqual(resolved[key], .string(hash), key)
        }
        XCTAssertEqual(envelope.options.explicit["set"], .string(set))
        let uses = outcome.index.url.appendingPathComponent(SalmonIndexCache.usesFolderName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: uses.path).count, 1, "the index's owner wrote one use")
        let scratch = ProjectTempDirectory.tempRoot(for: fixtures.projectURL)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix(SalmonQuantRoute.workFolderPrefix) }, "no working folder is left: \(left)")
    }

    func testANeedAboveTheMacsMemoryIsRefusedWithThePreflightWords() async throws {
        let set = try await makeSetAndIndex()
        do {
            _ = try await quant([try pairBundle("A")], set: set, host: RunFitHostFacts(physicalMemoryBytes: 4_294_967_296))
            XCTFail("a quant that cannot fit ran")
        } catch let error as RunFitError {
            guard case .insufficientMemory = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains(Self.linuxRoute), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("SPIKE-SALMON"), error.localizedDescription)
        }
        XCTAssertEqual(logLines(), [], "no salmon process started")
    }

    // MARK: - The set's use (`docs/formats/reference-set.md`, Cleanup)

    /// The set's owner writes one `uses/<sha256 of the result path>.json` that names the result and its record's sha256,
    /// and the set still settles with it.
    func testTheSetsOwnerWritesOneUseThatNamesTheResultAndItsRecord() async throws {
        let set = try await makeSetAndIndex()
        let outcome = try await quant([try pairBundle("A")], set: set)
        let owner = ReferenceSetOwner(storageRoot: root)
        let setURL = owner.setsFolder.appendingPathComponent("\(set).\(ReferenceSetManifest.folderExtension)", isDirectory: true)
        let uses = setURL.appendingPathComponent("uses", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: uses.path)) ?? []).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(names.count, 1, "the set's owner wrote one use: \(names)")
        guard let name = names.first else { return }
        let use = try JSONDecoder().decode(SalmonIndexCache.Use.self, from: Data(contentsOf: uses.appendingPathComponent(name)))
        XCTAssertEqual(use.resultPath, outcome.resultURL.standardizedFileURL.path)
        let record = outcome.resultURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertEqual(use.recordSHA256, try ProvenanceFileHasher.sha256(of: record))
        XCTAssertNoThrow(try owner.settled(setURL, id: set), "a use leaves the set settled")
    }
}
