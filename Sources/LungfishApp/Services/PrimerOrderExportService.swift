import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum PrimerOrderExportError: Error, LocalizedError {
  case invalid(String)
  var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Creates an ordering derivative of saved evidence, never a newly optimized scheme.
struct PrimerOrderExportService: Sendable {
  static func prepare(snapshot: PrimerAnalysisViewerSnapshot, selection: PrimerOrderSelection) throws -> [PrimerOrderOligo] {
    guard snapshot.bundle.url.standardizedFileURL == selection.analysisURL.standardizedFileURL,
      snapshot.bundle.manifest == selection.manifest, snapshot.primer3Results == nil else {
      throw PrimerOrderExportError.invalid("The source analysis changed. Reopen it and capture a new order.")
    }
    guard !selection.settings.filterByCompatibility || selection.compatibilityReady else {
      throw PrimerOrderExportError.invalid("Complete the MSA comparison before exporting the filtered order.")
    }
    guard selection.settings.minimumCompatibilityPercent.isFinite,
      (0...100).contains(selection.settings.minimumCompatibilityPercent),
      selection.compatibilitySummaries.values.allSatisfy({
        $0.matchingRows >= 0 && $0.matchingRows <= $0.assessableRows && $0.assessableRows <= $0.totalRows
      }) else { throw PrimerOrderExportError.invalid("The captured display measurements are invalid.") }
    let targets = snapshot.designReview.filter { $0.presentation == .schemeReference }
    let visibility = PrimerAnalysisVisibility(settings: selection.settings,
      summaries: selection.compatibilitySummaries, compatibilityReady: selection.compatibilityReady)
    let displayed = targets.flatMap { target in visibility.visiblePrimers(in: target).map { (target, $0) } }
    guard !displayed.isEmpty, displayed.map({ $0.1.id }) == selection.selectedPrimerIDs,
      Set(selection.selectedPrimerIDs).count == selection.selectedPrimerIDs.count else {
      throw PrimerOrderExportError.invalid("The order does not match the captured displayed oligos.")
    }
    // Stable scheme ordinals are derived from the entire saved analysis, not the subset.
    var resultIDs: [String] = []
    for target in targets where !resultIDs.contains(target.sourceResultID) { resultIDs.append(target.sourceResultID) }
    return try displayed.map { target, primer in
      guard let pool = primer.pool, pool > 0, ["+", "-"].contains(primer.strand),
        !primer.sequence.isEmpty, primer.sequence.utf8.allSatisfy({ "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }),
        primer.start >= 0, primer.end > primer.start, primer.end <= target.referenceLength,
        let result = snapshot.bundle.manifest.results.first(where: { $0.artifactPaths.contains(target.sourceResultID) }),
        let index = resultIDs.firstIndex(of: target.sourceResultID) else {
        throw PrimerOrderExportError.invalid("A displayed oligo has no verified sequence, coordinates or pool membership.")
      }
      return .init(primerID: primer.id, targetID: target.id, sourceResultID: target.sourceResultID,
        schemeLabel: result.label ?? "Scheme \(index + 1)", poolName: "Scheme_\(index + 1)_Pool_\(pool)",
        pool: pool, referenceID: target.referenceID, name: primer.name, sequence: primer.sequence,
        start: primer.start, end: primer.end, strand: primer.strand, ampliconIDs: primer.ampliconIDs,
        compatibility: selection.compatibilityReady ? selection.compatibilitySummaries[primer.id] : nil)
    }
  }

  func export(selection: PrimerOrderSelection, metadata: PrimerOrderMetadata, destinationURL: URL,
    invocationArgv: [String], progress: (@Sendable (Double, String) -> Void)? = nil,
    publish: (@Sendable (URL, URL) async throws -> Void)? = nil) async throws -> URL {
    let worker = Task.detached(priority: .userInitiated) {
      try await Self.perform(selection: selection, metadata: metadata, destination: destinationURL,
        argv: invocationArgv, progress: progress, publish: publish)
    }
    return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
  }

  private static func perform(selection: PrimerOrderSelection, metadata: PrimerOrderMetadata, destination: URL,
    argv: [String], progress: (@Sendable (Double, String) -> Void)?,
    publish: (@Sendable (URL, URL) async throws -> Void)?) async throws -> URL {
    let started = Date(), fm = FileManager.default
    guard destination.isFileURL, !argv.isEmpty, argv.allSatisfy({ !$0.contains("\0") }),
      !metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      [metadata.name, metadata.requestedBy, metadata.project, metadata.orderReference, metadata.notes]
        .allSatisfy({ !$0.contains("\0") && $0.utf16.count <= 32767 }) else {
      throw PrimerOrderExportError.invalid("Provide an order name, valid metadata and an exact invocation.")
    }
    let parent = destination.deletingLastPathComponent()
    guard parent.resolvingSymlinksInPath().standardizedFileURL == parent.standardizedFileURL,
      !ProjectSessionPath.contains(destination, in: selection.analysisURL),
      !ProjectSessionPath.contains(selection.analysisURL, in: destination) else {
      throw PrimerOrderExportError.invalid("The order requires a separate output directory without symbolic links.")
    }
    try requireAbsent(destination)
    progress?(0.02, "Verifying the captured primer selection…")
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: selection.analysisURL)
    let oligos = try prepare(snapshot: snapshot, selection: selection)
    try Task.checkCancellation()
    let staged = parent.appendingPathComponent(".primer-order-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staged, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staged) }
    let source = staged.appendingPathComponent("source-analysis", isDirectory: true)
    try fm.createDirectory(at: source, withIntermediateDirectories: false)
    let manifestData = try Data(contentsOf: snapshot.bundle.url.appendingPathComponent("manifest.json"))
    guard try JSONDecoder().decode(PrimerAnalysisManifest.self, from: manifestData) == selection.manifest else {
      throw PrimerOrderExportError.invalid("The saved analysis changed during export.")
    }
    try manifestData.write(to: source.appendingPathComponent("manifest.json"))
    var copied: Set<String> = []
    for artifact in snapshot.bundle.manifest.artifacts + [snapshot.bundle.manifest.provenance] {
      try Task.checkCancellation()
      guard copied.insert(artifact.relativePath).inserted else { continue }
      let data = try Data(contentsOf: snapshot.bundle.artifactURL(forRelativePath: artifact.relativePath))
      guard data.count == artifact.byteSize, sha256(data) == artifact.sha256.lowercased() else {
        throw PrimerAnalysisBundleError.integrityMismatch(artifact.relativePath)
      }
      let target = source.appendingPathComponent(artifact.relativePath)
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: target)
    }
    progress?(0.35, "Creating the IDT workbook and detailed CSV…")
    let receipt = try await PrimerOrderSheetWriter.write(oligos: oligos, metadata: metadata, selection: selection, to: staged)
    let document = PrimerOrderDocument(schemaVersion: 1, metadata: metadata, selection: selection, oligos: oligos,
      outputDirectoryPath: destination.path, templateSHA256: receipt.templateSHA256,
      sequenceSemantics: "Exact saved oligos in 5prime-to-3prime orientation. User-filtered subset; no new design optimization or assay validation.")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(document).write(to: staged.appendingPathComponent(PrimerOrderDocument.filename))
    try AnalysesFolder.writeAnalysisMetadata(.init(tool: PrimerOrderDocument.toolID, isBatch: false), to: staged)
    let options = try resolvedOptions(selection: selection, metadata: metadata, templateHash: receipt.templateSHA256,
      manifestHash: sha256(manifestData), final: destination)
    let runtime = ProvenanceRuntimeIdentity()
    let files = try regularFiles(staged)
    func descriptor(_ url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
      let suffix = String(url.path.dropFirst(staged.path.count + 1))
      let isSource = suffix.hasPrefix("source-analysis/")
      return .init(path: destination.appendingPathComponent(suffix).path,
        checksumSHA256: try ProvenanceFileHasher.sha256(of: url), fileSize: try ProvenanceFileHasher.fileSize(of: url),
        format: url.pathExtension == "json" ? .json : nil, role: role,
        originPath: role == .input && isSource
          ? selection.analysisURL.appendingPathComponent(String(suffix.dropFirst("source-analysis/".count))).path : url.path,
        sourceProvenancePath: isSource ? destination.appendingPathComponent("source-analysis/" + selection.manifest.provenance.relativePath).path : nil)
    }
    let inputs = try files.filter { $0.path.hasPrefix(source.path + "/") || $0.lastPathComponent == "template.xlsx" }
      .map { try descriptor($0, role: .input) }
    let outputs = try files.map { try descriptor($0, role: .output) }
    var builder = ProvenanceRunBuilder(workflowName: "Export displayed primer order", workflowVersion: WorkflowRun.currentAppVersion,
      toolName: "LGE primer ordering", toolVersion: WorkflowRun.currentAppVersion)
      .argv(argv).options(explicit: options, defaults: ["sequenceOrientation": .string("saved-5prime-to-3prime"),
        "deduplicate": .boolean(false), "publication": .string("exclusive-atomic")], resolved: options).runtime(runtime)
    for input in inputs { builder = try builder.consumedInputSnapshot(input) }
    for output in outputs { builder = try builder.relocatedOutput(output) }
    for command in receipt.commands {
      let replay = command.argv.map { relocatedPath($0, staged: staged, final: destination) }
      let workdir = relocatedPath(command.workingDirectory, staged: staged, final: destination)
      let isUnzip = command.argv[0].hasSuffix("/unzip")
      let parts = isUnzip ? "template-parts" : URL(fileURLWithPath: command.workingDirectory).lastPathComponent
      let nativeInputs = isUnzip ? inputs.filter { $0.path == destination.appendingPathComponent("template.xlsx").path }
        : outputs.filter { $0.path.hasPrefix(destination.appendingPathComponent(parts).path + "/") }.map { $0.withRole(.input) }
      let nativeOutputs = isUnzip ? outputs.filter { $0.path.hasPrefix(destination.appendingPathComponent(parts).path + "/") }
        : outputs.filter { $0.path == destination.appendingPathComponent(parts == "upload-parts" ? "IDT-oPools.xlsx" : "primer-order.xlsx").path }
      builder = builder.step(.init(toolName: URL(fileURLWithPath: command.argv[0]).lastPathComponent,
        toolVersion: command.toolVersion, argv: command.argv,
        durableReplayArgv: replay,
        reproducibleCommand: "cd " + shellEscape(workdir) + " && " + replay.map(shellEscape).joined(separator: " "),
        resolvedOptions: ["workingDirectory": .string(workdir)], runtimeIdentity: runtime,
        inputs: nativeInputs, outputs: nativeOutputs, exitStatus: Int(command.exitStatus),
        wallTimeSeconds: command.completedAt.timeIntervalSince(command.startedAt), stderr: command.stderr,
        startedAt: command.startedAt, completedAt: command.completedAt))
    }
    let completed = Date()
    builder = builder.step(.init(toolName: "LGE primer ordering", toolVersion: WorkflowRun.currentAppVersion,
      argv: argv, resolvedOptions: options, runtimeIdentity: runtime, inputs: inputs, outputs: outputs,
      exitStatus: 0, wallTimeSeconds: completed.timeIntervalSince(started), startedAt: started, completedAt: completed))
    let envelope = try builder.complete(exitStatus: 0, startedAt: started, endedAt: completed)
    try ProvenanceWriter(signingProvider: nil).write(envelope, to: staged, bundleLayoutRoot: destination)
    progress?(0.95, "Saving the order in this project…")
    try Task.checkCancellation()
    if let publish { try await publish(staged, destination) }
    else { try PrimerAnalysisSelectionExportService.publishExclusively(stagedURL: staged, destinationURL: destination) }
    progress?(1, "Primer order saved.")
    return destination
  }

  static func load(from url: URL) throws -> PrimerOrderDocument {
    try loadSnapshot(from: url).document
  }

  static func loadSnapshot(from url: URL) throws -> PrimerOrderViewerSnapshot {
    try Task.checkCancellation()
    guard let envelope = try ProvenanceEnvelopeReader.load(from: url), envelope.exitStatus == 0 else {
      throw PrimerOrderExportError.invalid("The primer order has no completed provenance.")
    }
    var checked: Set<String> = []
    let originalRoot: String
    let bytes = try checkedData(relativePath: PrimerOrderDocument.filename, root: url)
    let document = try JSONDecoder().decode(PrimerOrderDocument.self, from: bytes)
    guard document.schemaVersion == 1, !document.oligos.isEmpty else {
      throw PrimerOrderExportError.invalid("This primer order format is unsupported or empty.")
    }
    originalRoot = document.outputDirectoryPath
    for output in envelope.outputs {
      try Task.checkCancellation()
      guard output.path.hasPrefix(originalRoot + "/") else {
        throw PrimerOrderExportError.invalid("The saved order contains an unrelated output path.")
      }
      let path = String(output.path.dropFirst(originalRoot.count + 1))
      guard checked.insert(path).inserted else { continue }
      let data = try checkedData(relativePath: path, root: url)
      guard UInt64(data.count) == output.fileSize, sha256(data) == output.checksumSHA256 else {
        throw PrimerOrderExportError.invalid("The saved primer order changed: \(path)")
      }
    }
    guard [PrimerOrderDocument.filename, "primer-order.xlsx", "IDT-oPools.xlsx", "ordering.csv", "template.xlsx"]
      .allSatisfy(checked.contains) else { throw PrimerOrderExportError.invalid("The primer order is missing verified outputs.") }
    return .init(document: document, provenance: envelope)
  }

  private static func resolvedOptions(selection: PrimerOrderSelection, metadata: PrimerOrderMetadata,
    templateHash: String, manifestHash: String, final: URL) throws -> [String: ParameterValue] {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return ["sourceAnalysisID": .string(selection.manifest.analysisID.uuidString),
      "sourceRunID": .string(selection.manifest.runID.uuidString), "sourceManifestSHA256": .string(manifestHash),
      "selectionDocument": .string(final.appendingPathComponent(PrimerOrderDocument.filename).path),
      "selectedPrimerIDs": .array(selection.selectedPrimerIDs.map(ParameterValue.string)),
      "displaySettingsJSON": .string(String(decoding: try encoder.encode(selection.settings), as: UTF8.self)),
      "orderMetadataJSON": .string(String(decoding: try encoder.encode(metadata), as: UTF8.self)),
      "compatibilityReady": .boolean(selection.compatibilityReady), "templateSHA256": .string(templateHash),
      "selectedCount": .integer(selection.selectedPrimerIDs.count), "deduplicate": .boolean(false),
      "sequenceOrientation": .string("saved-5prime-to-3prime"), "publication": .string("exclusive-atomic"),
      "scope": .string("displayed-oligos-across-all-schemes-and-references")]
  }

  private static func checkedData(relativePath: String, root: URL) throws -> Data {
    guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
      throw PrimerOrderExportError.invalid("An order file path is invalid.")
    }
    let url = root.appendingPathComponent(relativePath)
    guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
      try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw PrimerOrderExportError.invalid("An order file is missing or redirected.")
    }
    return try Data(contentsOf: url)
  }
  private static func regularFiles(_ root: URL) throws -> [URL] {
    guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
      throw PrimerOrderExportError.invalid("The order could not be inventoried.")
    }
    var result: [URL] = []
    for case let url as URL in iterator {
      try Task.checkCancellation()
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result.append(url) }
    }
    return result.sorted { $0.path < $1.path }
  }
  private static func requireAbsent(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) != 0, errno == ENOENT else {
      throw PrimerOrderExportError.invalid("An order already exists at this destination.")
    }
  }
  private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private static func relocatedPath(_ path: String, staged: URL, final: URL) -> String {
    path == staged.path || path.hasPrefix(staged.path + "/") ? final.path + String(path.dropFirst(staged.path.count)) : path
  }
}

private enum ProjectSessionPath {
  static func contains(_ child: URL, in parent: URL) -> Bool {
    let path = child.resolvingSymlinksInPath().path, root = parent.resolvingSymlinksInPath().path
    return path == root || path.hasPrefix(root + "/")
  }
}
