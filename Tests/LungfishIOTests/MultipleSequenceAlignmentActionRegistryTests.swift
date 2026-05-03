import XCTest
@testable import LungfishIO

final class MultipleSequenceAlignmentActionRegistryTests: XCTestCase {
    func testRegistryContainsCoreExpertConsensusActions() {
        let actionIDs = Set(MultipleSequenceAlignmentActionRegistry.actions.map(\.id))

        XCTAssertTrue(actionIDs.contains("msa.selection.block"))
        XCTAssertTrue(actionIDs.contains("msa.display.annotations"))
        XCTAssertTrue(actionIDs.contains("msa.annotation.project"))
        XCTAssertTrue(actionIDs.contains("msa.transform.mask-columns"))
        XCTAssertTrue(actionIDs.contains("msa.transform.trim-columns"))
        XCTAssertTrue(actionIDs.contains("msa.alignment.mafft"))
        XCTAssertTrue(actionIDs.contains("msa.phylogenetics.build-tree"))
    }

    func testScientificDataChangingActionsRequireCLIAndProvenance() {
        let scientificActions = MultipleSequenceAlignmentActionRegistry.scientificDataChangingActions
        XCTAssertFalse(scientificActions.isEmpty)

        for action in scientificActions {
            XCTAssertTrue(action.requiresProvenance, "\(action.id) must require provenance")
            XCTAssertNotNil(action.cli, "\(action.id) must declare a CLI contract")
            XCTAssertFalse(action.cli?.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    func testRegistryValidationPasses() {
        XCTAssertEqual(MultipleSequenceAlignmentActionRegistry.validate(), [])
    }

    func testExtractAndConsensusActionsDocumentNativeReferenceBundleOutputs() throws {
        let extract = try XCTUnwrap(MultipleSequenceAlignmentActionRegistry.action(id: "msa.transform.extract-selection"))
        XCTAssertTrue(extract.cli?.command.contains("fasta|msa|reference") ?? false)
        XCTAssertTrue(extract.cli?.outputContract.contains(".lungfishref") ?? false)
        XCTAssertTrue(extract.cli?.outputContract.contains("annotations") ?? false)

        let consensus = try XCTUnwrap(MultipleSequenceAlignmentActionRegistry.action(id: "msa.transform.consensus"))
        XCTAssertTrue(consensus.cli?.command.contains("--output-kind fasta|reference") ?? false)
        XCTAssertTrue(consensus.cli?.outputContract.contains(".lungfishref") ?? false)
    }

    func testMaskColumnsActionDocumentsCodonPositionSelector() throws {
        let action = try XCTUnwrap(MultipleSequenceAlignmentActionRegistry.action(id: "msa.transform.mask-columns"))

        XCTAssertTrue(action.summary.contains("CDS codon-position"))
        XCTAssertTrue(action.cli?.command.contains("--codon-position <1|2|3>") ?? false)
        XCTAssertTrue(action.cli?.outputContract.contains("CDS codon position") ?? false)
    }

    func testBuildTreeActionDocumentsImplementedIQTreeContract() throws {
        let action = try XCTUnwrap(MultipleSequenceAlignmentActionRegistry.action(id: "msa.phylogenetics.build-tree"))

        XCTAssertEqual(action.implementationStatus, .implemented)
        XCTAssertTrue(action.cli?.command.contains("lungfish tree infer iqtree") ?? false)
        XCTAssertFalse(action.cli?.command.contains("fasttree") ?? true)
        XCTAssertFalse(action.cli?.command.contains("raxml-ng") ?? true)
        XCTAssertTrue(action.cli?.command.contains("--rows <rows>") ?? false)
        XCTAssertTrue(action.cli?.command.contains("--columns <ranges>") ?? false)
        XCTAssertTrue(action.cli?.command.contains("--output <path.lungfishtree>") ?? false)
        XCTAssertTrue(action.cli?.outputContract.contains("artifacts/iqtree") ?? false)
        XCTAssertTrue(action.cli?.outputContract.contains(".lungfish-provenance.json") ?? false)
        XCTAssertEqual(action.cli?.requiredPluginPackIDs, ["phylogenetics"])
    }

    func testP0ActionsDeclareAccessibilityAndTestRequirements() {
        let p0Actions = MultipleSequenceAlignmentActionRegistry.actions.filter { $0.priority == .p0 }
        XCTAssertFalse(p0Actions.isEmpty)

        for action in p0Actions {
            XCTAssertFalse(action.accessibilityRequirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(action.testRequirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
