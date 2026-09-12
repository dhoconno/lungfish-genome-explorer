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

  func testDestinationRequiresProjectAndRejectsTraversalAndCollisions() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    XCTAssertThrowsError(try PrimerDesignDialogState().validatedDestinationURL())
    let state = PrimerDesignDialogState(projectURL: project)
    state.analysisName = "Class I design"
    let destination = try state.validatedDestinationURL()
    XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "Analyses")
    XCTAssertEqual(destination.lastPathComponent, "Class I design.lungfishprimeranalysis")
    for name in ["../outside", "a/b", "a\\b", ".", "..", "", "a:b", "hidden\nname"] {
      state.analysisName = name
      XCTAssertThrowsError(try state.validatedDestinationURL(), name)
    }
    state.analysisName = "Class I design"
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    XCTAssertThrowsError(try state.validatedDestinationURL())
  }

  func testDestinationRejectsDanglingBundleLinkAndChangedProjectRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = PrimerDesignDialogState(projectURL: project)
    let destination = try state.validatedDestinationURL(createParent: true)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside.appendingPathComponent("missing"))
    XCTAssertThrowsError(try state.validatedDestinationURL())
    try FileManager.default.removeItem(at: project)
    try FileManager.default.createSymbolicLink(at: project, withDestinationURL: outside)
    XCTAssertThrowsError(try state.validatedDestinationURL())
  }

  func testDestinationRejectsAnalysesSymlinkEscapeIncludingDanglingLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let analyses = project.appendingPathComponent("Analyses")
    try FileManager.default.createSymbolicLink(at: analyses, withDestinationURL: outside)
    let state = PrimerDesignDialogState(projectURL: project)
    XCTAssertThrowsError(try state.validatedDestinationURL())
    try FileManager.default.removeItem(at: outside)
    XCTAssertThrowsError(try state.validatedDestinationURL())
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
    state.minimumPrimerVariantFrequencyPercent = "110"
    XCTAssertNotNil(state.validationMessage)
    state.minimumPrimerVariantFrequencyPercent = "50"
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

  func testPrimerVariantPercentResolvesToNativeFractionWithoutChangingDefaults() throws {
    let state = configuredState()
    state.engine = .primalScheme
    XCTAssertEqual(try state.primalSchemeOptions().minimumBaseFrequency, 0)
    state.minimumPrimerVariantFrequencyPercent = "2.5"
    XCTAssertEqual(try state.primalSchemeOptions().minimumBaseFrequency, 0.025, accuracy: 0.000001)
    for value in ["-1", "100.1", "nan", "inf", ""] {
      state.minimumPrimerVariantFrequencyPercent = value
      XCTAssertThrowsError(try state.primalSchemeOptions(), value)
    }
  }

  func testPrimalModeSpecificOptionsDoNotLeakAcrossGrouping() throws {
    let state = configuredState()
    state.backtrack = true
    state.ignoreN = true
    state.panelMode = .entropy
    state.maxAmplicons = "12"
    state.maxAmpliconsPerMSA = "3"
    state.dimerScore = "-28"
    state.useMatchDB = false
    let single = try state.primalSchemeOptions()
    XCTAssertTrue(single.backtrack)
    XCTAssertTrue(single.ignoreN)
    XCTAssertEqual(single.panelMode, .equal)
    XCTAssertNil(single.maxAmplicons)
    XCTAssertEqual(single.dimerScore, -28)
    XCTAssertFalse(single.useMatchDB)
    state.grouping = .combined
    let panel = try state.primalSchemeOptions()
    XCTAssertFalse(panel.backtrack)
    XCTAssertFalse(panel.ignoreN)
    XCTAssertEqual(panel.panelMode, .entropy)
    XCTAssertEqual(panel.maxAmplicons, 12)
    XCTAssertEqual(panel.maxAmpliconsPerMSA, 3)
    state.maxAmplicons = "0"
    XCTAssertThrowsError(try state.primalSchemeOptions())
    state.maxAmplicons = ""
    XCTAssertNil(try state.primalSchemeOptions().maxAmplicons)
    XCTAssertTrue(state.effectiveAmpliconRange.contains("360–440"))
  }

  private func configuredState() -> PrimerDesignDialogState {
    let state = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
    state.analysisName = UUID().uuidString
    state.addInputs([URL(fileURLWithPath: "/input/mhc.fasta")])
    return state
  }
}
