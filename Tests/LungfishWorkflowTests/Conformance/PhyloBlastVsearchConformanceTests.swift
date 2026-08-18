// PhyloBlastVsearchConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// End-to-end conformance: runs the real iqtree3, blastn/makeblastdb, vsearch,
// and mafft binaries against shared fixtures, then verifies the output
// through the app's real parsers (or, where the app's Newick parser is not
// public, a topology-invariant computed directly from the tree file). By
// default a missing tool is a skip (dev machines drift); with
// LUNGFISH_REQUIRE_TOOLS=1 a missing tool becomes a hard failure.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

final class PhyloBlastVsearchConformanceTests: XCTestCase {
    func testIQTreeReproducesExpectedLeafSet() async throws {
        let iqtree = try await ToolAvailability.require("iqtree3", environment: "iqtree")
        let tmp = try ConformanceFixtures.tempDir("iqtree")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let aln = ConformanceFixtures.fixture("phylogenetics/known-sarcopterygian/alignment.fasta")
        // The fixture README specifies a fixed seed, one thread, and the
        // simple JC model for deterministic smoke runs (it also notes IQ-TREE
        // emits an unrooted tree, so we compare topology, not root placement
        // or branch lengths).
        let res = try ProcessRunner.run(
            iqtree,
            ["-s", aln.path, "-m", "JC", "-seed", "1", "-nt", "2", "-pre", tmp.appendingPathComponent("run").path, "-redo"],
            timeout: 900
        )
        XCTAssertEqual(res.status, 0, res.stderr)

        let treefile = tmp.appendingPathComponent("run.treefile")
        XCTAssertTrue(FileManager.default.fileExists(atPath: treefile.path))
        let treeText = try String(contentsOf: treefile, encoding: .utf8)
        let expectedText = try String(
            contentsOf: ConformanceFixtures.fixture("phylogenetics/known-sarcopterygian/expected.nwk"),
            encoding: .utf8
        )

        let tree = try MinimalNewickTree.parse(treeText)
        let expected = try MinimalNewickTree.parse(expectedText)

        XCTAssertEqual(Set(tree.leafNames), Set(expected.leafNames))
        XCTAssertEqual(
            tree.unrootedSplits(allLeaves: Set(expected.leafNames)),
            expected.unrootedSplits(allLeaves: Set(expected.leafNames)),
            "topology changed vs expected.nwk"
        )
    }

    func testBlastnOutfmt6HasDeclaredFields() async throws {
        let blastn = try await ToolAvailability.require("blastn", environment: "blast")
        let makeblastdb = try await ToolAvailability.require("makeblastdb", environment: "blast")
        let tmp = try ConformanceFixtures.tempDir("blast")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ref = ConformanceFixtures.sarscov2.appendingPathComponent("genome.fasta")
        let dbResult = try ProcessRunner.run(
            makeblastdb,
            ["-in", ref.path, "-dbtype", "nucl", "-out", tmp.appendingPathComponent("db").path]
        )
        XCTAssertEqual(dbResult.status, 0, dbResult.stderr)

        // The 14 fields the pipeline actually requests -- single-sourced on
        // FullLengthONTMHCBlastRescueParser so this test and the pipeline's
        // blastn invocation can never drift apart.
        let fields = FullLengthONTMHCBlastRescueParser.outfmt6Fields
        let res = try ProcessRunner.run(
            blastn,
            ["-query", ref.path, "-db", tmp.appendingPathComponent("db").path, "-outfmt", "6 " + fields.joined(separator: " "), "-max_target_seqs", "1"]
        )
        XCTAssertEqual(res.status, 0, res.stderr)
        let firstLine = res.stdout.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertFalse(firstLine.isEmpty, "expected at least one blastn hit")
        XCTAssertEqual(firstLine.split(separator: "\t", omittingEmptySubsequences: false).count, fields.count)
        XCTAssertNoThrow(try FullLengthONTMHCBlastRescueParser.parseLine(firstLine))
    }

    func testVsearchDereplicatesFixtureReads() async throws {
        let vsearch = try await ToolAvailability.require("vsearch", environment: "vsearch")
        let seqkit = try await ToolAvailability.require("seqkit", environment: "seqkit")
        let tmp = try ConformanceFixtures.tempDir("vsearch")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fasta = tmp.appendingPathComponent("reads.fasta")
        let fq2fa = try ProcessRunner.run(
            seqkit,
            ["fq2fa", ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz").path, "-o", fasta.path]
        )
        XCTAssertEqual(fq2fa.status, 0, fq2fa.stderr)

        let out = tmp.appendingPathComponent("derep.fasta")
        let res = try ProcessRunner.run(vsearch, ["--derep_fulllength", fasta.path, "--output", out.path, "--sizeout"])
        XCTAssertEqual(res.status, 0, res.stderr)
        let headers = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix(">") }
        XCTAssertFalse(headers.isEmpty)
        XCTAssertTrue(headers.allSatisfy { $0.contains(";size=") })
    }

    func testMafftAlignsAndParserReadsIt() async throws {
        let mafft = try await ToolAvailability.require("mafft", environment: "mafft")
        let tmp = try ConformanceFixtures.tempDir("mafft")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = ConformanceFixtures.fixture("phylogenetics/known-sarcopterygian/alignment.fasta")
        let out = tmp.appendingPathComponent("aln.fasta")
        let res = try ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "'\(mafft.path)' --auto '\(input.path)' > '\(out.path)'"],
            timeout: 600
        )
        XCTAssertEqual(res.status, 0, res.stderr)

        // `FASTAReader`/`Sequence` intentionally reject `-` as an invalid DNA
        // character (see `SequenceAlphabet.validCharacters`): they model raw
        // genomic sequences, not gapped multiple-sequence alignments, so
        // MAFFT's gapped output is out of scope for that reader. Use its real
        // header-reading entry point for record identity/count, and check the
        // "aligned" invariant (every row shares one length) directly against
        // the file text, which is what an MSA reader would need to support
        // gaps to do.
        let reader = try FASTAReader(url: out)
        let headers = try await reader.readHeaders()
        XCTAssertGreaterThan(headers.count, 2)

        let text = try String(contentsOf: out, encoding: .utf8)
        var rowLengths: [Int] = []
        var currentLength = 0
        var sawHeader = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                if sawHeader { rowLengths.append(currentLength) }
                currentLength = 0
                sawHeader = true
            } else {
                currentLength += line.trimmingCharacters(in: .whitespacesAndNewlines).count
            }
        }
        if sawHeader { rowLengths.append(currentLength) }
        XCTAssertEqual(rowLengths.count, headers.count)
        XCTAssertEqual(Set(rowLengths).count, 1, "aligned sequences must share a length")
    }
}

/// A minimal Newick reader used only by this conformance test to compute a
/// topology-invariant (leaf set + unrooted bipartition splits) directly from
/// tree text. `LungfishIO`'s real Newick parser (`NewickParser` inside
/// `PhylogeneticTreeParsing.swift`) is `private` to that file, so tests
/// cannot call it; this is a deliberately small, independent reimplementation
/// scoped to what the assertions need (leaf names and unrooted splits), not a
/// replacement for the app's tree-rendering parser.
struct MinimalNewickTree {
    final class Node {
        var name: String?
        var children: [Node] = []
    }

    let root: Node

    var leafNames: [String] {
        var names: [String] = []
        collectLeafNames(root, into: &names)
        return names
    }

    /// The set of leaf names reachable beneath `node`, used both as a
    /// building block for `unrootedSplits` and directly for leaf-set
    /// collection.
    private func collectLeafNames(_ node: Node, into names: inout [String]) {
        if node.children.isEmpty, let name = node.name {
            names.append(name)
            return
        }
        for child in node.children {
            collectLeafNames(child, into: &names)
        }
    }

    /// Every internal edge's bipartition of `allLeaves`, normalized so each
    /// split is represented by its smaller side (as a sorted array) and the
    /// whole result is order-independent. This is topology, branch-length,
    /// and root-placement invariant, which is what IQ-TREE's default
    /// unrooted output requires comparing against a rooted `expected.nwk`.
    func unrootedSplits(allLeaves: Set<String>) -> Set<[String]> {
        var splits: Set<[String]> = []
        func visit(_ node: Node) -> Set<String> {
            if node.children.isEmpty, let name = node.name {
                return [name]
            }
            var subtreeLeaves: Set<String> = []
            for child in node.children {
                subtreeLeaves.formUnion(visit(child))
            }
            // Only internal edges that separate the leaf set into two
            // non-trivial groups (both sides >= 2, since the tree is
            // unrooted and a single-leaf split is trivial/always present)
            // carry topological information.
            if subtreeLeaves.count >= 2 && subtreeLeaves.count <= allLeaves.count - 2 {
                let complement = allLeaves.subtracting(subtreeLeaves)
                let canonical = subtreeLeaves.count <= complement.count ? subtreeLeaves : complement
                splits.insert(canonical.sorted())
            }
            return subtreeLeaves
        }
        _ = visit(root)
        return splits
    }

    static func parse(_ text: String) throws -> MinimalNewickTree {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0

        func peek() -> Character? { index < chars.count ? chars[index] : nil }
        func advance() { index += 1 }

        func parseNode() -> Node {
            let node = Node()
            if peek() == "(" {
                advance()
                repeat {
                    node.children.append(parseNode())
                } while peek() == "," && { advance(); return true }()
                if peek() == ")" { advance() }
            }
            // Read label (leaf name or internal support value).
            var label = ""
            while let c = peek(), c != ":" && c != "," && c != ")" && c != ";" {
                label.append(c)
                advance()
            }
            if node.children.isEmpty && !label.isEmpty {
                node.name = label
            }
            // Skip branch length if present.
            if peek() == ":" {
                advance()
                while let c = peek(), c != "," && c != ")" && c != ";" {
                    advance()
                }
            }
            return node
        }

        guard !chars.isEmpty else {
            throw MinimalNewickError.empty
        }
        let root = parseNode()
        return MinimalNewickTree(root: root)
    }
}

enum MinimalNewickError: Error {
    case empty
}
