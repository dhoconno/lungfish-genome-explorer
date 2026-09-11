import Foundation
import XCTest
@testable import LungfishApp

@MainActor
final class PrimerDesignDialogStateTests: XCTestCase {
  func testInvalidNumericTextCannotRetainAnOlderValidSetting() {
    let state = configuredState()
    XCTAssertNil(state.validationMessage)
    state.productSizeMin = "invalid"
    XCTAssertNotNil(state.validationMessage)
    XCTAssertThrowsError(try state.primer3Options())
  }

  func testTargetCoordinatesMustBeCompleteAndOrdered() {
    let state = configuredState()
    state.targetEnabled = true
    state.targetStart = "20"
    state.targetEnd = ""
    XCTAssertNotNil(state.validationMessage)
    state.targetEnd = "10"
    XCTAssertNotNil(state.validationMessage)
    state.targetEnd = "30"
    XCTAssertNil(state.validationMessage)
  }

  func testInputIdentityUsesFullPathAndPreservesSelectionOrder() {
    let state = PrimerDesignDialogState()
    let first = URL(fileURLWithPath: "/a/mhc.fasta")
    let second = URL(fileURLWithPath: "/b/mhc.fasta")
    state.addInputs([first, second, first])
    XCTAssertEqual(state.inputURLs, [first, second])
    state.removeInput(first)
    XCTAssertEqual(state.inputURLs, [second])
  }

  func testExemplarChangesNameWithoutInventingAssayParameters() {
    let state = configuredState()
    state.productSizeMin = "150"
    state.applyExemplar(.classIIDQ)
    XCTAssertEqual(state.analysisName, "MHC class II DQ")
    XCTAssertEqual(state.productSizeMin, "150")
    XCTAssertEqual(PrimerDesignMHCExemplar.allCases.count, 4)
  }

  func testChemistryControlsInternalProbeSelection() throws {
    let state = configuredState()
    state.chemistry = .intercalatingDye
    XCTAssertFalse(try state.primer3Options().pickInternalOligo)
    state.chemistry = .hydrolysisProbe
    XCTAssertTrue(try state.primer3Options().pickInternalOligo)
  }

  func testInspectedDuplicateFASTARecordNamesRetainIndependentSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mhc.fasta")
    try Data(">duplicate\nACGT\n>duplicate\nTGCA\n".utf8).write(to: url)
    let state = PrimerDesignDialogState()
    state.addInputs([url])
    XCTAssertNotNil(state.inputReadinessMessage)
    await state.inspectInputs()
    XCTAssertNil(state.inputReadinessMessage)
    XCTAssertEqual(state.selectedRecordIndices[url], [0, 1])
    state.selectedRecordIndices[url] = [1]
    let selections = try state.primer3Selections()
    XCTAssertEqual(selections.count, 1)
    guard case .fastaRecord(let selectedURL, let index) = selections[0] else {
      return XCTFail("Expected explicit FASTA selection")
    }
    XCTAssertEqual(selectedURL, url)
    XCTAssertEqual(index, 1)
    state.selectedRecordIndices[url] = []
    XCTAssertThrowsError(try state.primer3Selections())
    let originalChecksum = state.inputSummaries[url]?.checksumSHA256
    try Data(">replacement\nACGT\n".utf8).write(to: url)
    state.refreshInputs()
    XCTAssertNil(state.inputSummaries[url])
    await state.inspectInputs()
    XCTAssertEqual(state.selectedRecordIndices[url], [0])
    XCTAssertNotEqual(state.inputSummaries[url]?.checksumSHA256, originalChecksum)
  }

  func testInputReadFailurePreventsRunAndCanBeRetried() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mhc.fasta")
    let state = PrimerDesignDialogState()
    state.addInputs([url])
    await state.inspectInputs()
    XCTAssertNotNil(state.inputErrors[url])
    XCTAssertThrowsError(try state.primer3Selections())
    try Data(">recovered\nACGT\n".utf8).write(to: url)
    await state.inspectInputs()
    XCTAssertNil(state.inputErrors[url])
    XCTAssertNil(state.inputReadinessMessage)
  }

  func testPrimalAdvancedSettingsValidateTextAndGrouping() throws {
    let state = configuredState()
    state.engine = .primalScheme
    XCTAssertEqual(try state.primalSchemeOptions().terminalGapPolicy, .observedOnly)
    state.excludeUncoveredEnds = false
    state.minimumBaseFrequency = "1.1"
    XCTAssertNotNil(state.validationMessage)
    state.minimumBaseFrequency = "0.5"
    state.coreCount = "0"
    XCTAssertNotNil(state.validationMessage)
    state.coreCount = "2"
    state.minOverlap = "-1"
    XCTAssertNotNil(state.validationMessage)
    state.grouping = .combined
    XCTAssertNil(state.validationMessage)
    XCTAssertEqual(try state.primalSchemeOptions().minOverlap, 10)
    state.grouping = .independent
    state.minOverlap = "15"
    state.highGC = true
    let options = try state.primalSchemeOptions()
    XCTAssertEqual(options.minOverlap, 15)
    XCTAssertEqual(options.minimumBaseFrequency, 0.5)
    XCTAssertEqual(options.coreCount, 2)
    XCTAssertTrue(options.highGC)
    XCTAssertEqual(options.terminalGapPolicy, .legacy)
    state.excludeUncoveredEnds = true
    XCTAssertEqual(try state.primalSchemeOptions().terminalGapPolicy, .observedOnly)
    XCTAssertEqual(try state.primalSchemeOptions().coreCount, 2)
    XCTAssertTrue(state.engine.rawValue.contains("custom fork"))
  }

  private func configuredState() -> PrimerDesignDialogState {
    let state = PrimerDesignDialogState()
    state.addInputs([URL(fileURLWithPath: "/input/mhc.fasta")])
    state.destinationURL = URL(fileURLWithPath: "/output/mhc.lungfishprimeranalysis")
    return state
  }
}
