import Foundation
import XCTest
@testable import LungfishIO

/// Support labels, inference summaries, tip relabelling and quoting for IQ-TREE trees (rulings C3, C8, V1, V3).
final class PhylogeneticTreeSupportLabelTests: XCTestCase {
    private var workspaceURL: URL!

    /// The tree IQ-TREE 3.1.3 wrote next to Tests/Fixtures/phylogenetics/known-sarcopterygian/run.iqtree.
    private static let fixtureTreefile = "(Zebrafish_outgroup:0.5678569639,Coelacanth:0.0000010000,((Australian_lungfish:0.0445526797,African_lungfish:0.0445804337)99.9/100:0.3503482907,(Human:0.0000023147,Frog:0.0412925004)0/30:0.0000010000)99.7/100:0.3388885235);"

    private static let pairLabels = ["SH-aLRT", "UFBoot"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspaceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/tree-support-label-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceURL, FileManager.default.fileExists(atPath: workspaceURL.path) {
            try FileManager.default.removeItem(at: workspaceURL)
        }
        try super.tearDownWithError()
    }

    // MARK: - Normalisation (V1)

    func testIQTreeSupportPairsSplitIntoTypedValuesWithUFBootAsPrimary() throws {
        let bundle = try importTree(Self.fixtureTreefile, options: .init(supportLabels: Self.pairLabels))

        let lungfish = try XCTUnwrap(node(of: bundle, withDescendantTips: ["Australian_lungfish", "African_lungfish"]))
        XCTAssertEqual(lungfish.supportValues, [
            PhylogeneticTreeSupportValue(label: "SH-aLRT", rawValue: "99.9", value: 99.9),
            PhylogeneticTreeSupportValue(label: "UFBoot", rawValue: "100", value: 100)
        ])
        XCTAssertEqual(lungfish.support, PhylogeneticTreeSupport(rawValue: "100", interpretation: "UFBoot"))

        // SH-aLRT 0 is an integer 0, and with labels recorded it is never read as a posterior.
        let tetrapods = try XCTUnwrap(node(of: bundle, withDescendantTips: ["Human", "Frog"]))
        XCTAssertEqual(tetrapods.supportValues.map(\.label), ["SH-aLRT", "UFBoot"])
        XCTAssertEqual(tetrapods.supportValues.map(\.value), [0, 30])
        XCTAssertEqual(tetrapods.support, PhylogeneticTreeSupport(rawValue: "30", interpretation: "UFBoot"))
        XCTAssertFalse(bundle.manifest.warnings.contains { $0.contains("posterior") || $0.contains("unknown interpretation") })

        let tip = try XCTUnwrap(bundle.normalizedTree.nodes.first { $0.displayLabel == "Human" })
        XCTAssertEqual(tip.supportValues, [])
        XCTAssertNil(tip.support)
    }

    func testSHaLRTOnlyLabelsAreNotBootstrapAndOneIsNotAPosterior() throws {
        let bundle = try importTree("((A:0.1,B:0.1)85:0.2,(C:0.1,D:0.1)1:0.2,E:0.3);", options: .init(supportLabels: ["SH-aLRT"]))

        let ab = try XCTUnwrap(node(of: bundle, withDescendantTips: ["A", "B"]))
        XCTAssertEqual(ab.support, PhylogeneticTreeSupport(rawValue: "85", interpretation: "SH-aLRT"))
        XCTAssertEqual(ab.supportValues, [PhylogeneticTreeSupportValue(label: "SH-aLRT", rawValue: "85", value: 85)])
        let cd = try XCTUnwrap(node(of: bundle, withDescendantTips: ["C", "D"]))
        XCTAssertEqual(cd.support, PhylogeneticTreeSupport(rawValue: "1", interpretation: "SH-aLRT"))
        XCTAssertFalse(bundle.manifest.warnings.contains { $0.contains("posterior") })
    }

    func testThreeLabelsSplitInIQTreeOrder() throws {
        let bundle = try importTree(
            "((A:0.1,B:0.1)80.5/0.97/99:0.2,C:0.1,D:0.1);",
            options: .init(supportLabels: ["SH-aLRT", "aBayes", "UFBoot"])
        )
        let ab = try XCTUnwrap(node(of: bundle, withDescendantTips: ["A", "B"]))
        XCTAssertEqual(ab.supportValues.map(\.label), ["SH-aLRT", "aBayes", "UFBoot"])
        XCTAssertEqual(ab.supportValues.map(\.value), [80.5, 0.97, 99])
        XCTAssertEqual(ab.support, PhylogeneticTreeSupport(rawValue: "99", interpretation: "UFBoot"))
    }

    func testFirstLabelIsPrimaryWhenUFBootIsAbsent() throws {
        let bundle = try importTree("((A:0.1,B:0.1)80/0.9:0.2,C:0.1,D:0.1);", options: .init(supportLabels: ["SH-aLRT", "aBayes"]))
        let ab = try XCTUnwrap(node(of: bundle, withDescendantTips: ["A", "B"]))
        XCTAssertEqual(ab.support, PhylogeneticTreeSupport(rawValue: "80", interpretation: "SH-aLRT"))
    }

    func testLabelCountMismatchIsUnknownWithoutTypedValues() throws {
        let bundle = try importTree("((A:0.1,B:0.1)80/90/70:0.2,C:0.1,D:0.1);", options: .init(supportLabels: Self.pairLabels))
        let ab = try XCTUnwrap(node(of: bundle, withDescendantTips: ["A", "B"]))
        XCTAssertEqual(ab.supportValues, [])
        XCTAssertEqual(ab.support?.interpretation, "unknown")
    }

    func testWithoutLabelsTodaysGuessStays() throws {
        let bundle = try importTree(Self.fixtureTreefile, options: .init())
        XCTAssertNil(bundle.manifest.supportLabels)
        let lungfish = try XCTUnwrap(node(of: bundle, withDescendantTips: ["Australian_lungfish", "African_lungfish"]))
        XCTAssertEqual(lungfish.supportValues, [])
        XCTAssertEqual(lungfish.support?.interpretation, "unknown")

        let plain = try importTree("((A:0.1,B:0.1)90:0.2,(C:0.1,D:0.1)1:0.2,E:0.3);", options: .init())
        XCTAssertEqual(try XCTUnwrap(node(of: plain, withDescendantTips: ["A", "B"])).support?.interpretation, "bootstrap")
        XCTAssertEqual(try XCTUnwrap(node(of: plain, withDescendantTips: ["C", "D"])).support?.interpretation, "posterior")
    }

    // MARK: - Manifest and import options (C8)

    func testImportRecordsSupportLabelsUnitAndInferenceSummaryAndReloads() throws {
        let summary = Self.sampleSummary()
        let bundle = try importTree(
            Self.fixtureTreefile,
            options: .init(
                supportLabels: Self.pairLabels,
                branchLengthUnit: "substitutions per site",
                inference: summary
            )
        )
        XCTAssertEqual(bundle.manifest.supportLabels, Self.pairLabels)
        XCTAssertEqual(bundle.manifest.branchLengthUnit, "substitutions per site")
        XCTAssertEqual(bundle.manifest.inference, summary)

        // createdAt is written as whole-second ISO 8601, so compare the recorded fields.
        let reloaded = try PhylogeneticTreeBundle.load(from: bundle.url)
        XCTAssertEqual(reloaded.manifest.supportLabels, Self.pairLabels)
        XCTAssertEqual(reloaded.manifest.branchLengthUnit, "substitutions per site")
        XCTAssertEqual(reloaded.manifest.inference, summary)
        XCTAssertEqual(reloaded.normalizedTree, bundle.normalizedTree)
    }

    func testBundlesWrittenBeforeSupportLabelsStillLoad() throws {
        let bundle = try importTree(
            Self.fixtureTreefile,
            options: .init(supportLabels: Self.pairLabels, branchLengthUnit: "substitutions per site", inference: Self.sampleSummary())
        )
        try removeKeys(["supportLabels", "inference"], fromJSONAt: bundle.url.appendingPathComponent("manifest.json"))
        try removeKeys(["supportValues"], fromJSONAt: bundle.url.appendingPathComponent("tree/primary.normalized.json"))

        let reloaded = try PhylogeneticTreeBundle.load(from: bundle.url)
        XCTAssertNil(reloaded.manifest.supportLabels)
        XCTAssertNil(reloaded.manifest.inference)
        XCTAssertTrue(reloaded.normalizedTree.nodes.allSatisfy { $0.supportValues.isEmpty })
    }

    func testTreesWithoutSupportLabelsWriteNoSupportValuesKey() throws {
        let bundle = try importTree("((A:0.1,B:0.1)90:0.2,C:0.1,D:0.1);", options: .init())
        let normalizedText = try String(
            contentsOf: bundle.url.appendingPathComponent("tree/primary.normalized.json"),
            encoding: .utf8
        )
        let manifestText = try String(contentsOf: bundle.url.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(normalizedText.contains("supportValues"))
        XCTAssertFalse(manifestText.contains("supportLabels"))
        XCTAssertFalse(manifestText.contains("inference"))
    }

    // MARK: - Tip relabelling and quoting (C3)

    func testTipLabelMapRelabelsTipsAndDisplayNamesRoundTripThroughNewick() throws {
        let staged = "(t0001:0.5,t0002:0.1,((t0003:0.04,t0004:0.04)99.9/100:0.35,(t0005:0.01,t0006:0.04)0/30:0.01)99.7/100:0.33);"
        let map = [
            "t0001": "Zebrafish (outgroup)",
            "t0002": "Coelacanth",
            "t0003": "Lungfish: Australian",
            "t0004": "Lungfish, African",
            "t0005": "O'Brien's human; sample 1",
        ]
        let bundle = try importTree(staged, options: .init(supportLabels: Self.pairLabels, tipLabelMap: map))

        let expectedTips = Set(map.values).union(["t0006"])
        XCTAssertEqual(Set(tipLabels(of: bundle)), expectedTips)
        XCTAssertEqual(try XCTUnwrap(bundle.normalizedTree.nodes.first { $0.rawLabel == "t0003" }).displayLabel, "Lungfish: Australian")

        let primaryNewick = try String(contentsOf: bundle.url.appendingPathComponent("tree/primary.nwk"), encoding: .utf8)
        XCTAssertTrue(primaryNewick.contains("'O''Brien''s human; sample 1'"))
        XCTAssertTrue(primaryNewick.contains("99.9/100:"), "support pairs stay unquoted")
        let reparsed = try importTree(primaryNewick, options: .init(supportLabels: Self.pairLabels))
        XCTAssertEqual(Set(tipLabels(of: reparsed)), expectedTips)
        XCTAssertEqual(
            try XCTUnwrap(node(of: reparsed, withDescendantTips: ["Lungfish: Australian", "Lungfish, African"])).supportValues.map(\.value),
            [99.9, 100]
        )

        let subtree = try bundle.subtreeNewick(
            nodeID: try XCTUnwrap(node(of: bundle, withDescendantTips: ["O'Brien's human; sample 1", "t0006"])).id
        )
        let subtreeBundle = try importTree(subtree, options: .init())
        XCTAssertEqual(Set(tipLabels(of: subtreeBundle)), ["O'Brien's human; sample 1", "t0006"])
    }

    func testTipLabelMapNamingAMissingTipFailsWithoutPartialBundle() throws {
        let sourceURL = try writeSource("(t0001:0.1,t0002:0.1,t0003:0.1);")
        let destination = workspaceURL.appendingPathComponent("Missing.lungfishtree", isDirectory: true)
        XCTAssertThrowsError(
            try PhylogeneticTreeBundleImporter.importTree(
                from: sourceURL,
                to: destination,
                options: .init(tipLabelMap: ["t0001": "Human", "t0009": "Frog"])
            )
        ) { error in
            XCTAssertEqual(error as? PhylogeneticTreeBundleError, .tipLabelNotFound("t0009"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Rooting data (V3)

    func testIQTreeBasalTrifurcationImportsAsUnrooted() throws {
        let bundle = try importTree(
            Self.fixtureTreefile,
            options: .init(supportLabels: Self.pairLabels, tipLabelMap: ["Human": "Homo sapiens"])
        )
        XCTAssertFalse(bundle.manifest.isRooted)
        XCTAssertFalse(bundle.normalizedTree.rooted)
    }

    // MARK: - Transforms (item 7)

    /// Fix M1. Extract drops the inference summary because its likelihood and scope describe the
    /// whole tree. Reroot keeps it but clears the outgroup, which no longer roots the tree.
    /// Every transform keeps the support labels, which still describe the node labels.
    func testTransformsKeepSupportLabelsAndAdjustTheInferenceSummary() throws {
        let summary = Self.sampleSummary()
        let source = try importTree(
            Self.fixtureTreefile,
            options: .init(supportLabels: Self.pairLabels, branchLengthUnit: "substitutions per site", inference: summary)
        )
        let lungfishID = try XCTUnwrap(node(of: source, withDescendantTips: ["Australian_lungfish", "African_lungfish"])).id
        let cladeID = try XCTUnwrap(
            node(of: source, withDescendantTips: ["Australian_lungfish", "African_lungfish", "Human", "Frog"])
        ).id
        try """
        id\tcommon
        Zebrafish_outgroup\tzebrafish
        Coelacanth\tcoelacanth
        Australian_lungfish\tqueensland lungfish
        African_lungfish\tmarbled lungfish
        Human\thuman
        Frog\tfrog
        """.write(to: source.url.appendingPathComponent("metadata.tsv"), atomically: true, encoding: .utf8)

        let rerooted = try source.rerootedBundle(
            on: lungfishID,
            to: workspaceURL.appendingPathComponent("Rerooted.lungfishtree", isDirectory: true),
            provenance: .init(toolName: "lungfish tree reroot", argv: [])
        )
        let extracted = try source.extractSubtreeBundle(
            nodeID: cladeID,
            to: workspaceURL.appendingPathComponent("Extracted.lungfishtree", isDirectory: true),
            provenance: .init(toolName: "lungfish tree extract-subtree", argv: [])
        )
        let relabeled = try source.relabeledBundle(
            column: "common",
            to: workspaceURL.appendingPathComponent("Relabeled.lungfishtree", isDirectory: true),
            provenance: .init(toolName: "lungfish tree relabel", argv: [])
        )

        XCTAssertNil(extracted.manifest.inference)
        XCTAssertNil(try PhylogeneticTreeBundle.load(from: extracted.url).manifest.inference)

        let rerootedInference = try XCTUnwrap(rerooted.manifest.inference)
        XCTAssertNil(rerootedInference.outgroup)
        XCTAssertNil(rerootedInference.outgroupWarning)
        XCTAssertEqual(rerootedInference, Self.sampleSummary(outgroup: nil, outgroupWarning: nil))
        XCTAssertEqual(try PhylogeneticTreeBundle.load(from: rerooted.url).manifest.inference, rerootedInference)

        XCTAssertEqual(relabeled.manifest.inference, summary)
        XCTAssertEqual(try PhylogeneticTreeBundle.load(from: relabeled.url).manifest.inference, summary)

        for derived in [rerooted, extracted, relabeled] {
            XCTAssertEqual(derived.manifest.supportLabels, Self.pairLabels)
            XCTAssertEqual(derived.manifest.branchLengthUnit, "substitutions per site")
            let reloaded = try PhylogeneticTreeBundle.load(from: derived.url)
            XCTAssertEqual(reloaded.manifest.supportLabels, Self.pairLabels)
            XCTAssertEqual(reloaded.normalizedTree, derived.normalizedTree)
        }
        for derived in [rerooted, extracted] {
            let tetrapods = try XCTUnwrap(node(of: derived, withDescendantTips: ["Human", "Frog"]))
            XCTAssertEqual(tetrapods.supportValues.map(\.value), [0, 30])
            XCTAssertEqual(tetrapods.support?.interpretation, "UFBoot")
        }
    }

    func testRerootOfATreeWithAnOutgroupWarningClearsTheWarning() throws {
        let summary = Self.sampleSummary(outgroupWarning: "The outgroup (Zebrafish_outgroup) is not monophyletic in the inferred tree, so the tree was saved unrooted.")
        let source = try importTree(Self.fixtureTreefile, options: .init(supportLabels: Self.pairLabels, inference: summary))
        let rerooted = try source.rerootedBundle(
            on: "Coelacanth",
            to: workspaceURL.appendingPathComponent("Rerooted.lungfishtree", isDirectory: true),
            provenance: .init(toolName: "lungfish tree reroot", argv: [])
        )
        let inference = try XCTUnwrap(rerooted.manifest.inference)
        XCTAssertNil(inference.outgroup)
        XCTAssertNil(inference.outgroupWarning)
        XCTAssertEqual(inference.logLikelihood, summary.logLikelihood)
        XCTAssertEqual(inference.seed, summary.seed)
    }

    func testRerootKeepsPairSupportOnTheSameSplitsOfASixTaxonTree() throws {
        let source = try importTree(
            "((A:0.1,B:0.1)90/91:0.2,((C:0.1,D:0.1)80/81:0.2,E:0.1)60/61:0.3,F:0.1);",
            options: .init(supportLabels: Self.pairLabels)
        )
        let sourceSplits = try supportBySplit(of: source)
        XCTAssertEqual(sourceSplits, [
            ["A", "B"]: "90/91",
            ["C", "D"]: "80/81",
            ["C", "D", "E"]: "60/61"
        ])

        for selector in ["E", "A", try XCTUnwrap(node(of: source, withDescendantTips: ["C", "D"])).id] {
            let rerooted = try source.rerootedBundle(
                on: selector,
                to: workspaceURL.appendingPathComponent("Rerooted-\(UUID().uuidString).lungfishtree", isDirectory: true),
                provenance: .init(toolName: "lungfish tree reroot", argv: [])
            )
            XCTAssertEqual(try supportBySplit(of: rerooted), sourceSplits, "rerooted on \(selector)")
            XCTAssertEqual(Set(tipLabels(of: rerooted)), ["A", "B", "C", "D", "E", "F"])
            for node in rerooted.normalizedTree.nodes where node.supportValues.isEmpty == false {
                XCTAssertEqual(node.supportValues.map(\.label), Self.pairLabels)
                XCTAssertEqual(node.support?.interpretation, "UFBoot")
            }
        }
    }

    // MARK: - Helpers

    private static func sampleSummary(
        outgroup: [String]? = ["Zebrafish_outgroup"],
        outgroupWarning: String? = nil
    ) -> PhylogeneticTreeInferenceSummary {
        PhylogeneticTreeInferenceSummary(
            program: "IQ-TREE",
            programVersion: "3.1.3",
            requestedModel: "MFP",
            bestFitModel: "TIM2+ASC",
            modelSelectionCriterion: "BIC",
            substitutionModel: "TIM2+F+ASC",
            logLikelihood: -173.4941,
            logLikelihoodStandardError: 7.9018,
            freeParameters: 15,
            sequenceType: "DNA",
            seed: 12345,
            threads: 1,
            outgroup: outgroup,
            outgroupWarning: outgroupWarning,
            sourceAlignmentName: "known-sarcopterygian",
            sourceAlignmentPath: "Alignments/known-sarcopterygian.lungfishmsa",
            selectedRowCount: 6,
            totalRowCount: 6,
            selectedColumns: nil,
            alignedLength: 48
        )
    }

    private func writeSource(_ contents: String) throws -> URL {
        let url = workspaceURL.appendingPathComponent("source-\(UUID().uuidString).nwk")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func importTree(_ newick: String, options: PhylogeneticTreeImportOptions) throws -> PhylogeneticTreeBundle {
        try PhylogeneticTreeBundleImporter.importTree(
            from: try writeSource(newick),
            to: workspaceURL.appendingPathComponent("Tree-\(UUID().uuidString).lungfishtree", isDirectory: true),
            options: options
        )
    }

    private func tipLabels(of bundle: PhylogeneticTreeBundle) -> [String] {
        bundle.normalizedTree.nodes.filter(\.isTip).map(\.displayLabel).sorted()
    }

    private func descendantTips(of nodeID: String, in bundle: PhylogeneticTreeBundle) -> Set<String> {
        let nodesByID = Dictionary(uniqueKeysWithValues: bundle.normalizedTree.nodes.map { ($0.id, $0) })
        guard let node = nodesByID[nodeID] else { return [] }
        if node.isTip { return [node.displayLabel] }
        return node.childIDs.reduce(into: Set<String>()) { $0.formUnion(descendantTips(of: $1, in: bundle)) }
    }

    private func node(of bundle: PhylogeneticTreeBundle, withDescendantTips tips: Set<String>) -> PhylogeneticTreeNormalizedNode? {
        bundle.normalizedTree.nodes.first { !$0.isTip && descendantTips(of: $0.id, in: bundle) == tips }
    }

    /// Support written on each non-trivial bipartition, keyed by the side that does not hold tip F.
    /// Both halves of a split root edge describe one bipartition, so they must agree.
    private func supportBySplit(of bundle: PhylogeneticTreeBundle) throws -> [Set<String>: String] {
        let allTips = Set(tipLabels(of: bundle))
        var result: [Set<String>: String] = [:]
        for node in bundle.normalizedTree.nodes where !node.isTip && node.parentID != nil {
            let below = descendantTips(of: node.id, in: bundle)
            let side = below.contains("F") ? allTips.subtracting(below) : below
            guard side.count > 1, side.count < allTips.count - 1 else { continue }
            guard let raw = node.rawLabel else { continue }
            if let existing = result[side] {
                XCTAssertEqual(existing, raw, "both halves of split \(side.sorted()) must agree")
            }
            result[side] = raw
        }
        return result
    }

    private func removeKeys(_ keys: Set<String>, fromJSONAt url: URL) throws {
        func strip(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { !keys.contains($0.key) }.mapValues(strip)
            }
            if let array = value as? [Any] {
                return array.map(strip)
            }
            return value
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        try JSONSerialization.data(withJSONObject: strip(object)).write(to: url)
    }
}
