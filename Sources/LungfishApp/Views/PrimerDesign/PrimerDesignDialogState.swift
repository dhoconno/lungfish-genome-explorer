import Foundation
import Observation
import LungfishIO
import LungfishWorkflow

enum PrimerDesignEngine: String, CaseIterable, Identifiable {
  case primer3 = "Primer3"
  case primalScheme = "PrimalScheme"
  case olivar = "Olivar"
  case varVAMP = "varVAMP"
  var id: String { rawValue }

  var schemeEngine: PrimerSchemeEngine? {
    switch self {
    case .olivar: .olivar
    case .varVAMP: .varvamp
    default: nil
    }
  }
}

enum PrimerDesignChemistry: String, CaseIterable, Identifiable {
  case pcr = "PCR primers"
  case intercalatingDye = "qPCR · intercalating dye"
  case hydrolysisProbe = "qPCR · internal hydrolysis probe"
  var id: String { rawValue }
}

struct PrimerDesignValidationError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@MainActor @Observable
final class PrimerDesignDialogState {
  var engine: PrimerDesignEngine = .primer3 {
    didSet { updateEngine(from: oldValue) }
  }
  var chemistry: PrimerDesignChemistry = .pcr
  var inputURLs: [URL] = []
  var inputSummaries: [URL: Primer3DesignInputSummary] = [:]
  var inputErrors: [URL: String] = [:]
  var selectedRecordIndices: [URL: Set<Int>] = [:]
  var templateRowIndices: [URL: Int] = [:]
  var conservedBindingSites = true
  var isInspecting = false
  var inspectionRevision: UInt64 = 0
  private var inspectionGeneration = UUID()
  let projectURL: URL?
  var destinationURL: URL? { try? validatedDestinationURL() }
  var analysisName = "Primer analysis"
  var grouping: PrimerAnalysisGrouping = .independent
  var productSizeMin = "100"
  var productSizeMax = "400"
  var targetEnabled = false
  var targetStart = ""
  var targetEnd = ""
  var pairCount = "5"
  var primerMinSize = "18"
  var primerOptSize = "20"
  var primerMaxSize = "27"
  var primerMinTm = "57"
  var primerOptTm = "60"
  var primerMaxTm = "63"
  var primerMinGC = "20"
  var primerMaxGC = "80"
  var advancedExpanded = false
  var schemeMode: PrimerSchemeMode = .tiled {
    didSet { updateVarVAMPMode(from: oldValue) }
  }
  var ampliconSize = "400" {
    didSet { updateDefaultAmpliconBounds() }
  }
  var ampliconSizeMinimum = "360" {
    didSet {
      if !isUpdatingAmpliconBounds, ampliconSizeMinimum != oldValue { minimumAmpliconSizeWasCustomized = true }
    }
  }
  var ampliconSizeMaximum = "440" {
    didSet {
      if !isUpdatingAmpliconBounds, ampliconSizeMaximum != oldValue { maximumAmpliconSizeWasCustomized = true }
    }
  }
  private var minimumAmpliconSizeWasCustomized = false
  private var maximumAmpliconSizeWasCustomized = false
  private var isUpdatingAmpliconBounds = false
  var poolCount = "2"
  var minimumBaseFrequency = "0"
  var schemeWorkers = String(PrimerSchemeDesignOptions.defaultWorkers)

  // Olivar 1.3.3 adapter controls. Defaults mirror the typed workflow model.
  var olivarMinimumVariantFrequency = "0.01"
  var olivarDegenerate = false
  var olivarCheckVariants = false
  var olivarTemperatureC = "60"
  var olivarSalinityM = "0.18"
  var olivarMaximumDimerDeltaG = "-11.8"
  var olivarMinimumGC = "0.2"
  var olivarMaximumGC = "0.75"
  var olivarMinimumComplexity = "0.4"
  var olivarMaximumPrimerLength = "36"
  var olivarSeed = "10"
  var olivarEffort = "1"
  var olivarBlastDatabasePath = ""
  var olivarRiskExtremeGC = "1"
  var olivarRiskLowComplexity = "1"
  var olivarRiskNonSpecificity = "1"
  var olivarRiskVariation = "1"
  var olivarRiskSensitivity = "1"
  var olivarRiskCombination = "1"

  // varVAMP 1.3.2 controls. qPCR deliberately starts without a threshold.
  var varVAMPConsensusThreshold = ""
  var varVAMPMaximumPrimerAmbiguities = "2"
  var varVAMPMaximumProbeAmbiguities = ""
  var varVAMPTiledOverlap = "25"
  var varVAMPReportCount = ""
  var varVAMPQPCRTestCount = "50"
  var varVAMPQPCRDeltaG = "-3"
  var varVAMPSchemeName = "varVAMP"
  var varVAMPCompatiblePrimersPath = ""
  var varVAMPBlastDatabasePath = ""
  var varVAMPTerminalMaskingThreshold = "0.5"
  var varVAMPPrimerTmMinimum = "56"
  var varVAMPPrimerTmOptimum = "60"
  var varVAMPPrimerTmMaximum = "63"
  var varVAMPPrimerGCMinimum = "35"
  var varVAMPPrimerGCOptimum = "50"
  var varVAMPPrimerGCMaximum = "65"
  var varVAMPPrimerSizeMinimum = "18"
  var varVAMPPrimerSizeOptimum = "21"
  var varVAMPPrimerSizeMaximum = "24"
  var varVAMPPrimerMaximumPolyX = "4"
  var varVAMPPrimerMaximumDinucleotideRepeats = "4"
  var varVAMPPrimerHairpin = "47"
  var varVAMPPrimerGCEndMinimum = "1"
  var varVAMPPrimerGCEndMaximum = "3"
  var varVAMPPrimerMinimum3PrimeWithoutAmbiguity = "3"
  var varVAMPPrimerMaximumDimerTemperature = "35"
  var varVAMPPrimerMaximumDimerDeltaG = "-9000"
  var varVAMPEndOverlap = "5"
  var varVAMPProbeTmMinimum = "64"
  var varVAMPProbeTmOptimum = "67"
  var varVAMPProbeTmMaximum = "70"
  var varVAMPProbeSizeMinimum = "20"
  var varVAMPProbeSizeOptimum = "25"
  var varVAMPProbeSizeMaximum = "30"
  var varVAMPProbeGCMinimum = "40"
  var varVAMPProbeGCOptimum = "60"
  var varVAMPProbeGCMaximum = "80"
  var varVAMPProbeGCEndMinimum = "0"
  var varVAMPProbeGCEndMaximum = "4"
  var varVAMPQPrimerDifference = "2"
  var varVAMPProbeTemperatureDifferenceMinimum = "5"
  var varVAMPProbeTemperatureDifferenceMaximum = "10"
  var varVAMPProbeDistanceMinimum = "4"
  var varVAMPProbeDistanceMaximum = "15"
  var varVAMPAmpliconGCMinimum = "40"
  var varVAMPAmpliconGCMaximum = "60"
  var varVAMPAmpliconDeletionCutoff = "4"
  var varVAMPMonovalentCationConcentration = "100"
  var varVAMPDivalentCationConcentration = "2"
  var varVAMPDNTPConcentration = "0.8"
  var varVAMPDNAConcentration = "15"
  private var varVAMPSizingByMode: [PrimerSchemeMode: [String]] = [:]
  private var varVAMPBoundCustomizations: [PrimerSchemeMode: (minimum: Bool, maximum: Bool)] = [:]
  private var sizingByEngine: [PrimerDesignEngine: [String]] = [:]
  private var boundCustomizationsByEngine: [PrimerDesignEngine: (minimum: Bool, maximum: Bool)] = [:]
  private var lastVarVAMPMode: PrimerSchemeMode = .tiled
  private var isUpdatingEngine = false
  /// Required for non-legacy PrimalScheme contracts. Legacy designs continue
  /// using the managed runtime when this is empty.
  var primalschemeExecutablePath = ""
  var legacySalvageEnabled = false
  var legacySalvageThresholds = "-28,-30,-32"
  var legacySalvageFloor = "-32"
  var legacySalvageMaxEdgesPerPool = "8"
  var legacySalvageMaxIncidentSpeciesPerPool = "4"
  var legacySalvageMinReferenceGain = "1"
  var legacySalvageMaxCandidateEvaluations = "10000"
  var gapCompletionParentPath = ""
  var gapExpansionEnabled = false
  var gapExpansionMaxAnchorsPerMSA = "2000"
  var gapExpansionMaxPairsPerMSA = "1000"
  var minOverlap = "10"
  var highGC = false
  var dimerScore = "-26"
  var useMatchDB = true
  var backtrack = false
  var ignoreN = false
  var panelMode: PrimalScheme3PanelMode = .equal
  var maxAmplicons = ""
  var maxAmpliconsPerMSA = ""
  var coreCount = String(PrimalScheme3DesignOptions.defaultCoreCount)
  var excludeUncoveredEnds = true
  var errorMessage: String?
  var isRunning = false

  var isRunEnabled: Bool {
    !isRunning && validationMessage == nil && inputReadinessMessage == nil
  }

  init(projectURL: URL? = nil) { self.projectURL = projectURL?.resolvingSymlinksInPath().standardizedFileURL }

  /// GUI outputs are always direct children of the originating project's Analyses folder.
  /// Resolve the project once per check and reject even dangling links at the output boundary.
  func validatedDestinationURL(createParent: Bool = false) throws -> URL {
    guard let projectURL, projectURL.isFileURL else { throw invalid("Open a project before designing primers.") }
    let name = analysisName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
      !name.contains("/"), !name.contains("\\"), !name.contains(":"),
      name.rangeOfCharacter(from: .controlCharacters) == nil,
      name.utf8.count <= 200 else {
      throw invalid("Enter an analysis name without path separators or control characters (up to 200 bytes).")
    }
    let project = projectURL.resolvingSymlinksInPath().standardizedFileURL
    guard project == projectURL else { throw invalid("The originating project location changed. Reopen the primer design window.") }
    var isDirectory: ObjCBool = false
    let fm = FileManager.default
    guard fm.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw invalid("The originating project is no longer available.")
    }
    let parent = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
    if (try? fm.destinationOfSymbolicLink(atPath: parent.path)) != nil {
      throw invalid("The project's Analyses folder must not be a symbolic link.")
    }
    if createParent, !fm.fileExists(atPath: parent.path) {
      try fm.createDirectory(at: parent, withIntermediateDirectories: false)
    }
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedParent.deletingLastPathComponent() == project else {
      throw invalid("Primer analyses must be saved inside the originating project.")
    }
    if fm.fileExists(atPath: parent.path, isDirectory: &isDirectory), !isDirectory.boolValue {
      throw invalid("The project's Analyses path is not a folder.")
    }
    let destination = resolvedParent.appendingPathComponent(name + ".lungfishprimeranalysis", isDirectory: true)
    guard !fm.fileExists(atPath: destination.path),
      (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
      throw invalid("An analysis with this name already exists in the project. Enter a different name.")
    }
    return destination
  }

  var ampliconSpanDescription: String {
    do {
      let sizes = try validatedAmpliconSizes()
      return "Saved reference amplicon span: \(sizes.minimum)–\(sizes.maximum) bp, inclusive of both primer sites. Alternative primers and alleles may have different spans."
    } catch { return error.localizedDescription }
  }

  func addInputs(_ urls: [URL]) {
    for url in urls {
      let normalized = url.standardizedFileURL
      if !inputURLs.contains(normalized) { inputURLs.append(normalized) }
    }
  }

  func removeInput(_ url: URL) {
    inputURLs.removeAll { $0 == url }
    inputSummaries[url] = nil
    inputErrors[url] = nil
    selectedRecordIndices[url] = nil
    templateRowIndices[url] = nil
  }

  func refreshInputs() {
    inspectionGeneration = UUID()
    inputSummaries = [:]
    inputErrors = [:]
    selectedRecordIndices = [:]
    templateRowIndices = [:]
    errorMessage = nil
    inspectionRevision &+= 1
  }

  func inspectInputs() async {
    let generation = UUID()
    inspectionGeneration = generation
    isInspecting = true
    let urls = inputURLs
    for url in urls where inputSummaries[url] == nil {
      do {
        let summary = try await Primer3DesignPipeline.inspectInput(at: url)
        guard !Task.isCancelled, inspectionGeneration == generation, inputURLs.contains(url) else { return }
        inputSummaries[url] = summary
        inputErrors[url] = nil
        // FASTA selections are explicit in the visible checklist. Alignment templates
        // remain unselected until the user chooses a row.
        if !summary.isAlignment { selectedRecordIndices[url] = Set(summary.recordTitles.indices) }
      } catch {
        guard !Task.isCancelled, inspectionGeneration == generation else { return }
        inputErrors[url] = error.localizedDescription
      }
    }
    guard inspectionGeneration == generation else { return }
    isInspecting = false
  }

  var inputReadinessMessage: String? {
    if isInspecting { return "Reading input records…" }
    for url in inputURLs {
      if let error = inputErrors[url] { return "\(url.lastPathComponent): \(error)" }
      guard let summary = inputSummaries[url] else { return "Reading input records…" }
      if engine == .primer3 {
        if summary.isAlignment, templateRowIndices[url] == nil {
          return "Choose a template row for \(url.lastPathComponent)."
        }
        if !summary.isAlignment, selectedRecordIndices[url, default: []].isEmpty {
          return "Select at least one record in \(url.lastPathComponent)."
        }
      }
    }
    return nil
  }

  func primer3Selections() throws -> [Primer3TemplateSelection] {
    if let message = inputReadinessMessage { throw invalid(message) }
    return try inputURLs.flatMap { url -> [Primer3TemplateSelection] in
      guard let summary = inputSummaries[url] else { throw invalid("Input has not been read.") }
      if summary.isAlignment {
        guard let index = templateRowIndices[url] else { throw invalid("Choose an alignment template row.") }
        return [.msaTemplate(inputURL: url, rowIndex: index,
          bindingSitePolicy: conservedBindingSites ? .excludeVariableAndGappedColumns : .templateOnly)]
      }
      return selectedRecordIndices[url, default: []].sorted().map { .fastaRecord(inputURL: url, recordIndex: $0) }
    }
  }

  var validationMessage: String? {
    if inputURLs.isEmpty { return "Select sequence or alignment bundles in the project sidebar." }
    do {
      _ = try validatedDestinationURL()
      switch engine {
      case .primer3: _ = try primer3Options()
      case .primalScheme: _ = try primalSchemeOptions()
      case .olivar, .varVAMP: _ = try primerSchemeOptions()
      }
    } catch { return error.localizedDescription }
    return nil
  }

  func primalSchemeOptions() throws -> PrimalScheme3DesignOptions {
    if let executable = primalschemeExecutableURL {
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw invalid("Choose an executable PrimalScheme3 native binary or entrypoint script.")
      }
    }
    if gapCompletionParentURL != nil && legacySalvageEnabled {
      throw invalid("Choose either bounded salvage or a gap-completion follow-up parent, not both.")
    }
    let sizes = try validatedAmpliconSizes(for: .primalScheme)
    let overlap: Int
    if grouping == .independent {
      guard let value = Int(minOverlap.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
        throw invalid("Minimum overlap must be a nonnegative whole number.")
      }
      overlap = value
    } else { overlap = 10 }
    let options = PrimalScheme3DesignOptions(
      ampliconSize: sizes.target, poolCount: try positiveInteger(poolCount, "Pool count"),
      minOverlap: overlap, minimumBaseFrequency: try unitInterval(minimumBaseFrequency, "Minimum base frequency"), highGC: highGC,
      coreCount: try positiveInteger(coreCount, "CPU cores"),
      terminalGapPolicy: gapCompletionParentURL != nil ? .legacy : (excludeUncoveredEnds ? .observedOnly : .legacy),
      dimerScore: try finiteNumber(dimerScore, "Dimer score threshold"), useMatchDB: useMatchDB,
      backtrack: grouping == .independent && backtrack,
      ignoreN: grouping == .independent && ignoreN,
      panelMode: grouping == .combined ? panelMode : .equal,
      maxAmplicons: grouping == .combined ? try optionalPositiveInteger(maxAmplicons, "Maximum panel amplicons") : nil,
      maxAmpliconsPerMSA: grouping == .combined ? try optionalPositiveInteger(maxAmpliconsPerMSA, "Maximum amplicons per MSA") : nil,
      ampliconSizeMinimum: sizes.minimum, ampliconSizeMaximum: sizes.maximum,
      legacySalvageOptions: try legacySalvageOptions(),
      gapCompletionParent: gapCompletionParentURL,
      gapExpansionOptions: try gapExpansionOptions())
    try options.legacySalvageOptions.validate(selectionAlgorithm: options.selectionAlgorithm,
      grouping: grouping, panelMode: options.panelMode, strictCutoff: options.dimerScore)
    try options.gapExpansionOptions.validate(hasParent: options.gapCompletionParent != nil)
    if options.legacySalvageOptions.mode == .bounded || options.gapCompletionParent != nil {
      guard options.panelMode == .equal, options.maxAmplicons == nil, options.maxAmpliconsPerMSA == nil else {
        throw invalid("Recovery requires uniform position weighting and blank amplicon limits.")
      }
    }
    return options
  }

  func primerSchemeOptions() throws -> PrimerSchemeDesignOptions {
    guard let schemeEngine = engine.schemeEngine else {
      throw invalid("Choose Olivar or varVAMP to create primer-scheme options.")
    }
    let sizes = try validatedAmpliconSizes()
    let workers = try positiveInteger(schemeWorkers, "CPU workers")
    let resolvedGrouping = schemeEngine == .varvamp ? PrimerAnalysisGrouping.independent : grouping
    var suppliedCommonOptions: Set<String> = [
      "engine", "mode", "grouping", "nominalAmpliconLength", "minimumAmpliconLength",
      "maximumAmpliconLength", "workers",
    ]
    if minimumAmpliconSizeWasCustomized { suppliedCommonOptions.insert("requestedMinimumAmpliconLength") }
    if maximumAmpliconSizeWasCustomized { suppliedCommonOptions.insert("requestedMaximumAmpliconLength") }
    let options: PrimerSchemeDesignOptions
    switch schemeEngine {
    case .olivar:
      let riskWeights = OlivarRiskWeights(
        extremeGC: try nonnegativeNumber(olivarRiskExtremeGC, "Extreme-GC risk weight"),
        lowComplexity: try nonnegativeNumber(olivarRiskLowComplexity, "Low-complexity risk weight"),
        nonSpecificity: try nonnegativeNumber(olivarRiskNonSpecificity, "Non-specificity risk weight"),
        variation: try nonnegativeNumber(olivarRiskVariation, "Variation risk weight"),
        sensitivity: try nonnegativeNumber(olivarRiskSensitivity, "Sensitivity risk weight"),
        combination: try nonnegativeNumber(olivarRiskCombination, "Combination risk weight"))
      let native = OlivarDesignOptions(
        minimumVariantFrequency: try unitInterval(olivarMinimumVariantFrequency, "Olivar minimum variant frequency"),
        degenerate: olivarDegenerate, align: false,
        temperatureC: try finiteNumber(olivarTemperatureC, "Temperature"),
        salinityM: try nonnegativeNumber(olivarSalinityM, "Salinity"),
        maximumDimerDeltaG: try finiteNumber(olivarMaximumDimerDeltaG, "Maximum dimer ΔG"),
        minimumGC: try unitInterval(olivarMinimumGC, "Minimum GC fraction"),
        maximumGC: try unitInterval(olivarMaximumGC, "Maximum GC fraction"),
        minimumComplexity: try unitInterval(olivarMinimumComplexity, "Minimum complexity"),
        maximumPrimerLength: try positiveInteger(olivarMaximumPrimerLength, "Maximum primer length"),
        checkVariants: olivarCheckVariants, seed: try integer(olivarSeed, "Random seed"),
        effort: try positiveInteger(olivarEffort, "Search effort"),
        blastDatabasePath: optionalPath(olivarBlastDatabasePath), riskWeights: riskWeights,
        suppliedOptionNames: Set([
          "minimumVariantFrequency", "degenerate", "align", "temperatureC", "salinityM",
          "maximumDimerDeltaG", "minimumGC", "maximumGC", "minimumComplexity",
          "maximumPrimerLength", "checkVariants", "seed", "effort", "blastDatabasePath", "riskWeights",
        ]))
      options = .init(engine: .olivar, mode: .tiled, grouping: resolvedGrouping,
        nominalAmpliconLength: sizes.target, minimumAmpliconLength: sizes.minimum,
        maximumAmpliconLength: sizes.maximum,
        requestedMinimumAmpliconLength: minimumAmpliconSizeWasCustomized ? sizes.minimum : nil,
        requestedMaximumAmpliconLength: maximumAmpliconSizeWasCustomized ? sizes.maximum : nil,
        workers: workers, suppliedOptionNames: suppliedCommonOptions, olivar: native)
    case .varvamp:
      let threshold: Double?
      if varVAMPConsensusThreshold.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        threshold = nil
      } else {
        threshold = try positiveUnitInterval(varVAMPConsensusThreshold, "varVAMP cumulative consensus threshold")
      }
      let qPCR = schemeMode == .qpcr
      let overrides = VarVAMPConfigOverrides(
        terminalMaskingThreshold: try finiteNumber(varVAMPTerminalMaskingThreshold, "Terminal masking threshold"),
        primerTemperature: try doubleTriplet(varVAMPPrimerTmMinimum, varVAMPPrimerTmOptimum,
          varVAMPPrimerTmMaximum, "Primer temperature"),
        primerGCRange: try doubleTriplet(varVAMPPrimerGCMinimum, varVAMPPrimerGCOptimum,
          varVAMPPrimerGCMaximum, "Primer GC"),
        primerSizes: try intTriplet(varVAMPPrimerSizeMinimum, varVAMPPrimerSizeOptimum,
          varVAMPPrimerSizeMaximum, "Primer size"),
        primerMaximumPolyX: try nonnegativeInteger(varVAMPPrimerMaximumPolyX, "Maximum primer homopolymer"),
        primerMaximumDinucleotideRepeats: try nonnegativeInteger(varVAMPPrimerMaximumDinucleotideRepeats,
          "Maximum primer dinucleotide repeats"),
        primerHairpin: try finiteNumber(varVAMPPrimerHairpin, "Primer hairpin threshold"),
        primerGCEnd: try intRange(varVAMPPrimerGCEndMinimum, varVAMPPrimerGCEndMaximum, "Primer GC end"),
        primerMinimum3PrimeWithoutAmbiguity: try nonnegativeInteger(varVAMPPrimerMinimum3PrimeWithoutAmbiguity,
          "Minimum unambiguous 3-prime bases"),
        primerMaximumDimerTemperature: try finiteNumber(varVAMPPrimerMaximumDimerTemperature,
          "Maximum primer dimer temperature"),
        primerMaximumDimerDeltaG: try finiteNumber(varVAMPPrimerMaximumDimerDeltaG, "Maximum primer dimer ΔG"),
        endOverlap: try nonnegativeInteger(varVAMPEndOverlap, "End overlap"),
        probeTemperature: qPCR ? try doubleTriplet(varVAMPProbeTmMinimum, varVAMPProbeTmOptimum,
          varVAMPProbeTmMaximum, "Probe temperature") : nil,
        probeSizes: qPCR ? try intTriplet(varVAMPProbeSizeMinimum, varVAMPProbeSizeOptimum,
          varVAMPProbeSizeMaximum, "Probe size") : nil,
        probeGCRange: qPCR ? try doubleTriplet(varVAMPProbeGCMinimum, varVAMPProbeGCOptimum,
          varVAMPProbeGCMaximum, "Probe GC") : nil,
        probeGCEnd: qPCR ? try intRange(varVAMPProbeGCEndMinimum, varVAMPProbeGCEndMaximum, "Probe GC end") : nil,
        qprimerDifference: qPCR ? try finiteNumber(varVAMPQPrimerDifference, "qPCR primer difference") : nil,
        probeTemperatureDifference: qPCR ? try doubleRange(varVAMPProbeTemperatureDifferenceMinimum,
          varVAMPProbeTemperatureDifferenceMaximum, "Probe temperature difference") : nil,
        probeDistance: qPCR ? try intRange(varVAMPProbeDistanceMinimum, varVAMPProbeDistanceMaximum,
          "Probe distance") : nil,
        ampliconGCRange: qPCR ? try doubleRange(varVAMPAmpliconGCMinimum, varVAMPAmpliconGCMaximum,
          "Amplicon GC") : nil,
        ampliconDeletionCutoff: qPCR ? try nonnegativeInteger(varVAMPAmpliconDeletionCutoff,
          "Amplicon deletion cutoff") : nil,
        monovalentCationConcentration: try nonnegativeNumber(varVAMPMonovalentCationConcentration,
          "Monovalent cation concentration"),
        divalentCationConcentration: try nonnegativeNumber(varVAMPDivalentCationConcentration,
          "Divalent cation concentration"),
        dNTPConcentration: try nonnegativeNumber(varVAMPDNTPConcentration, "dNTP concentration"),
        DNAConcentration: try nonnegativeNumber(varVAMPDNAConcentration, "DNA concentration"))
      let native = VarVAMPDesignOptions(
        cumulativeConsensusThreshold: threshold,
        maximumPrimerAmbiguities: try nonnegativeInteger(varVAMPMaximumPrimerAmbiguities,
          "Maximum primer ambiguities"),
        maximumProbeAmbiguities: qPCR ? try optionalNonnegativeInteger(varVAMPMaximumProbeAmbiguities,
          "Maximum probe ambiguities") : nil,
        tiledOverlap: schemeMode == .tiled
          ? try nonnegativeInteger(varVAMPTiledOverlap, "Tiled overlap") : 25,
        reportCount: schemeMode == .single ? try optionalPositiveInteger(varVAMPReportCount,
          "Reported assay count") : nil,
        qpcrTestCount: qPCR ? try positiveInteger(varVAMPQPCRTestCount, "qPCR test count") : 50,
        qpcrDeltaG: qPCR ? try integer(varVAMPQPCRDeltaG, "qPCR ΔG threshold") : -3,
        schemeName: varVAMPSchemeName, compatiblePrimersPath: optionalPath(varVAMPCompatiblePrimersPath),
        blastDatabasePath: optionalPath(varVAMPBlastDatabasePath), configOverrides: overrides,
        suppliedOptionNames: Set(Set([
          "cumulativeConsensusThreshold", "maximumPrimerAmbiguities", "maximumProbeAmbiguities",
          "tiledOverlap", "reportCount", "qpcrTestCount", "qpcrDeltaG", "schemeName",
          "compatiblePrimersPath", "blastDatabasePath", "configOverrides",
        ]).filter { name in
          if name == "reportCount" { return schemeMode == .single }
          if name == "tiledOverlap" { return schemeMode == .tiled }
          if ["maximumProbeAmbiguities", "qpcrTestCount", "qpcrDeltaG"].contains(name) { return qPCR }
          return true
        }))
      options = .init(engine: .varvamp, mode: schemeMode, grouping: .independent,
        nominalAmpliconLength: sizes.target, minimumAmpliconLength: sizes.minimum,
        maximumAmpliconLength: sizes.maximum,
        requestedMinimumAmpliconLength: minimumAmpliconSizeWasCustomized ? sizes.minimum : nil,
        requestedMaximumAmpliconLength: maximumAmpliconSizeWasCustomized ? sizes.maximum : nil,
        workers: workers, suppliedOptionNames: suppliedCommonOptions, varvamp: native)
    }
    try options.validate()
    return options
  }

  var gapCompletionParentURL: URL? {
    guard grouping == .combined else { return nil }
    let path = gapCompletionParentPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL
  }

  private func legacySalvageOptions() throws -> PrimalScheme3LegacySalvageOptions {
    guard grouping == .combined, legacySalvageEnabled else {
      return .init()
    }
    let thresholds = try legacySalvageThresholds.split(separator: ",").map { try finiteNumber(String($0), "Salvage threshold") }
    return .init(mode: .bounded, thresholds: thresholds,
      floor: try finiteNumber(legacySalvageFloor, "Salvage floor"),
      maxEdgesPerPool: try nonnegativeInteger(legacySalvageMaxEdgesPerPool, "Maximum salvage edges per pool"),
      maxIncidentSpeciesPerPool: try nonnegativeInteger(legacySalvageMaxIncidentSpeciesPerPool, "Maximum incident species per pool"),
      minReferenceGain: try positiveInteger(legacySalvageMinReferenceGain, "Minimum reference gain"),
      maxCandidateEvaluations: try positiveInteger(legacySalvageMaxCandidateEvaluations, "Maximum candidate evaluations"))
  }

  private func gapExpansionOptions() throws -> PrimalScheme3GapExpansionOptions {
    guard gapExpansionEnabled else { return .init() }
    return .init(mode: .bounded,
      maxAnchorsPerMSA: try positiveInteger(gapExpansionMaxAnchorsPerMSA, "Maximum gap-expansion anchors per MSA"),
      maxPairsPerMSA: try positiveInteger(gapExpansionMaxPairsPerMSA, "Maximum gap-expansion pairs per MSA"))
  }

  var primalschemeExecutableURL: URL? {
    let path = primalschemeExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL
  }

  private func updateDefaultAmpliconBounds() {
    guard let target = Int(ampliconSize.trimmingCharacters(in: .whitespacesAndNewlines)),
      (100...2000).contains(target) else { return }
    isUpdatingAmpliconBounds = true
    defer { isUpdatingAmpliconBounds = false }
    if !minimumAmpliconSizeWasCustomized { ampliconSizeMinimum = String(Int(Double(target) * 0.9)) }
    if !maximumAmpliconSizeWasCustomized { ampliconSizeMaximum = String(Int(Double(target) * 1.1)) }
  }

  private func updateEngine(from oldEngine: PrimerDesignEngine) {
    guard oldEngine != engine else { return }
    let currentSizing = [ampliconSizeMinimum, ampliconSize, ampliconSizeMaximum]
    let currentCustomizations = (minimumAmpliconSizeWasCustomized, maximumAmpliconSizeWasCustomized)
    sizingByEngine[oldEngine] = currentSizing
    boundCustomizationsByEngine[oldEngine] = currentCustomizations
    if oldEngine == .varVAMP {
      lastVarVAMPMode = schemeMode
      varVAMPSizingByMode[schemeMode] = currentSizing
      varVAMPBoundCustomizations[schemeMode] = currentCustomizations
    }

    isUpdatingEngine = true
    defer { isUpdatingEngine = false }
    if engine == .olivar { schemeMode = .tiled }
    if engine == .varVAMP {
      grouping = .independent
      schemeMode = lastVarVAMPMode
    }
    let restored: [String]
    let restoredCustomizations: (minimum: Bool, maximum: Bool)
    if engine == .varVAMP {
      restored = varVAMPSizingByMode[schemeMode] ?? (schemeMode == .qpcr
        ? ["70", "135", "200"] : ["360", "400", "440"])
      restoredCustomizations = varVAMPBoundCustomizations[schemeMode] ?? (false, false)
    } else {
      restored = sizingByEngine[engine] ?? ["360", "400", "440"]
      restoredCustomizations = boundCustomizationsByEngine[engine] ?? (false, false)
    }
    applyAmpliconSizing(restored, customizations: restoredCustomizations)
  }

  private func applyAmpliconSizing(
    _ values: [String], customizations: (minimum: Bool, maximum: Bool)
  ) {
    precondition(values.count == 3)
    isUpdatingAmpliconBounds = true
    ampliconSizeMinimum = values[0]
    ampliconSize = values[1]
    ampliconSizeMaximum = values[2]
    isUpdatingAmpliconBounds = false
    minimumAmpliconSizeWasCustomized = customizations.minimum
    maximumAmpliconSizeWasCustomized = customizations.maximum
  }

  private func updateVarVAMPMode(from oldMode: PrimerSchemeMode) {
    guard engine == .varVAMP, !isUpdatingEngine, oldMode != schemeMode else { return }
    lastVarVAMPMode = schemeMode
    varVAMPSizingByMode[oldMode] = [ampliconSizeMinimum, ampliconSize, ampliconSizeMaximum]
    varVAMPBoundCustomizations[oldMode] = (minimumAmpliconSizeWasCustomized, maximumAmpliconSizeWasCustomized)
    let restored = varVAMPSizingByMode[schemeMode] ?? (schemeMode == .qpcr
      ? ["70", "135", "200"] : ["360", "400", "440"])
    let restoredCustomizations = varVAMPBoundCustomizations[schemeMode] ?? (false, false)
    applyAmpliconSizing(restored, customizations: restoredCustomizations)
  }

  private func validatedAmpliconSizes(
    for requestedEngine: PrimerDesignEngine? = nil
  ) throws -> (minimum: Int, target: Int, maximum: Int) {
    let target = try positiveInteger(ampliconSize, "Target amplicon size")
    if (requestedEngine ?? engine) == .primalScheme, !(100...2000).contains(target) {
      throw invalid("PrimalScheme3 target amplicon size must be between 100 and 2000 bp.")
    }
    let minimum = try positiveInteger(ampliconSizeMinimum, "Minimum amplicon size")
    let maximum = try positiveInteger(ampliconSizeMaximum, "Maximum amplicon size")
    guard minimum <= target, target <= maximum else {
      throw invalid("Amplicon sizes must be ordered minimum ≤ target ≤ maximum.")
    }
    return (minimum, target, maximum)
  }

  func primer3Options() throws -> Primer3DesignOptions {
    let productMin = try positiveInteger(productSizeMin, "Minimum product size")
    let productMax = try positiveInteger(productSizeMax, "Maximum product size")
    guard productMin <= productMax else { throw invalid("Product size minimum must not exceed its maximum.") }
    let minimumSize = try positiveInteger(primerMinSize, "Minimum primer length")
    let optimumSize = try positiveInteger(primerOptSize, "Optimum primer length")
    let maximumSize = try positiveInteger(primerMaxSize, "Maximum primer length")
    guard minimumSize <= optimumSize, optimumSize <= maximumSize else {
      throw invalid("Primer lengths must be ordered minimum ≤ optimum ≤ maximum.")
    }
    let minimumTm = try finiteNumber(primerMinTm, "Minimum primer Tm")
    let optimumTm = try finiteNumber(primerOptTm, "Optimum primer Tm")
    let maximumTm = try finiteNumber(primerMaxTm, "Maximum primer Tm")
    guard minimumTm <= optimumTm, optimumTm <= maximumTm else {
      throw invalid("Primer temperatures must be ordered minimum ≤ optimum ≤ maximum.")
    }
    let minimumGC = try finiteNumber(primerMinGC, "Minimum GC percentage")
    let maximumGC = try finiteNumber(primerMaxGC, "Maximum GC percentage")
    guard minimumGC >= 0, minimumGC <= maximumGC, maximumGC <= 100 else {
      throw invalid("GC percentages must be between 0 and 100, with minimum ≤ maximum.")
    }
    let start = targetEnabled ? try positiveInteger(targetStart, "Target start") : nil
    let end = targetEnabled ? try positiveInteger(targetEnd, "Target end") : nil
    if let start, let end, start > end { throw invalid("Target start must not exceed target end.") }
    return Primer3DesignOptions(
      productSizeMin: productMin, productSizeMax: productMax,
      targetStart: start, targetEnd: end, pairCount: try positiveInteger(pairCount, "Candidate pair count"),
      primerMinSize: minimumSize, primerOptSize: optimumSize, primerMaxSize: maximumSize,
      primerMinTm: minimumTm, primerOptTm: optimumTm, primerMaxTm: maximumTm,
      primerMinGC: minimumGC, primerMaxGC: maximumGC,
      pickInternalOligo: chemistry == .hydrolysisProbe)
  }

  private func optionalPositiveInteger(_ text: String, _ title: String) throws -> Int? {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    return try positiveInteger(text, title)
  }

  private func optionalNonnegativeInteger(_ text: String, _ title: String) throws -> Int? {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    return try nonnegativeInteger(text, title)
  }

  private func integer(_ text: String, _ title: String) throws -> Int {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw invalid("\(title) must be a whole number.")
    }
    return value
  }

  func positiveInteger(_ text: String, _ title: String) throws -> Int {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
      throw invalid("\(title) must be a positive whole number.")
    }
    return value
  }

  private func nonnegativeInteger(_ text: String, _ title: String) throws -> Int {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
      throw invalid("\(title) must be a nonnegative whole number.")
    }
    return value
  }

  private func finiteNumber(_ text: String, _ title: String) throws -> Double {
    guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
      throw invalid("\(title) must be a finite number.")
    }
    return value
  }

  private func nonnegativeNumber(_ text: String, _ title: String) throws -> Double {
    let value = try finiteNumber(text, title)
    guard value >= 0 else { throw invalid("\(title) must be nonnegative.") }
    return value
  }

  private func unitInterval(_ text: String, _ title: String) throws -> Double {
    let value = try finiteNumber(text, title)
    guard (0...1).contains(value) else { throw invalid("\(title) must be between 0 and 1.") }
    return value
  }

  private func positiveUnitInterval(_ text: String, _ title: String) throws -> Double {
    let value = try unitInterval(text, title)
    guard value > 0 else { throw invalid("\(title) must be greater than 0 and at most 1.") }
    return value
  }

  private func doubleTriplet(_ minimum: String, _ optimum: String, _ maximum: String,
                             _ title: String) throws -> PrimerSchemeDoubleTriplet {
    .init(minimum: try finiteNumber(minimum, "\(title) minimum"),
      maximum: try finiteNumber(maximum, "\(title) maximum"),
      optimum: try finiteNumber(optimum, "\(title) optimum"))
  }

  private func intTriplet(_ minimum: String, _ optimum: String, _ maximum: String,
                          _ title: String) throws -> PrimerSchemeIntTriplet {
    .init(minimum: try nonnegativeInteger(minimum, "\(title) minimum"),
      maximum: try nonnegativeInteger(maximum, "\(title) maximum"),
      optimum: try nonnegativeInteger(optimum, "\(title) optimum"))
  }

  private func doubleRange(_ minimum: String, _ maximum: String,
                           _ title: String) throws -> PrimerSchemeDoubleRange {
    .init(minimum: try finiteNumber(minimum, "\(title) minimum"),
      maximum: try finiteNumber(maximum, "\(title) maximum"))
  }

  private func intRange(_ minimum: String, _ maximum: String,
                        _ title: String) throws -> PrimerSchemeIntRange {
    .init(minimum: try nonnegativeInteger(minimum, "\(title) minimum"),
      maximum: try nonnegativeInteger(maximum, "\(title) maximum"))
  }

  private func optionalPath(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private func invalid(_ message: String) -> PrimerDesignValidationError { .init(message: message) }
}
