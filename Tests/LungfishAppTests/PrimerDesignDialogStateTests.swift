import Foundation
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

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

  /// The dialog must send the same hydrolysis-probe preset the CLI sends for
  /// `--assay qpcr-probe`, including the PRIMER_INTERNAL_* window the probe needs.
  func testHydrolysisProbeChemistrySendsTheSharedProbePreset() throws {
    let state = configuredState()
    state.chemistry = .hydrolysisProbe
    let options = try state.primer3Options()
    XCTAssertEqual(options.assayMode, .qpcrProbe)
    XCTAssertTrue(options.pickInternalOligo)
    XCTAssertEqual(options.probe, Primer3ProbeDefaults.hydrolysisProbe)
    XCTAssertEqual(options, Primer3DesignOptions.preset(.qpcrProbe, pairCount: options.pairCount))

    // Switching chemistry reseeds the primer rules and drops the probe window.
    state.chemistry = .pcr
    let pcr = try state.primer3Options()
    XCTAssertNil(pcr.probe)
    XCTAssertEqual(pcr.productSizeMax, Primer3AssayDefaults.pcr.productSizeMax)
    state.chemistry = .intercalatingDye
    XCTAssertNil(try state.primer3Options().probe)
    state.chemistry = .hydrolysisProbe
    XCTAssertEqual(try state.primer3Options().probe, Primer3ProbeDefaults.hydrolysisProbe)
  }

  /// A target longer than the maximum product size leaves Primer3 nothing to consider, so
  /// the dialog must refuse it instead of producing an empty result that looks successful.
  func testTargetLongerThanMaximumProductSizeIsRejected() throws {
    let state = configuredState()
    state.chemistry = .intercalatingDye
    state.targetEnabled = true
    state.targetStart = "205"
    state.targetEnd = "474"
    let productMax = try XCTUnwrap(Int(state.productSizeMax))
    XCTAssertGreaterThan(474 - 205 + 1, productMax)
    let message = try XCTUnwrap(state.validationMessage)
    XCTAssertTrue(message.contains("270"), message)
    XCTAssertTrue(message.contains("\(productMax)"), message)
    XCTAssertThrowsError(try state.primer3Options())

    state.targetEnd = String(205 + productMax - 1)
    XCTAssertNil(state.validationMessage)
    XCTAssertNoThrow(try state.primer3Options())
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

  func testSingleSequenceFASTAEnablesPrimalSchemeRunAfterInspection() async throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }

    let fasta = project.appendingPathComponent("reference.fas")
    let sequence = String(repeating: "ACGT", count: 150)
    try Data(">reference\n\(sequence)\n".utf8).write(to: fasta)

    let state = PrimerDesignDialogState(projectURL: project)
    state.engine = .primalScheme
    state.analysisName = "single-sequence-primal"
    state.addInputs([fasta])
    XCTAssertFalse(state.isRunEnabled)

    await state.inspectInputs()

    XCTAssertEqual(state.inputSummaries[fasta]?.recordTitles, ["reference"])
    XCTAssertEqual(state.inputSummaries[fasta]?.isAlignment, false)
    XCTAssertNil(state.inputReadinessMessage)
    XCTAssertNil(state.validationMessage)
    XCTAssertTrue(state.isRunEnabled)
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
    XCTAssertEqual(options.minimumBaseFrequency, 0)
    XCTAssertEqual(options.coreCount, 2)
    XCTAssertTrue(options.highGC)
    XCTAssertEqual(options.terminalGapPolicy, .legacy)
    state.excludeUncoveredEnds = true
    XCTAssertEqual(try state.primalSchemeOptions().terminalGapPolicy, .observedOnly)
    XCTAssertEqual(try state.primalSchemeOptions().coreCount, 2)
    XCTAssertEqual(state.engine, .primalScheme)
  }

  func testPrimalAmpliconBoundsFollowTargetUntilCustomized() throws {
    let state = configuredState()
    let defaults = try state.primalSchemeOptions()
    XCTAssertEqual(defaults.ampliconSizeMinimum, 360)
    XCTAssertEqual(defaults.ampliconSize, 400)
    XCTAssertEqual(defaults.ampliconSizeMaximum, 440)

    state.ampliconSize = "200"
    let smaller = try state.primalSchemeOptions()
    XCTAssertEqual(smaller.ampliconSizeMinimum, 180)
    XCTAssertEqual(smaller.ampliconSizeMaximum, 220)

    state.ampliconSizeMinimum = "150"
    state.ampliconSizeMaximum = "250"
    state.ampliconSize = "210"
    let customized = try state.primalSchemeOptions()
    XCTAssertEqual(customized.ampliconSizeMinimum, 150)
    XCTAssertEqual(customized.ampliconSize, 210)
    XCTAssertEqual(customized.ampliconSizeMaximum, 250)
  }

  func testPrimalAmpliconBoundsAreCustomizedIndependently() throws {
    let minimumOnly = configuredState()
    minimumOnly.ampliconSizeMinimum = "150"
    minimumOnly.ampliconSize = "200"
    XCTAssertEqual(try minimumOnly.primalSchemeOptions().ampliconSizeMinimum, 150)
    XCTAssertEqual(try minimumOnly.primalSchemeOptions().ampliconSizeMaximum, 220)

    let maximumOnly = configuredState()
    maximumOnly.ampliconSizeMaximum = "500"
    maximumOnly.ampliconSize = "200"
    XCTAssertEqual(try maximumOnly.primalSchemeOptions().ampliconSizeMinimum, 180)
    XCTAssertEqual(try maximumOnly.primalSchemeOptions().ampliconSizeMaximum, 500)
  }

  func testPrimalCustomAmpliconBoundsApplyToBothGroupingModes() throws {
    let state = configuredState()
    state.ampliconSize = "200"
    state.ampliconSizeMinimum = "150"
    state.ampliconSizeMaximum = "250"
    for grouping in [PrimerAnalysisGrouping.independent, .combined] {
      state.grouping = grouping
      let options = try state.primalSchemeOptions()
      XCTAssertEqual(options.ampliconSize, 200)
      XCTAssertEqual(options.ampliconSizeMinimum, 150)
      XCTAssertEqual(options.ampliconSizeMaximum, 250)
    }
  }

  func testPrimalAmpliconBoundsRejectInvalidAndUnorderedValues() throws {
    let state = configuredState()
    state.engine = .primalScheme
    state.ampliconSize = "200"
    for value in ["", "0", "-1", "150.5", "invalid"] {
      state.ampliconSizeMinimum = value
      state.ampliconSizeMaximum = "250"
      XCTAssertThrowsError(try state.primalSchemeOptions(), "minimum: \(value)")
      XCTAssertNotNil(state.validationMessage)
      state.ampliconSizeMinimum = "150"
      state.ampliconSizeMaximum = value
      XCTAssertThrowsError(try state.primalSchemeOptions(), "maximum: \(value)")
      XCTAssertNotNil(state.validationMessage)
    }
    for (minimum, maximum) in [("201", "250"), ("150", "199"), ("250", "150")] {
      state.ampliconSizeMinimum = minimum
      state.ampliconSizeMaximum = maximum
      XCTAssertThrowsError(try state.primalSchemeOptions())
    }
    state.ampliconSizeMinimum = "200"
    state.ampliconSizeMaximum = "200"
    XCTAssertNil(state.validationMessage)
    XCTAssertEqual(try state.primalSchemeOptions().ampliconSizeMinimum, 200)
    XCTAssertEqual(try state.primalSchemeOptions().ampliconSizeMaximum, 200)
  }

  func testPrimalTargetKeepsItsSupportedRangeWithExplicitBounds() throws {
    let state = configuredState()
    state.ampliconSizeMinimum = "1"
    state.ampliconSizeMaximum = "2500"
    for value in ["99", "2001", "", "invalid"] {
      state.ampliconSize = value
      XCTAssertThrowsError(try state.primalSchemeOptions(), value)
    }
    for value in ["100", "2000"] {
      state.ampliconSize = value
      XCTAssertNoThrow(try state.primalSchemeOptions(), value)
    }
  }

  func testGUIPrimalSchemeAlwaysResolvesZeroMinimumBaseFrequency() throws {
    let state = configuredState()
    state.engine = .primalScheme
    XCTAssertEqual(try state.primalSchemeOptions().minimumBaseFrequency, 0)

    state.ampliconSize = "200"
    state.ampliconSizeMinimum = "150"
    state.ampliconSizeMaximum = "250"
    state.poolCount = "3"
    state.coreCount = "2"
    state.highGC = true
    state.dimerScore = "-28"
    state.useMatchDB = false
    state.backtrack = true
    state.ignoreN = true
    state.panelMode = .entropy
    state.maxAmplicons = "12"
    state.maxAmpliconsPerMSA = "3"

    for grouping in [PrimerAnalysisGrouping.independent, .combined] {
      state.grouping = grouping
      for excludeUncoveredEnds in [true, false] {
        state.excludeUncoveredEnds = excludeUncoveredEnds
        let options = try state.primalSchemeOptions()
        XCTAssertEqual(options.minimumBaseFrequency, 0)
        XCTAssertEqual(options.poolCount, 3)
        XCTAssertEqual(options.ampliconSizeMinimum, 150)
        XCTAssertEqual(options.ampliconSizeMaximum, 250)
        XCTAssertTrue(options.highGC)
        XCTAssertEqual(options.terminalGapPolicy, excludeUncoveredEnds ? .observedOnly : .legacy)
      }
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
  }

  func testRecoveryControlsStayOptInAndPreserveLegacyDefaults() throws {
    let state = configuredState()
    state.engine = .primalScheme
    state.grouping = .combined
    let defaults = try state.primalSchemeOptions()
    XCTAssertEqual(defaults.selectionAlgorithm, .legacy)
    XCTAssertEqual(defaults.legacySalvageOptions.mode, .off)
    XCTAssertEqual(defaults.gapExpansionOptions.mode, .off)

    state.legacySalvageEnabled = true
    let salvage = try state.primalSchemeOptions()
    XCTAssertEqual(salvage.legacySalvageOptions.mode, .bounded)
    XCTAssertEqual(salvage.legacySalvageOptions.thresholds, [-28, -30, -32])
    XCTAssertNil(state.primalschemeExecutableURL)
  }

  func testLegacyPrimalDefaultsRemainManagedAndUnchanged() throws {
    let state = configuredState()
    state.engine = .primalScheme
    XCTAssertNil(state.primalschemeExecutableURL)
    let options = try state.primalSchemeOptions()
    XCTAssertEqual(options.selectionAlgorithm, .legacy)
    XCTAssertEqual(options.terminalGapPolicy, .observedOnly)
  }

  func testPrimalMinimumBaseFrequencyIsVisibleAndForwardedExactly() throws {
    let state = configuredState()
    state.engine = .primalScheme
    state.minimumBaseFrequency = "0.125"
    XCTAssertEqual(try state.primalSchemeOptions().minimumBaseFrequency, 0.125)
    state.minimumBaseFrequency = "1.1"
    XCTAssertThrowsError(try state.primalSchemeOptions())
    XCTAssertTrue(state.validationMessage?.contains("base frequency") == true)
  }

  func testEngineRoutingExposesBothNormalizedSchemeWorkflows() throws {
    XCTAssertEqual(PrimerDesignEngine.allCases.map(\.rawValue),
      ["Primer3", "PrimalScheme", "Olivar", "varVAMP"])
    let state = configuredState()
    state.engine = .olivar
    XCTAssertEqual(try state.primerSchemeOptions().engine, .olivar)
    state.engine = .varVAMP
    XCTAssertEqual(try state.primerSchemeOptions().engine, .varvamp)
  }

  func testOlivarSettingsSurviveAdvancedToggleAndRoundTripExactly() throws {
    let state = configuredState()
    state.engine = .olivar
    state.ampliconSizeMinimum = "320"
    state.ampliconSize = "375"
    state.ampliconSizeMaximum = "430"
    state.schemeWorkers = "3"
    state.olivarMinimumVariantFrequency = "0.0375"
    state.olivarDegenerate = true
    state.olivarCheckVariants = true
    state.olivarTemperatureC = "61.5"
    state.olivarRiskVariation = "2.25"
    state.olivarBlastDatabasePath = "/db/non-target"
    state.advancedExpanded = true
    state.advancedExpanded = false

    let options = try state.primerSchemeOptions()
    XCTAssertEqual(options.engine, .olivar)
    XCTAssertEqual(options.mode, .tiled)
    XCTAssertEqual(options.minimumAmpliconLength, 320)
    XCTAssertEqual(options.nominalAmpliconLength, 375)
    XCTAssertEqual(options.maximumAmpliconLength, 430)
    XCTAssertEqual(options.workers, 3)
    XCTAssertEqual(options.requestedMinimumAmpliconLength, 320)
    XCTAssertEqual(options.requestedMaximumAmpliconLength, 430)
    XCTAssertTrue(options.suppliedOptionNames.isSuperset(of: ["engine", "mode", "grouping",
      "nominalAmpliconLength", "minimumAmpliconLength", "maximumAmpliconLength", "workers",
      "requestedMinimumAmpliconLength", "requestedMaximumAmpliconLength"]))
    XCTAssertEqual(options.olivar?.minimumVariantFrequency, 0.0375)
    XCTAssertEqual(options.olivar?.temperatureC, 61.5)
    XCTAssertEqual(options.olivar?.riskWeights.variation, 2.25)
    XCTAssertEqual(options.olivar?.blastDatabasePath, "/db/non-target")
    XCTAssertTrue(options.olivar?.degenerate == true)
    XCTAssertTrue(options.olivar?.checkVariants == true)
  }

  func testVarVAMPModesRetainSizingAndQPCRRequiresVisibleThreshold() throws {
    let state = configuredState()
    state.engine = .varVAMP
    state.schemeMode = .single
    state.ampliconSizeMinimum = "180"
    state.ampliconSize = "220"
    state.ampliconSizeMaximum = "260"
    state.varVAMPReportCount = "7"

    state.schemeMode = .qpcr
    XCTAssertEqual(state.ampliconSizeMinimum, "70")
    XCTAssertEqual(state.ampliconSize, "135")
    XCTAssertEqual(state.ampliconSizeMaximum, "200")
    XCTAssertThrowsError(try state.primerSchemeOptions())
    XCTAssertTrue(state.validationMessage?.contains("consensus threshold") == true)
    state.varVAMPConsensusThreshold = "0.91"
    let untouchedQPCRBounds = try state.primerSchemeOptions()
    XCTAssertNil(untouchedQPCRBounds.requestedMinimumAmpliconLength)
    XCTAssertNil(untouchedQPCRBounds.requestedMaximumAmpliconLength)
    XCTAssertFalse(untouchedQPCRBounds.suppliedOptionNames.contains("requestedMinimumAmpliconLength"))
    XCTAssertFalse(untouchedQPCRBounds.suppliedOptionNames.contains("requestedMaximumAmpliconLength"))
    state.varVAMPMaximumProbeAmbiguities = "1"
    state.varVAMPQPCRTestCount = "17"
    state.ampliconSizeMinimum = "80"
    state.ampliconSize = "125"
    state.ampliconSizeMaximum = "175"
    let qpcr = try state.primerSchemeOptions()
    XCTAssertEqual(qpcr.mode, .qpcr)
    XCTAssertEqual(qpcr.varvamp?.cumulativeConsensusThreshold, 0.91)
    XCTAssertEqual(qpcr.varvamp?.maximumProbeAmbiguities, 1)
    XCTAssertEqual(qpcr.varvamp?.qpcrTestCount, 17)
    XCTAssertEqual(qpcr.requestedMinimumAmpliconLength, 80)
    XCTAssertEqual(qpcr.requestedMaximumAmpliconLength, 175)

    state.schemeMode = .single
    XCTAssertEqual(state.ampliconSizeMinimum, "180")
    XCTAssertEqual(state.ampliconSize, "220")
    XCTAssertEqual(state.ampliconSizeMaximum, "260")
    XCTAssertEqual(try state.primerSchemeOptions().varvamp?.reportCount, 7)
    state.schemeMode = .qpcr
    XCTAssertEqual(state.ampliconSizeMinimum, "80")
    XCTAssertEqual(state.ampliconSize, "125")
    XCTAssertEqual(state.ampliconSizeMaximum, "175")
    XCTAssertEqual(try state.primerSchemeOptions().varvamp?.cumulativeConsensusThreshold, 0.91)
  }

  func testFreshVarVAMPModeSwitchRestoresExactDefaultSizing() {
    let state = configuredState()
    state.engine = .varVAMP

    XCTAssertEqual(state.schemeMode, .tiled)
    XCTAssertEqual(
      [state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["360", "400", "440"])

    state.schemeMode = .qpcr
    XCTAssertEqual(
      [state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["70", "135", "200"])

    state.schemeMode = .tiled
    XCTAssertEqual(
      [state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["360", "400", "440"])
  }

  func testVarVAMPModeSwitchOmitsInactiveControlsWithoutLosingEdits() throws {
    let state = configuredState()
    state.engine = .varVAMP
    state.schemeMode = .qpcr
    state.varVAMPConsensusThreshold = "0.88"
    state.varVAMPMaximumProbeAmbiguities = "1"
    state.varVAMPQPCRTestCount = "23"
    state.varVAMPQPCRDeltaG = "-7"
    state.varVAMPProbeSizeMinimum = "19"
    state.varVAMPProbeSizeOptimum = "24"
    state.varVAMPProbeSizeMaximum = "29"
    XCTAssertEqual(try state.primerSchemeOptions().varvamp?.qpcrTestCount, 23)

    state.schemeMode = .single
    state.varVAMPTiledOverlap = "hidden-invalid"
    let single = try state.primerSchemeOptions()
    XCTAssertNil(single.varvamp?.maximumProbeAmbiguities)
    XCTAssertNil(single.varvamp?.configOverrides.probeSizes)
    XCTAssertEqual(single.varvamp?.qpcrTestCount, 50)
    XCTAssertEqual(single.varvamp?.qpcrDeltaG, -3)
    XCTAssertEqual(single.varvamp?.tiledOverlap, 25)
    XCTAssertFalse(single.varvamp?.suppliedOptionNames.contains("tiledOverlap") == true)
    XCTAssertFalse(single.varvamp?.suppliedOptionNames.contains("qpcrTestCount") == true)

    state.varVAMPTiledOverlap = "31"
    state.varVAMPReportCount = "hidden-invalid"
    state.schemeMode = .tiled
    state.varVAMPQPCRTestCount = "also-hidden-invalid"
    let tiled = try state.primerSchemeOptions()
    XCTAssertNil(tiled.varvamp?.reportCount)
    XCTAssertEqual(tiled.varvamp?.tiledOverlap, 31)
    XCTAssertEqual(tiled.varvamp?.qpcrTestCount, 50)

    state.varVAMPQPCRTestCount = "23"
    state.schemeMode = .qpcr
    let restored = try state.primerSchemeOptions()
    XCTAssertEqual(restored.varvamp?.maximumProbeAmbiguities, 1)
    XCTAssertEqual(restored.varvamp?.qpcrTestCount, 23)
    XCTAssertEqual(restored.varvamp?.qpcrDeltaG, -7)
    XCTAssertEqual(restored.varvamp?.configOverrides.probeSizes?.minimum, 19)
    XCTAssertEqual(restored.varvamp?.configOverrides.probeSizes?.optimum, 24)
    XCTAssertEqual(restored.varvamp?.configOverrides.probeSizes?.maximum, 29)
    XCTAssertEqual(state.varVAMPTiledOverlap, "31")
    XCTAssertEqual(state.varVAMPReportCount, "hidden-invalid")
  }

  func testEngineSwitchRestoresPerEngineAndVarVAMPModeSizing() throws {
    let state = configuredState()
    state.engine = .varVAMP
    state.schemeMode = .qpcr
    state.varVAMPConsensusThreshold = "0.90"
    state.ampliconSizeMinimum = "80"
    state.ampliconSize = "125"
    state.ampliconSizeMaximum = "175"

    state.engine = .olivar
    XCTAssertEqual([state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["360", "400", "440"])
    XCTAssertNoThrow(try state.primerSchemeOptions())
    state.ampliconSizeMinimum = "300"
    state.ampliconSize = "350"
    state.ampliconSizeMaximum = "410"

    state.engine = .primalScheme
    XCTAssertEqual([state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["360", "400", "440"])
    state.ampliconSizeMinimum = "330"
    state.ampliconSize = "370"
    state.ampliconSizeMaximum = "420"

    state.engine = .varVAMP
    XCTAssertEqual(state.schemeMode, .qpcr)
    XCTAssertEqual([state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["80", "125", "175"])
    XCTAssertNoThrow(try state.primerSchemeOptions())
    state.engine = .olivar
    XCTAssertEqual([state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["300", "350", "410"])
    state.engine = .primalScheme
    XCTAssertEqual([state.ampliconSizeMinimum, state.ampliconSize, state.ampliconSizeMaximum],
      ["330", "370", "420"])
  }

  func testGapFollowupForcesLegacyTerminalPolicyAndCarriesBoundedExpansion() throws {
    let state = configuredState()
    state.engine = .primalScheme
    state.grouping = .combined
    state.gapCompletionParentPath = "/tmp/parent-native-output"
    state.gapExpansionEnabled = true
    state.gapExpansionMaxAnchorsPerMSA = "12"
    state.gapExpansionMaxPairsPerMSA = "9"
    let options = try state.primalSchemeOptions()
    XCTAssertEqual(options.selectionAlgorithm, .legacy)
    XCTAssertEqual(options.terminalGapPolicy, .legacy)
    XCTAssertEqual(options.gapCompletionParent?.path, "/tmp/parent-native-output")
    XCTAssertEqual(options.gapExpansionOptions.mode, .bounded)
    XCTAssertEqual(options.gapExpansionOptions.maxAnchorsPerMSA, 12)
    XCTAssertEqual(options.gapExpansionOptions.maxPairsPerMSA, 9)
  }

  func testDialogAndCLIResolveIdenticalPrimalSchemeSizingFromVisibleSettings() throws {
    let state = configuredState()
    state.engine = .primalScheme
    state.ampliconSize = "300"
    let dialogOptions = try state.primalSchemeOptions()
    XCTAssertEqual(dialogOptions.requestedAmpliconSizeMinimum, 270)
    XCTAssertEqual(dialogOptions.requestedAmpliconSizeMaximum, 330)

    let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse([
      "--msa", "/input/mhc.fasta", "--output", "/tmp/out.lungfishprimeranalysis",
      "--amplicon-size", "300",
    ])
    let cli = try command.makeOptions()
    XCTAssertEqual(cli.grouping, .independent)
    XCTAssertEqual(cli.options, dialogOptions)
    XCTAssertEqual(cli.options.ampliconSizeMetric, "reference-span")
  }

  func testDialogRecoveryControlsRoundTripThroughCLIArguments() throws {
    let state = configuredState()
    state.engine = .primalScheme
    state.grouping = .combined
    state.legacySalvageEnabled = true
    state.legacySalvageThresholds = "-28,-30"
    state.legacySalvageMaxEdgesPerPool = "6"
    try assertRoundTrip(state)

    state.legacySalvageEnabled = false
    state.gapCompletionParentPath = "/tmp/parent.lungfishprimeranalysis"
    state.gapExpansionEnabled = true
    state.gapExpansionMaxPairsPerMSA = "250"
    try assertRoundTrip(state)

    state.gapExpansionEnabled = false
    state.gapCompletionParentPath = ""
    state.grouping = .independent
    state.backtrack = true
    state.minOverlap = "20"
    state.useMatchDB = false
    try assertRoundTrip(state)
  }

  private func assertRoundTrip(_ state: PrimerDesignDialogState, file: StaticString = #filePath, line: UInt = #line) throws {
    let options = try state.primalSchemeOptions()
    let argv = PrimerDesignCommand.PrimalScheme3Subcommand.arguments(
      inputs: state.inputURLs, output: URL(fileURLWithPath: "/tmp/out.lungfishprimeranalysis"),
      grouping: state.grouping, options: options)
    let command = try PrimerDesignCommand.PrimalScheme3Subcommand.parse(argv)
    let resolved = try command.makeOptions()
    XCTAssertEqual(resolved.grouping, state.grouping, file: file, line: line)
    XCTAssertEqual(resolved.options, options, file: file, line: line)
    XCTAssertEqual(resolved.options.legacySalvageOptions.requestedOptionNames,
      options.legacySalvageOptions.requestedOptionNames, file: file, line: line)
    XCTAssertEqual(resolved.options.gapExpansionOptions.requestedOptionNames,
      options.gapExpansionOptions.requestedOptionNames, file: file, line: line)
  }

  func testDefaultAnalysisNameIsUniqueWithinTheProjectAtDialogOpen() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let analyses = project.appendingPathComponent("Analyses")
    try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }

    XCTAssertEqual(PrimerDesignDialogState(projectURL: project).analysisName, "Primer analysis")
    XCTAssertEqual(PrimerDesignDialogState().analysisName, "Primer analysis")

    try FileManager.default.createDirectory(
      at: analyses.appendingPathComponent("Primer analysis.lungfishprimeranalysis"), withIntermediateDirectories: false)
    let second = PrimerDesignDialogState(projectURL: project)
    XCTAssertEqual(second.analysisName, "Primer analysis 2")
    XCTAssertNoThrow(try second.validatedDestinationURL())

    try FileManager.default.createDirectory(
      at: analyses.appendingPathComponent("Primer analysis 2.lungfishprimeranalysis"), withIntermediateDirectories: false)
    let third = PrimerDesignDialogState(projectURL: project)
    XCTAssertEqual(third.analysisName, "Primer analysis 3")
    XCTAssertNoThrow(try third.validatedDestinationURL())
  }

  func testTypedNameCollisionIsStillBlocked() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let analyses = project.appendingPathComponent("Analyses")
    try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    try FileManager.default.createDirectory(
      at: analyses.appendingPathComponent("Primer analysis.lungfishprimeranalysis"), withIntermediateDirectories: false)
    let state = PrimerDesignDialogState(projectURL: project)
    XCTAssertEqual(state.analysisName, "Primer analysis 2")
    state.addInputs([URL(fileURLWithPath: "/input/mhc.fasta")])
    state.analysisName = "Primer analysis"
    XCTAssertThrowsError(try state.validatedDestinationURL())
    XCTAssertEqual(state.validationMessage, "An analysis with this name already exists in the project. Enter a different name.")
  }

  func testChoosingIntercalatingDyeAppliesSharedDefaultsThatMatchTheCLI() throws {
    let state = configuredState()
    XCTAssertEqual(try state.primer3Options(), .preset(.pcr))
    state.chemistry = .intercalatingDye
    XCTAssertEqual(state.productSizeMin, "70")
    XCTAssertEqual(state.primerMaxTm, "62")
    XCTAssertEqual(state.primerMaxEndGC, "2")
    let dialog = try state.primer3Options()
    XCTAssertEqual(dialog, .preset(.qpcrDye))

    let command = try PrimerDesignCommand.Primer3Subcommand.parse([
      "--fasta-record", "/input/mhc.fasta@0", "--output", "/tmp/out.lungfishprimeranalysis", "--assay", "qpcr-dye",
    ])
    XCTAssertEqual(try command.makeOptions(), dialog)

    // The preset only seeds the visible fields; edits still win.
    state.primerMinTm = "59"
    state.primerMaxSelfEndTh = ""
    let edited = try state.primer3Options()
    XCTAssertEqual(edited.primerMinTm, 59)
    XCTAssertNil(edited.primerMaxSelfEndTh)
    XCTAssertEqual(edited.assayMode, .qpcrDye)

    state.chemistry = .pcr
    XCTAssertEqual(try state.primer3Options(), .preset(.pcr))
    state.primerMinTm = "55"
    state.chemistry = .hydrolysisProbe
    XCTAssertEqual(state.primerMinTm, "58",
      "The probe assay has its own preset now, so switching to it reseeds the primer rules")
    XCTAssertEqual(try state.primer3Options().assayMode, .qpcrProbe)
    XCTAssertTrue(try state.primer3Options().pickInternalOligo)
    XCTAssertEqual(try state.primer3Options().probe, Primer3ProbeDefaults.hydrolysisProbe)
  }

  private func configuredState() -> PrimerDesignDialogState {
    let state = PrimerDesignDialogState(projectURL: FileManager.default.temporaryDirectory)
    state.analysisName = UUID().uuidString
    state.addInputs([URL(fileURLWithPath: "/input/mhc.fasta")])
    return state
  }
}
