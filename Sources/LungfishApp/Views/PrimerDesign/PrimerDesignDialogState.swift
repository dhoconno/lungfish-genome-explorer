import Foundation
import Observation
import LungfishIO
import LungfishWorkflow

enum PrimerDesignEngine: String, CaseIterable, Identifiable {
  case primer3 = "Primer3"
  case primalScheme = "PrimalScheme3"
  var id: String { rawValue }
}

enum PrimerDesignChemistry: String, CaseIterable, Identifiable {
  case pcr = "PCR primers"
  case intercalatingDye = "qPCR · intercalating dye"
  case hydrolysisProbe = "qPCR · internal hydrolysis probe"
  var id: String { rawValue }
}

enum PrimerDesignMHCExemplar: String, CaseIterable, Identifiable {
  case classI = "MHC class I"
  case classIIDP = "MHC class II DP"
  case classIIDQ = "MHC class II DQ"
  case classIIDRB = "MHC class II DRB"
  var id: String { rawValue }
}

struct PrimerDesignValidationError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

@MainActor @Observable
final class PrimerDesignDialogState {
  var engine: PrimerDesignEngine = .primer3
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
  var destinationURL: URL?
  var analysisName = "MHC primer analysis"
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
  var ampliconSize = "400"
  var poolCount = "2"
  var minOverlap = "10"
  var minimumBaseFrequency = "0"
  var highGC = false
  var coreCount = "1"
  var excludeUncoveredEnds = false
  var executableOverride = ""
  var progressMessage: String?
  var errorMessage: String?
  var completedURL: URL?
  var isRunning = false

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
  func applyExemplar(_ exemplar: PrimerDesignMHCExemplar) { analysisName = exemplar.rawValue }

  func refreshInputs() {
    inspectionGeneration = UUID()
    inputSummaries = [:]
    inputErrors = [:]
    selectedRecordIndices = [:]
    templateRowIndices = [:]
    completedURL = nil
    progressMessage = nil
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
    if inputURLs.isEmpty { return "Add a FASTA file or multiple sequence alignment." }
    if analysisName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Enter an analysis name."
    }
    guard let destinationURL else { return "Choose where to save the analysis." }
    if destinationURL.pathExtension.lowercased() != "lungfishprimeranalysis" {
      return "Save the analysis with the .lungfishprimeranalysis extension."
    }
    do {
      if engine == .primer3 { _ = try primer3Options() }
      else {
        _ = try primalSchemeOptions()
      }
    } catch { return error.localizedDescription }
    return nil
  }

  func primalSchemeOptions() throws -> PrimalScheme3DesignOptions {
    let size = try positiveInteger(ampliconSize, "Amplicon size")
    guard (100...2000).contains(size) else { throw invalid("PrimalScheme3 amplicon size must be between 100 and 2000 bp.") }
    let overlap: Int
    if grouping == .independent {
      guard let value = Int(minOverlap.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
        throw invalid("Minimum overlap must be a nonnegative whole number.")
      }
      overlap = value
    } else { overlap = 10 }
    let frequency = try finiteNumber(minimumBaseFrequency, "Minimum base frequency")
    guard (0...1).contains(frequency) else { throw invalid("Minimum base frequency must be between 0 and 1.") }
    return PrimalScheme3DesignOptions(
      ampliconSize: size, poolCount: try positiveInteger(poolCount, "Pool count"),
      minOverlap: overlap, minimumBaseFrequency: frequency, highGC: highGC,
      coreCount: try positiveInteger(coreCount, "CPU cores"))
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

  func positiveInteger(_ text: String, _ title: String) throws -> Int {
    guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
      throw invalid("\(title) must be a positive whole number.")
    }
    return value
  }

  private func finiteNumber(_ text: String, _ title: String) throws -> Double {
    guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
      throw invalid("\(title) must be a finite number.")
    }
    return value
  }

  private func invalid(_ message: String) -> PrimerDesignValidationError { .init(message: message) }
}
