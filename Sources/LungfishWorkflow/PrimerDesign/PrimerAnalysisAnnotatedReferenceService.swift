import Darwin
import Foundation
import LungfishCore
import LungfishIO

public enum PrimerAnalysisAnnotatedReferenceError: Error, LocalizedError, Sendable {
  case unavailable(String)
  case annotationImportFailed(referenceURL: URL, reason: String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): return message
    case .annotationImportFailed(let url, let reason):
      return "The reference was created at \(url.path), but its primer annotations could not be attached: \(reason)"
    }
  }
}

/// Materializes a saved, annotated template as a native reference document.
/// The saved analysis and original source sequences are immutable inputs.
public struct PrimerAnalysisAnnotatedReferenceService: Sendable {
  public init() {}

  public func createReference(
    analysisURL: URL, resultID: UUID, outputDirectory: URL,
    invocationArgv: [String],
    progress: (@Sendable (Double, String) -> Void)? = nil
  ) async throws -> URL {
    let worker = Task.detached(priority: .userInitiated) {
      guard let physical = realpath(outputDirectory.path, nil) else {
        throw PrimerAnalysisAnnotatedReferenceError.unavailable("The output directory does not exist or cannot be resolved.")
      }
      let physicalOutput = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
      free(physical)
      let bundle = try PrimerAnalysisBundle.load(from: analysisURL) { try Task.checkCancellation() }
      let input = try Self.annotationInput(bundle: bundle, resultID: resultID)
      let sequences = try FASTAReader(url: input.templateURL).readAllSync(alphabet: .dna)
      guard sequences.count == 1, let sequence = sequences.first else {
        throw PrimerAnalysisAnnotatedReferenceError.unavailable("The stored template FASTA must contain exactly one record.")
      }
      let validationDirectory = physicalOutput.appendingPathComponent(".primer-annotation-validation-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: validationDirectory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: validationDirectory) }
      let validationDatabaseURL = validationDirectory.appendingPathComponent("annotations.sqlite")
      let featureCount = try AnnotationDatabase.createFromBED(bedURL: input.annotationURL, outputURL: validationDatabaseURL)
      let validationDatabase = try AnnotationDatabase(url: validationDatabaseURL)
      let features = validationDatabase.query(limit: featureCount)
      guard features.count == featureCount else {
        throw PrimerAnalysisAnnotatedReferenceError.unavailable("Stored primer annotations could not be read completely.")
      }
      let expectedLink = PrimerAnalysisAnnotationLink(
        analysisID: bundle.manifest.analysisID, resultID: resultID, inputID: input.inputID)
      guard !features.isEmpty else {
        throw PrimerAnalysisAnnotatedReferenceError.unavailable("This result has no primer annotations to import.")
      }
      for feature in features {
        guard feature.chromosome == sequence.name, feature.start >= 0,
          feature.end > feature.start, feature.end <= sequence.length,
          try PrimerAnalysisAnnotationLink.read(from: feature.toAnnotation()) == expectedLink else {
          throw PrimerAnalysisAnnotatedReferenceError.unavailable("Stored primer annotations do not match this template and analysis result.")
        }
      }
      try Task.checkCancellation()
      let imported = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
        sourceURL: input.templateURL, outputDirectory: physicalOutput,
        preferredBundleName: input.title + " primers",
        provenanceWorkflowName: "lungfish.primer-analysis.annotated-reference",
        provenanceCommand: invocationArgv,
        provenanceInputFiles: [bundle.url.appendingPathComponent("manifest.json"), input.templateURL, input.annotationURL],
        progressHandler: progress)
      // Once a reference has been published, finish attaching its annotations
      // before returning; a failure reports the existing partial reference path.
      do {
        _ = try await ReferenceBundleAnnotationImportService().attachAnnotationTrack(
          sourceURL: input.annotationURL, bundleURL: imported.bundleURL,
          trackID: "primer-analysis-\(resultID.uuidString.lowercased())",
          trackName: "Primer analysis: \(input.title)", invocationArgv: invocationArgv)
      } catch {
        throw PrimerAnalysisAnnotatedReferenceError.annotationImportFailed(
          referenceURL: imported.bundleURL, reason: error.localizedDescription)
      }
      return imported.bundleURL
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: { worker.cancel() }
  }

  struct AnnotationInput: Sendable {
    let inputID: UUID
    let templateURL: URL
    let annotationURL: URL
    let title: String
  }

  static func annotationInput(bundle: PrimerAnalysisBundle, resultID: UUID) throws -> AnnotationInput {
    guard let result = bundle.manifest.results.first(where: { $0.id == resultID }),
      result.inputIDs.count == 1,
      let input = bundle.manifest.inputs.first(where: { $0.id == result.inputIDs[0] }) else {
      throw PrimerAnalysisAnnotatedReferenceError.unavailable("This result does not identify a single annotated template.")
    }
    let templatePath = "inputs/\(input.id.uuidString).fasta"
    guard input.artifactPaths.contains(templatePath),
      let annotationPath = result.artifactPaths.first(where: { $0.lowercased().hasSuffix(".bed") }) else {
      throw PrimerAnalysisAnnotatedReferenceError.unavailable("This analysis does not contain a template FASTA and linked BED annotations.")
    }
    return AnnotationInput(
      inputID: input.id,
      templateURL: try bundle.artifactURL(forRelativePath: templatePath),
      annotationURL: try bundle.artifactURL(forRelativePath: annotationPath),
      title: result.label ?? input.label ?? "Primer template")
  }
}
