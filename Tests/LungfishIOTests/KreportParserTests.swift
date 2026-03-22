// KreportParserTests.swift - Tests for Kraken2 kreport parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class KreportParserTests: XCTestCase {

    // MARK: - Minimal Report Parsing

    func testParseMinimalKreport() throws {
        let text = """
          1.00\t10\t10\tU\t0\tunclassified
         99.00\t990\t50\tR\t1\troot
         80.00\t800\t100\tD\t2\t  Bacteria
         60.00\t600\t600\tS\t562\t    Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)

        XCTAssertEqual(tree.totalReads, 1000)
        XCTAssertEqual(tree.classifiedReads, 990)
        XCTAssertEqual(tree.unclassifiedReads, 10)
        XCTAssertNotNil(tree.unclassifiedNode)
        XCTAssertEqual(tree.unclassifiedNode?.readsClade, 10)
        XCTAssertEqual(tree.root.taxId, 1)
        XCTAssertEqual(tree.root.name, "root")
    }

    func testTreeStructureFromIndentation() throws {
        let text = """
         99.99\t9999\t100\tR\t1\troot
         95.00\t9500\t200\tD\t2\t  Bacteria
         80.00\t8000\t50\tP\t1224\t    Proteobacteria
         60.00\t6000\t600\tG\t561\t      Escherichia
         35.00\t3500\t3500\tS\t562\t        Escherichia coli
         10.00\t1000\t50\tP\t1239\t    Firmicutes
          5.00\t500\t500\tS\t1423\t      Bacillus subtilis
        """

        let tree = try KreportParser.parse(text: text)

        // Root should have one child: Bacteria
        XCTAssertEqual(tree.root.children.count, 1)
        let bacteria = tree.root.children[0]
        XCTAssertEqual(bacteria.name, "Bacteria")
        XCTAssertEqual(bacteria.taxId, 2)

        // Bacteria should have two children: Proteobacteria and Firmicutes
        XCTAssertEqual(bacteria.children.count, 2)
        XCTAssertEqual(bacteria.children[0].name, "Proteobacteria")
        XCTAssertEqual(bacteria.children[1].name, "Firmicutes")

        // Proteobacteria -> Escherichia -> E. coli
        let proteo = bacteria.children[0]
        XCTAssertEqual(proteo.children.count, 1)
        let escherichia = proteo.children[0]
        XCTAssertEqual(escherichia.name, "Escherichia")
        XCTAssertEqual(escherichia.children.count, 1)
        XCTAssertEqual(escherichia.children[0].name, "Escherichia coli")

        // Firmicutes -> B. subtilis
        let firmicutes = bacteria.children[1]
        XCTAssertEqual(firmicutes.children.count, 1)
        XCTAssertEqual(firmicutes.children[0].name, "Bacillus subtilis")

        // Parent links
        XCTAssertNil(tree.root.parent)
        XCTAssertTrue(bacteria.parent === tree.root)
        XCTAssertTrue(proteo.parent === bacteria)
        XCTAssertTrue(escherichia.parent === proteo)
    }

    func testSubspeciesRanks() throws {
        let text = """
         99.99\t9999\t100\tR\t1\troot
         95.00\t9500\t200\tD\t2\t  Bacteria
         35.00\t3500\t500\tS\t562\t    Escherichia coli
         10.00\t1000\t1000\tS1\t83333\t      Escherichia coli K-12
          5.00\t500\t500\tS2\t511145\t        Escherichia coli K-12 MG1655
        """

        let tree = try KreportParser.parse(text: text)

        let ecoli = tree.node(taxId: 562)
        XCTAssertNotNil(ecoli)
        XCTAssertEqual(ecoli?.rank, .species)
        XCTAssertEqual(ecoli?.children.count, 1)

        let k12 = tree.node(taxId: 83333)
        XCTAssertNotNil(k12)
        XCTAssertEqual(k12?.rank, .intermediate("S1"))
        XCTAssertTrue(k12?.parent === ecoli)
        XCTAssertEqual(k12?.children.count, 1)

        let mg1655 = tree.node(taxId: 511145)
        XCTAssertNotNil(mg1655)
        XCTAssertEqual(mg1655?.rank, .intermediate("S2"))
        XCTAssertTrue(mg1655?.parent === k12)
    }

    func testCladeSumConsistency() throws {
        let text = """
          0.50\t50\t50\tU\t0\tunclassified
         99.50\t9950\t100\tR\t1\troot
         95.00\t9500\t200\tD\t2\t  Bacteria
         35.00\t3500\t500\tS\t562\t    Escherichia coli
         60.00\t6000\t300\tD\t2157\t  Archaea
         30.00\t3000\t3000\tS\t2253\t    Haloferax volcanii
        """

        let tree = try KreportParser.parse(text: text)

        // For every node, readsClade should be >= readsDirect
        for node in tree.allNodes() {
            XCTAssertGreaterThanOrEqual(
                node.readsClade, node.readsDirect,
                "Node \(node.name) has readsClade (\(node.readsClade)) < readsDirect (\(node.readsDirect))"
            )
        }
    }

    func testFractionsSumApproximatelyToOne() throws {
        let text = """
          0.50\t50\t50\tU\t0\tunclassified
         99.50\t9950\t100\tR\t1\troot
         95.00\t9500\t200\tD\t2\t  Bacteria
         60.00\t6000\t6000\tS\t562\t    Escherichia coli
          4.50\t450\t450\tD\t2157\t  Archaea
        """

        let tree = try KreportParser.parse(text: text)

        // Root fraction + unclassified fraction should be approximately 1.0
        let total = tree.root.fractionClade + tree.unclassifiedFraction
        XCTAssertEqual(total, 1.0, accuracy: 0.001,
                       "Root clade fraction + unclassified fraction should sum to ~1.0")
    }

    func testAllNodesFlattening() throws {
        let text = """
        100.00\t1000\t100\tR\t1\troot
         90.00\t900\t50\tD\t2\t  Bacteria
         80.00\t800\t100\tP\t1224\t    Proteobacteria
         60.00\t600\t600\tS\t562\t      Escherichia coli
         10.00\t100\t100\tP\t1239\t    Firmicutes
        """

        let tree = try KreportParser.parse(text: text)

        let allNodes = tree.allNodes()
        // Should return all 5 nodes in pre-order
        XCTAssertEqual(allNodes.count, 5)
        XCTAssertEqual(allNodes[0].name, "root")
        XCTAssertEqual(allNodes[1].name, "Bacteria")
        XCTAssertEqual(allNodes[2].name, "Proteobacteria")
        XCTAssertEqual(allNodes[3].name, "Escherichia coli")
        XCTAssertEqual(allNodes[4].name, "Firmicutes")
    }

    func testNodeLookupByTaxid() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         90.00\t9000\t200\tD\t2\t  Bacteria
         60.00\t6000\t600\tS\t562\t    Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)

        // Find existing nodes
        XCTAssertNotNil(tree.node(taxId: 1))
        XCTAssertEqual(tree.node(taxId: 1)?.name, "root")

        XCTAssertNotNil(tree.node(taxId: 562))
        XCTAssertEqual(tree.node(taxId: 562)?.name, "Escherichia coli")

        // Find non-existent node
        XCTAssertNil(tree.node(taxId: 99999))

        // Find unclassified node (taxId 0 not in this report)
        XCTAssertNil(tree.node(taxId: 0))
    }

    func testNodesAtRank() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         90.00\t9000\t200\tD\t2\t  Bacteria
         60.00\t6000\t100\tG\t561\t    Escherichia
         50.00\t5000\t5000\tS\t562\t      Escherichia coli
         10.00\t1000\t100\tG\t590\t    Salmonella
          8.00\t800\t800\tS\t28901\t      Salmonella enterica
         10.00\t1000\t200\tD\t2157\t  Archaea
          5.00\t500\t500\tS\t2253\t    Haloferax volcanii
        """

        let tree = try KreportParser.parse(text: text)

        let species = tree.nodes(at: .species)
        XCTAssertEqual(species.count, 3)
        let speciesNames = Set(species.map(\.name))
        XCTAssertTrue(speciesNames.contains("Escherichia coli"))
        XCTAssertTrue(speciesNames.contains("Salmonella enterica"))
        XCTAssertTrue(speciesNames.contains("Haloferax volcanii"))

        let genera = tree.nodes(at: .genus)
        XCTAssertEqual(genera.count, 2)

        let domains = tree.nodes(at: .domain)
        XCTAssertEqual(domains.count, 2)
    }

    // MARK: - Error Handling

    func testEmptyKreportThrows() throws {
        XCTAssertThrowsError(try KreportParser.parse(text: "")) { error in
            XCTAssertTrue(error is KreportParserError)
            if let kreportError = error as? KreportParserError {
                switch kreportError {
                case .emptyReport:
                    break // Expected
                default:
                    XCTFail("Expected emptyReport error, got \(kreportError)")
                }
            }
        }
    }

    func testEmptyKreportOnlyWhitespace() throws {
        XCTAssertThrowsError(try KreportParser.parse(text: "   \n\n   \n")) { error in
            XCTAssertTrue(error is KreportParserError)
        }
    }

    func testParseMalformedLineSkipped() throws {
        // Line 2 has too few columns -- it should be skipped
        let text = """
        100.00\t10000\t100\tR\t1\troot
        this is not a valid line
         90.00\t9000\t200\tD\t2\t  Bacteria
        """

        let tree = try KreportParser.parse(text: text)
        // Root + Bacteria should be parsed, malformed line skipped
        XCTAssertEqual(tree.allNodes().count, 2)
        XCTAssertEqual(tree.root.name, "root")
        XCTAssertEqual(tree.root.children.first?.name, "Bacteria")
    }

    func testParseCommentLinesSkipped() throws {
        let text = """
        # This is a comment
        100.00\t10000\t100\tR\t1\troot
         90.00\t9000\t9000\tD\t2\t  Bacteria
        """

        let tree = try KreportParser.parse(text: text)
        XCTAssertEqual(tree.allNodes().count, 2)
    }

    // MARK: - Rank Code Mapping

    func testRankCodeMapping() throws {
        let text = """
          1.00\t100\t100\tU\t0\tunclassified
         99.00\t9900\t50\tR\t1\troot
         95.00\t9500\t10\tR1\t131567\t  cellular organisms
         90.00\t9000\t20\tD\t2\t    Bacteria
         80.00\t8000\t30\tD1\t1783270\t      FCB group
         70.00\t7000\t40\tK\t33154\t        some kingdom
         60.00\t6000\t50\tP\t1224\t          Proteobacteria
         50.00\t5000\t60\tP1\t1234\t            some subphylum
         40.00\t4000\t70\tC\t1236\t              Gammaproteobacteria
         30.00\t3000\t80\tO\t91347\t                Enterobacterales
         20.00\t2000\t90\tF\t543\t                  Enterobacteriaceae
         10.00\t1000\t100\tG\t561\t                    Escherichia
          5.00\t500\t500\tS\t562\t                      Escherichia coli
          2.00\t200\t200\tS1\t83333\t                        Escherichia coli K-12
        """

        let tree = try KreportParser.parse(text: text)

        // Check rank assignments
        XCTAssertEqual(tree.root.rank, .root)
        XCTAssertEqual(tree.node(taxId: 131567)?.rank, .intermediate("R1"))
        XCTAssertEqual(tree.node(taxId: 2)?.rank, .domain)
        XCTAssertEqual(tree.node(taxId: 1783270)?.rank, .intermediate("D1"))
        XCTAssertEqual(tree.node(taxId: 33154)?.rank, .kingdom)
        XCTAssertEqual(tree.node(taxId: 1224)?.rank, .phylum)
        XCTAssertEqual(tree.node(taxId: 1234)?.rank, .intermediate("P1"))
        XCTAssertEqual(tree.node(taxId: 1236)?.rank, .class)
        XCTAssertEqual(tree.node(taxId: 91347)?.rank, .order)
        XCTAssertEqual(tree.node(taxId: 543)?.rank, .family)
        XCTAssertEqual(tree.node(taxId: 561)?.rank, .genus)
        XCTAssertEqual(tree.node(taxId: 562)?.rank, .species)
        XCTAssertEqual(tree.node(taxId: 83333)?.rank, .intermediate("S1"))
    }

    // MARK: - Unclassified Reads

    func testUnclassifiedReads() throws {
        let text = """
         25.00\t2500\t2500\tU\t0\tunclassified
         75.00\t7500\t100\tR\t1\troot
         50.00\t5000\t5000\tS\t562\t  Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)

        XCTAssertEqual(tree.totalReads, 10000)
        XCTAssertEqual(tree.unclassifiedReads, 2500)
        XCTAssertEqual(tree.classifiedReads, 7500)
        XCTAssertNotNil(tree.unclassifiedNode)
        XCTAssertEqual(tree.unclassifiedNode?.name, "unclassified")
        XCTAssertEqual(tree.unclassifiedNode?.rank, .unclassified)

        // Unclassified fraction
        XCTAssertEqual(tree.unclassifiedFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(tree.classifiedFraction, 0.75, accuracy: 0.001)
    }

    func testNoUnclassifiedNode() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         99.00\t9900\t9900\tS\t562\t  Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)

        XCTAssertNil(tree.unclassifiedNode)
        XCTAssertEqual(tree.unclassifiedReads, 0)
        XCTAssertEqual(tree.totalReads, 10000)
    }

    // MARK: - Real-World Report (Fixture)

    func testParseRealWorldReport() throws {
        guard let url = Bundle.module.url(
            forResource: "sample",
            withExtension: "kreport",
            subdirectory: "Resources"
        ) else {
            XCTFail("Could not find sample.kreport test fixture")
            return
        }

        let tree = try KreportParser.parse(url: url)

        // Verify structure
        XCTAssertEqual(tree.totalReads, 10000)
        XCTAssertEqual(tree.unclassifiedReads, 50)
        XCTAssertEqual(tree.classifiedReads, 9950)
        XCTAssertNotNil(tree.unclassifiedNode)

        // Root
        XCTAssertEqual(tree.root.taxId, 1)
        XCTAssertEqual(tree.root.readsClade, 9950)

        // Domains: Bacteria and Archaea
        let domains = tree.nodes(at: .domain)
        XCTAssertEqual(domains.count, 2)
        let domainNames = Set(domains.map(\.name))
        XCTAssertTrue(domainNames.contains("Bacteria"))
        XCTAssertTrue(domainNames.contains("Archaea"))

        // Species
        let species = tree.nodes(at: .species)
        XCTAssertEqual(species.count, 7)
        let speciesNames = Set(species.map(\.name))
        XCTAssertTrue(speciesNames.contains("Escherichia coli"))
        XCTAssertTrue(speciesNames.contains("Salmonella enterica"))
        XCTAssertTrue(speciesNames.contains("Pseudomonas aeruginosa"))
        XCTAssertTrue(speciesNames.contains("Pseudomonas fluorescens"))
        XCTAssertTrue(speciesNames.contains("Bacillus subtilis"))
        XCTAssertTrue(speciesNames.contains("Bacillus anthracis"))
        XCTAssertTrue(speciesNames.contains("Haloferax volcanii"))

        // Subspecies (intermediate ranks)
        let ecoli = tree.node(taxId: 562)
        XCTAssertNotNil(ecoli)
        XCTAssertEqual(ecoli?.children.count, 1)
        XCTAssertEqual(ecoli?.children.first?.rank, .intermediate("S1"))

        // Dominant species
        XCTAssertEqual(tree.dominantSpecies?.name, "Escherichia coli")
        XCTAssertEqual(tree.dominantSpecies?.readsClade, 3500)

        // Genera count
        XCTAssertEqual(tree.generaCount, 5) // Escherichia, Salmonella, Pseudomonas, Bacillus, Haloferax
    }

    // MARK: - Statistics

    func testSpeciesCount() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         60.00\t6000\t200\tD\t2\t  Bacteria
         50.00\t5000\t5000\tS\t562\t    Escherichia coli
          8.00\t800\t800\tS\t287\t    Pseudomonas aeruginosa
         30.00\t3000\t200\tD\t2157\t  Archaea
         20.00\t2000\t2000\tS\t2253\t    Haloferax volcanii
        """

        let tree = try KreportParser.parse(text: text)
        XCTAssertEqual(tree.speciesCount, 3)
    }

    func testDominantSpecies() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         60.00\t6000\t100\tD\t2\t  Bacteria
         50.00\t5000\t5000\tS\t562\t    Escherichia coli
          8.00\t800\t800\tS\t287\t    Pseudomonas aeruginosa
        """

        let tree = try KreportParser.parse(text: text)

        XCTAssertNotNil(tree.dominantSpecies)
        XCTAssertEqual(tree.dominantSpecies?.name, "Escherichia coli")
        XCTAssertEqual(tree.dominantSpecies?.readsClade, 5000)
    }

    func testDominantSpeciesNilWhenNoSpecies() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         60.00\t6000\t6000\tD\t2\t  Bacteria
        """

        let tree = try KreportParser.parse(text: text)
        XCTAssertNil(tree.dominantSpecies)
    }

    func testShannonDiversity() throws {
        // Two equally abundant species: H' = ln(2) ~= 0.693
        let text = """
        100.00\t1000\t0\tR\t1\troot
         50.00\t500\t500\tS\t562\t  Escherichia coli
         50.00\t500\t500\tS\t287\t  Pseudomonas aeruginosa
        """

        let tree = try KreportParser.parse(text: text)
        XCTAssertEqual(tree.shannonDiversity, log(2.0), accuracy: 0.001)
    }

    func testSimpsonDiversity() throws {
        // Two equally abundant species: 1-D = 1 - 2*(0.5^2) = 0.5
        let text = """
        100.00\t1000\t0\tR\t1\troot
         50.00\t500\t500\tS\t562\t  Escherichia coli
         50.00\t500\t500\tS\t287\t  Pseudomonas aeruginosa
        """

        let tree = try KreportParser.parse(text: text)
        XCTAssertEqual(tree.simpsonDiversity, 0.5, accuracy: 0.001)
    }

    func testDiversityWithSingleSpecies() throws {
        // Single species: H' = 0, Simpson = 0
        let text = """
        100.00\t1000\t0\tR\t1\troot
        100.00\t1000\t1000\tS\t562\t  Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)
        XCTAssertEqual(tree.shannonDiversity, 0.0)
        XCTAssertEqual(tree.simpsonDiversity, 0.0)
    }

    // MARK: - Name Search

    func testFindByName() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         60.00\t6000\t100\tD\t2\t  Bacteria
         50.00\t5000\t5000\tS\t562\t    Escherichia coli
          8.00\t800\t800\tS\t287\t    Pseudomonas aeruginosa
        """

        let tree = try KreportParser.parse(text: text)

        // Case-insensitive substring search
        let results = tree.find(name: "escherichia")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.taxId, 562)

        // Partial match
        let partial = tree.find(name: "aerugi")
        XCTAssertEqual(partial.count, 1)
        XCTAssertEqual(partial.first?.taxId, 287)

        // No match
        let none = tree.find(name: "nonexistent")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Node Traversal

    func testPathFromRoot() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         90.00\t9000\t200\tD\t2\t  Bacteria
         80.00\t8000\t100\tP\t1224\t    Proteobacteria
         60.00\t6000\t600\tG\t561\t      Escherichia
         35.00\t3500\t3500\tS\t562\t        Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)

        let ecoli = tree.node(taxId: 562)!
        let path = ecoli.pathFromRoot()
        XCTAssertEqual(path.count, 5)
        XCTAssertEqual(path[0].name, "root")
        XCTAssertEqual(path[1].name, "Bacteria")
        XCTAssertEqual(path[2].name, "Proteobacteria")
        XCTAssertEqual(path[3].name, "Escherichia")
        XCTAssertEqual(path[4].name, "Escherichia coli")
    }

    func testLeafNodes() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         60.00\t6000\t100\tD\t2\t  Bacteria
         50.00\t5000\t5000\tS\t562\t    Escherichia coli
          8.00\t800\t800\tS\t287\t    Pseudomonas aeruginosa
         30.00\t3000\t3000\tD\t2157\t  Archaea
        """

        let tree = try KreportParser.parse(text: text)

        let leaves = tree.root.leaves()
        XCTAssertEqual(leaves.count, 3)
        let leafNames = Set(leaves.map(\.name))
        XCTAssertTrue(leafNames.contains("Escherichia coli"))
        XCTAssertTrue(leafNames.contains("Pseudomonas aeruginosa"))
        XCTAssertTrue(leafNames.contains("Archaea")) // leaf because it has no children
    }

    // MARK: - Indentation Depth

    func testIndentationDepthCounting() {
        XCTAssertEqual(KreportParser.countIndentationDepth("root"), 0)
        XCTAssertEqual(KreportParser.countIndentationDepth("  Bacteria"), 1)
        XCTAssertEqual(KreportParser.countIndentationDepth("    Proteobacteria"), 2)
        XCTAssertEqual(KreportParser.countIndentationDepth("      Gammaproteobacteria"), 3)
        XCTAssertEqual(KreportParser.countIndentationDepth("        Enterobacterales"), 4)
    }

    // MARK: - Edge Cases

    func testOnlyUnclassifiedThrows() throws {
        // Only an unclassified line with no classified data
        let text = """
        100.00\t10000\t10000\tU\t0\tunclassified
        """

        XCTAssertThrowsError(try KreportParser.parse(text: text)) { error in
            XCTAssertTrue(error is KreportParserError)
        }
    }

    func testSingleRootNode() throws {
        let text = """
        100.00\t10000\t10000\tR\t1\troot
        """

        let tree = try KreportParser.parse(text: text)
        XCTAssertEqual(tree.root.taxId, 1)
        XCTAssertEqual(tree.root.children.count, 0)
        XCTAssertEqual(tree.totalReads, 10000)
        XCTAssertNil(tree.unclassifiedNode)
    }

    func testUnclassifiedNodeLookup() throws {
        let text = """
         50.00\t5000\t5000\tU\t0\tunclassified
         50.00\t5000\t5000\tR\t1\troot
        """

        let tree = try KreportParser.parse(text: text)

        // Unclassified should be findable by taxId
        let unclassified = tree.node(taxId: 0)
        XCTAssertNotNil(unclassified)
        XCTAssertEqual(unclassified?.name, "unclassified")
        XCTAssertEqual(unclassified?.rank, .unclassified)
    }

    // MARK: - TaxonNode Equality and Hashing

    func testNodeEquality() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         50.00\t5000\t5000\tS\t562\t  Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)
        let ecoli1 = tree.node(taxId: 562)
        let ecoli2 = tree.node(taxId: 562)

        XCTAssertEqual(ecoli1, ecoli2)
        XCTAssertNotEqual(ecoli1, tree.root)
    }

    func testNodeHashing() throws {
        let text = """
        100.00\t10000\t100\tR\t1\troot
         50.00\t5000\t5000\tS\t562\t  Escherichia coli
          8.00\t800\t800\tS\t287\t  Pseudomonas aeruginosa
        """

        let tree = try KreportParser.parse(text: text)

        var nodeSet: Set<TaxonNode> = []
        for node in tree.allNodes() {
            nodeSet.insert(node)
        }
        XCTAssertEqual(nodeSet.count, 3)
    }

    // MARK: - TaxonTree Description

    func testTreeDescription() throws {
        let text = """
          1.00\t100\t100\tU\t0\tunclassified
         99.00\t9900\t100\tR\t1\troot
         60.00\t6000\t6000\tS\t562\t  Escherichia coli
        """

        let tree = try KreportParser.parse(text: text)
        let desc = tree.description

        XCTAssertTrue(desc.contains("totalReads: 10000"))
        XCTAssertTrue(desc.contains("classified: 9900"))
        XCTAssertTrue(desc.contains("unclassified: 100"))
    }
}
