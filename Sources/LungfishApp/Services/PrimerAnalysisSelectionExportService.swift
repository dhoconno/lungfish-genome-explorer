import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum PrimerAnalysisExportSelection: Sendable, Equatable, Codable {
  case primer(targetID: String, primerID: String)
  case amplicon(targetID: String, ampliconID: String)
  case pool(sourceResultID: String, pool: Int)
}

enum PrimerAnalysisExportKind: String, Sendable, Equatable, Codable {
  case primerFASTA
  case referenceAmplicon
}

enum PrimerAnalysisSelectionExportError: Error, LocalizedError {
  case unavailable(String)
  var errorDescription: String? {
    switch self { case .unavailable(let message): return message }
  }
}

/// Publishes derivatives of immutable saved design evidence. Selection identities
/// are resolved again at execution; UI coordinates and sequences are never inputs.
struct PrimerAnalysisSelectionExportService: Sendable {
  struct Record: Sendable, Codable {
    let name: String
    let description: String
    let sequence: String
  }

  struct Prepared: Sendable {
    let records: [Record]
    let annotationBED: String?
    let options: [String: ParameterValue]
    let sourcePaths: [String]
    var fasta: String { records.map { ">\($0.name) \($0.description)\n\($0.sequence)\n" }.joined() }
  }

  private struct SelectionDocument: Codable {
    let schemaVersion: Int
    let analysisID: UUID
    let runID: UUID
    let selection: PrimerAnalysisExportSelection
    let kind: PrimerAnalysisExportKind
    let outputBundlePath: String
    let options: [String: ParameterValue]
    let records: [Record]
    let retainedSourceArtifacts: [String]
  }

  func export(
    analysisURL: URL, selection: PrimerAnalysisExportSelection, kind: PrimerAnalysisExportKind,
    destinationURL: URL, invocationArgv: [String],
    progress: (@Sendable (Double, String) -> Void)? = nil,
    publish: (@Sendable (_ stagedURL: URL, _ destinationURL: URL) async throws -> Void)? = nil
  ) async throws -> URL {
    let worker = Task.detached(priority: .userInitiated) {
      try await Self.perform(analysisURL: analysisURL, selection: selection, kind: kind,
        destinationURL: destinationURL, invocationArgv: invocationArgv, progress: progress,
        publish: publish)
    }
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
  }

  static func prepare(snapshot: PrimerAnalysisViewerSnapshot, selection: PrimerAnalysisExportSelection,
                      kind: PrimerAnalysisExportKind) throws -> Prepared {
    func unavailable(_ text: String) -> PrimerAnalysisSelectionExportError { .unavailable(text) }
    let targets: [PrimerTargetDesignReview]
    var selectedPrimers: [(PrimerTargetDesignReview, PrimerReviewPrimer)] = []
    var selectedAmplicon: PrimerReviewInterval?
    switch selection {
    case .primer(let targetID, let primerID):
      guard let target = snapshot.designReview.first(where: { $0.id == targetID }),
        let primer = target.primers.first(where: { $0.id == primerID }) else {
        throw unavailable("This primer is no longer present in the saved analysis.")
      }
      targets = [target]; selectedPrimers = [(target, primer)]
    case .amplicon(let targetID, let ampliconID):
      guard let target = snapshot.designReview.first(where: { $0.id == targetID }),
        let amplicon = target.intervals.first(where: { $0.id == ampliconID }) else {
        throw unavailable("This amplicon is no longer present in the saved analysis.")
      }
      targets = [target]; selectedAmplicon = amplicon
      selectedPrimers = target.primers.filter {
        amplicon.primerIDs.contains($0.id) && $0.ampliconIDs.contains(amplicon.id)
      }.map { (target, $0) }
    case .pool(let sourceResultID, let pool):
      guard pool > 0 else { throw unavailable("Choose a saved primer pool.") }
      targets = snapshot.designReview.filter { $0.sourceResultID == sourceResultID }
      selectedPrimers = targets.flatMap { target in target.primers.filter { $0.pool == pool }.map { (target, $0) } }
    }
    guard !targets.isEmpty else { throw unavailable("This target is no longer present in the saved analysis.") }
    let internalOligoIDs = Set(snapshot.primer3Results?.results.flatMap { result in
      result.pairs.compactMap { $0.internalOligo?.id.uuidString }
    } ?? [])
    var paths: Set<String> = []
    for target in targets {
      let result: PrimerAnalysisResult?
      if snapshot.primer3Results != nil {
        result = snapshot.bundle.manifest.results.first { $0.id.uuidString == target.sourceResultID }
        paths.insert("results/primer3-normalized-v1.json")
      } else {
        result = snapshot.bundle.manifest.results.first { $0.artifactPaths.contains(target.sourceResultID) }
        let prefix = String(target.sourceResultID.dropLast("primer.bed".count))
        paths.formUnion([prefix + "primer.bed", prefix + "reference.fasta"])
        if let result, result.artifactPaths.contains(prefix + "amplicon.bed") { paths.insert(prefix + "amplicon.bed") }
      }
      guard let result else { throw unavailable("The selection has no saved result membership.") }
      for input in snapshot.bundle.manifest.inputs where result.inputIDs.contains(input.id) {
        paths.formUnion(input.artifactPaths)
      }
    }
    // Parent envelopes remain immutable evidence, not newly executed tool steps.
    paths.formUnion(snapshot.bundle.manifest.artifacts.filter {
      ["toolProvenance", "derivedProvenance", "workflowProvenance", "provenance-support"].contains($0.role)
    }.map(\.relativePath))
    paths.insert(snapshot.bundle.manifest.provenance.relativePath)
    var options: [String: ParameterValue] = [
      "analysisID": .string(snapshot.bundle.manifest.analysisID.uuidString),
      "runID": .string(snapshot.bundle.manifest.runID.uuidString),
      "targetIDs": .array(targets.map { .string($0.id) }),
      "sourceResultIDs": .array(Array(Set(targets.map(\.sourceResultID))).sorted().map(ParameterValue.string)),
      "coordinateConvention": .string("zero-based-half-open"),
      "kind": .string(kind.rawValue),
      "primers": .array(selectedPrimers.map { target, primer in .dictionary([
        "targetID": .string(target.id), "referenceID": .string(target.referenceID),
        "primerID": .string(primer.id), "name": .string(primer.name),
        "start": .integer(primer.start), "end": .integer(primer.end),
        "strand": .string(primer.strand), "pool": primer.pool.map(ParameterValue.integer) ?? .string("unpooled"),
        "oligoType": .string(internalOligoIDs.contains(primer.id) ? "internal_oligo" : "primer_bind"),
        "sequence5primeTo3prime": .string(primer.sequence),
      ]) }),
    ]
    if case .pool(_, let pool) = selection { options["pool"] = .integer(pool) }
    if let amplicon = selectedAmplicon {
      options["ampliconID"] = .string(amplicon.id)
      options["ampliconName"] = .string(amplicon.name)
      options["sourceStart"] = .integer(amplicon.start)
      options["sourceEnd"] = .integer(amplicon.end)
      if let pool = amplicon.pool { options["pool"] = .integer(pool) }
    }
    if kind == .primerFASTA {
      guard !selectedPrimers.isEmpty else {
        throw unavailable("No verified primer membership is available for this selection.")
      }
      let records = try selectedPrimers.enumerated().map { ordinal, item in
        let (target, primer) = item
        guard !primer.sequence.isEmpty, primer.sequence.utf8.allSatisfy({ "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }) else {
          throw unavailable("The saved primer sequence is unavailable or invalid.")
        }
        return Record(name: "primer_\(ordinal + 1)_\(safeToken(primer.name))",
          description: "name=\(safeHeader(primer.name)) target=\(safeHeader(target.referenceID)) pool=\(primer.pool.map(String.init) ?? "unpooled") strand=\(primer.strand) orientation=5prime-to-3prime",
          sequence: primer.sequence)
      }
      options["sequenceSemantics"] = .string("stored-oligos-5prime-to-3prime")
      options["recordPrimerIDs"] = .array(selectedPrimers.map { .string($0.1.id) })
      return Prepared(records: records, annotationBED: nil, options: options, sourcePaths: paths.sorted())
    }
    guard let amplicon = selectedAmplicon, targets.count == 1, let target = targets.first else {
      throw unavailable("Select an explicit saved amplicon to extract its reference span.")
    }
    let sequence: String
    if let normalized = snapshot.primer3Results,
      let result = normalized.results.first(where: { $0.resultID.uuidString == target.sourceResultID }) {
      sequence = result.templateSequence
    } else {
      let path = String(target.sourceResultID.dropLast("primer.bed".count)) + "reference.fasta"
      let bytes = try verifiedSource(path, bundle: snapshot.bundle)
      sequence = try referenceSequence(bytes, id: target.referenceID)
    }
    let bytes = Array(sequence.utf8)
    guard amplicon.start >= 0, amplicon.end > amplicon.start, amplicon.end <= bytes.count else {
      throw unavailable("The saved amplicon exceeds the reference sequence.")
    }
    let recordName = "amplicon_" + safeToken(amplicon.name)
    let record = Record(name: recordName,
      description: "reference=\(safeHeader(target.referenceID)) start0=\(amplicon.start) end=\(amplicon.end) orientation=forward-reference pool=\(amplicon.pool.map(String.init) ?? "unpooled")",
      sequence: String(decoding: bytes[amplicon.start..<amplicon.end], as: UTF8.self))
    let bed = try selectedPrimers.map { _, primer in
      guard primer.start >= amplicon.start, primer.end <= amplicon.end else {
        throw unavailable("A linked primer extends beyond this saved amplicon.")
      }
      let start = primer.start - amplicon.start, end = primer.end - amplicon.start
      let qualifiers = ["source_primer_id=\(safeQualifier(primer.id))",
        "source_analysis_id=\(snapshot.bundle.manifest.analysisID.uuidString)",
        "source_amplicon_id=\(safeQualifier(amplicon.id))", "source_reference=\(safeQualifier(target.referenceID))",
        "source_start=\(primer.start)", "source_end=\(primer.end)",
        "pool=\(primer.pool.map(String.init) ?? "unpooled")",
        "sequence_5prime_to_3prime=\(safeQualifier(primer.sequence))"].joined(separator: ";")
      return [recordName, String(start), String(end), safeHeader(primer.name), "0", primer.strand,
        String(start), String(end), "0,102,204", "1", String(end - start), "0",
        internalOligoIDs.contains(primer.id) ? "internal_oligo" : "primer_bind", qualifiers].joined(separator: "\t")
    }.joined(separator: "\n")
    options["referenceID"] = .string(target.referenceID)
    options["sequenceSemantics"] = .string(snapshot.primer3Results == nil
      ? "saved-reference-span-including-primers" : "saved-template-product-including-primers")
    options["orientation"] = .string("forward-reference")
    options["primerMembership"] = .string(selectedPrimers.isEmpty ? "unavailable" : "verified-saved-membership")
    return Prepared(records: [record], annotationBED: bed.isEmpty ? nil : bed + "\n", options: options, sourcePaths: paths.sorted())
  }

  private static func perform(
    analysisURL: URL, selection: PrimerAnalysisExportSelection, kind: PrimerAnalysisExportKind,
    destinationURL: URL, invocationArgv: [String], progress: (@Sendable (Double, String) -> Void)?,
    publish: (@Sendable (URL, URL) async throws -> Void)?
  ) async throws -> URL {
    let startedAt = Date(), fm = FileManager.default
    guard !invocationArgv.isEmpty, invocationArgv.allSatisfy({ !$0.contains("\0") }),
      destinationURL.isFileURL, destinationURL.pathExtension == "lungfishref" else {
      throw PrimerAnalysisSelectionExportError.unavailable("A new Lungfish reference destination and exact invocation are required.")
    }
    let parent = destinationURL.deletingLastPathComponent()
    guard parent.resolvingSymlinksInPath().standardizedFileURL == parent.standardizedFileURL else {
      throw PrimerAnalysisSelectionExportError.unavailable("The output directory must not redirect through a symbolic link.")
    }
    try requireAbsent(destinationURL)
    progress?(0.02, "Verifying saved primer analysis…")
    let snapshot = try PrimerAnalysisViewerSnapshot.load(from: analysisURL)
    let prepared = try prepare(snapshot: snapshot, selection: selection, kind: kind)
    try Task.checkCancellation()
    let staging = parent.appendingPathComponent(".primer-selection-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staging) }
    let sourceRoot = staging.appendingPathComponent("source-analysis", isDirectory: true)
    try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
    let manifestBytes = try Data(contentsOf: analysisURL.appendingPathComponent("manifest.json"))
    guard try JSONDecoder().decode(PrimerAnalysisManifest.self, from: manifestBytes) == snapshot.bundle.manifest else {
      throw PrimerAnalysisSelectionExportError.unavailable("The source analysis changed while preparing this export.")
    }
    try manifestBytes.write(to: sourceRoot.appendingPathComponent("manifest.json"), options: .atomic)
    for path in prepared.sourcePaths {
      try Task.checkCancellation()
      let bytes = try verifiedSource(path, bundle: snapshot.bundle)
      let retained = sourceRoot.appendingPathComponent(path)
      try fm.createDirectory(at: retained.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: retained, options: .atomic)
    }
    let payloadName = kind == .primerFASTA ? "primers.fasta" : "amplicon.fasta"
    let fasta = staging.appendingPathComponent(payloadName)
    try prepared.fasta.write(to: fasta, atomically: true, encoding: .utf8)
    let annotationURL = staging.appendingPathComponent("binding-sites.bed")
    if let bed = prepared.annotationBED { try bed.write(to: annotationURL, atomically: true, encoding: .utf8) }
    let workflowName = "lungfish.primer-analysis.selection-export"
    let built = try await NativeBundleBuilder().build(configuration: BuildConfiguration(
      name: destinationURL.deletingPathExtension().lastPathComponent,
      identifier: "org.lungfish.primer-selection.\(UUID().uuidString.lowercased())",
      fastaURL: fasta,
      annotationFiles: prepared.annotationBED == nil ? [] : [.init(url: annotationURL,
        name: "Saved primer binding sites", description: "Stored reference footprints; not predicted allele products.", id: "primer-binding-sites")],
      outputDirectory: staging, source: SourceInfo(organism: "Unspecified", assembly: "Saved primer analysis selection",
        sourceURL: analysisURL, downloadDate: Date(), notes: "Derived from saved design evidence; no new primer design was performed."),
      compressFASTA: false, provenanceWorkflowName: workflowName, provenanceCommand: invocationArgv,
      provenanceInputFiles: [sourceRoot.appendingPathComponent("manifest.json")] + prepared.sourcePaths.map { sourceRoot.appendingPathComponent($0) }
    )) { _, fraction, message in progress?(0.15 + 0.6 * fraction, message) }
    let nativeEnvelope = try ProvenanceEnvelopeReader.load(from: built)
    try fm.copyItem(at: sourceRoot, to: built.appendingPathComponent("source-analysis"))
    try fm.copyItem(at: fasta, to: built.appendingPathComponent(payloadName))
    if prepared.annotationBED != nil { try fm.copyItem(at: annotationURL, to: built.appendingPathComponent("binding-sites.bed")) }
    var options = prepared.options
    options["outputBundle"] = .file(destinationURL)
    options["publication"] = .string("exclusive-atomic")
    options["compressFASTA"] = .boolean(false)
    options["includePrimerSites"] = .boolean(prepared.annotationBED != nil)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(SelectionDocument(schemaVersion: 1, analysisID: snapshot.bundle.manifest.analysisID,
      runID: snapshot.bundle.manifest.runID, selection: selection, kind: kind, outputBundlePath: destinationURL.path,
      options: options, records: prepared.records, retainedSourceArtifacts: ["manifest.json"] + prepared.sourcePaths))
      .write(to: built.appendingPathComponent("selection.json"), options: .atomic)
    try writeProvenance(snapshot: snapshot, prepared: prepared, nativeEnvelope: nativeEnvelope,
      built: built, staging: staging, final: destinationURL, workflowName: workflowName,
      argv: invocationArgv, options: options, startedAt: startedAt)
    progress?(0.95, "Publishing selected primer analysis data…")
    try Task.checkCancellation()
    if let publish { try await publish(built, destinationURL) }
    else { try publishExclusively(stagedURL: built, destinationURL: destinationURL) }
    // The publication callback commits its Operations result in the same turn
    // as the rename. Cancellation after that point must not erase the result.
    progress?(1, "Selection saved in the project.")
    return destinationURL
  }

  static func publishExclusively(stagedURL: URL, destinationURL: URL) throws {
    try Task.checkCancellation()
    try requireAbsent(destinationURL)
    let status = stagedURL.path.withCString { source in destinationURL.path.withCString { destination in
      renamex_np(source, destination, UInt32(RENAME_EXCL))
    } }
    guard status == 0 else {
      throw PrimerAnalysisSelectionExportError.unavailable("Could not publish the new reference without replacing existing data: \(String(cString: strerror(errno))).")
    }
  }

  private static func writeProvenance(snapshot: PrimerAnalysisViewerSnapshot, prepared: Prepared,
    nativeEnvelope: ProvenanceEnvelope?, built: URL, staging: URL, final: URL, workflowName: String,
    argv: [String], options: [String: ParameterValue], startedAt: Date) throws {
    let fm = FileManager.default
    // Replace only this unpublished derivative's builder provenance. Parent scientific
    // provenance is retained byte-for-byte under source-analysis.
    for url in [built.appendingPathComponent(ProvenanceWriter.provenanceFilename),
      built.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName)] where fm.fileExists(atPath: url.path) {
      try fm.removeItem(at: url)
    }
    func relocated(_ url: URL, role: FileRole, origin: String? = nil) throws -> ProvenanceFileDescriptor {
      let bytes = try Data(contentsOf: url)
      return .init(path: final.path + String(url.path.dropFirst(built.path.count)),
        checksumSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        fileSize: UInt64(bytes.count), format: url.pathExtension == "json" ? .json : nil,
        role: role, originPath: origin ?? url.path,
        sourceProvenancePath: role == .input ? final.appendingPathComponent("source-analysis/" + snapshot.bundle.manifest.provenance.relativePath).path : nil)
    }
    let outputs = try regularFiles(built).map { try relocated($0, role: $0.pathExtension == "fai" ? .index : .output) }
    let inputs = try (["manifest.json"] + prepared.sourcePaths).map { path in
      try relocated(built.appendingPathComponent("source-analysis/" + path), role: .input,
        origin: snapshot.bundle.url.appendingPathComponent(path).path)
    }
    let runtime = ProvenanceRuntimeIdentity()
    let completedAt = Date()
    var builder = ProvenanceRunBuilder(workflowName: workflowName, workflowVersion: WorkflowRun.currentAppVersion,
      toolName: workflowName, toolVersion: WorkflowRun.currentAppVersion).argv(argv)
      .options(explicit: prepared.options, defaults: ["compressFASTA": .boolean(false),
        "publication": .string("exclusive-atomic"), "includePrimerSites": .boolean(prepared.annotationBED != nil)], resolved: options)
      .runtime(runtime)
    for input in inputs { builder = try builder.consumedInputSnapshot(input) }
    for output in outputs { builder = try builder.relocatedOutput(output) }
    builder = builder.step(.init(toolName: workflowName, toolVersion: WorkflowRun.currentAppVersion,
      argv: argv, resolvedOptions: options, runtimeIdentity: runtime, inputs: inputs, outputs: outputs,
      exitStatus: 0, wallTimeSeconds: completedAt.timeIntervalSince(startedAt), startedAt: startedAt, completedAt: completedAt))
    if let nativeEnvelope {
      let outputsBySuffix = Dictionary(uniqueKeysWithValues: outputs.map { (String($0.path.dropFirst(final.path.count)), $0) })
      for step in nativeEnvelope.steps where step.toolName != workflowName {
        func mapDescriptor(_ descriptor: ProvenanceFileDescriptor) -> ProvenanceFileDescriptor {
          if descriptor.path.hasPrefix(built.path + "/"),
            let output = outputsBySuffix[String(descriptor.path.dropFirst(built.path.count))] {
            return output.withRole(descriptor.role)
          }
          if descriptor.path.hasPrefix(staging.appendingPathComponent("source-analysis").path + "/") {
            let suffix = String(descriptor.path.dropFirst(staging.appendingPathComponent("source-analysis").path.count + 1))
            if let input = inputs.first(where: { $0.path == final.appendingPathComponent("source-analysis/" + suffix).path }) { return input }
          }
          return descriptor
        }
        let stepInputs = step.inputs.map(mapDescriptor), stepOutputs = step.outputs.map(mapDescriptor)
        var pathMap: [String: String] = [:]
        for (old, new) in zip(step.inputs + step.outputs, stepInputs + stepOutputs) {
          pathMap[old.path] = new.path
          if let origin = old.originPath { pathMap[origin] = new.path }
        }
        let replay = try (step.durableReplayArgv ?? step.argv).map { argument in
          if let mapped = pathMap[argument] { return mapped }
          guard argument.hasPrefix(staging.path + "/") else { return argument }
          // NativeBundleBuilder publishes descriptors under `built`, while its
          // actual subprocess argv names a private sub-staging bundle. Resolve
          // only an exact, unique file suffix from this step's known descriptors.
          let matches = Set(zip(step.inputs + step.outputs, stepInputs + stepOutputs).compactMap { old, new -> String? in
            guard old.path.hasPrefix(built.path + "/") else { return nil }
            let suffix = String(old.path.dropFirst(built.path.count))
            return argument.hasSuffix(suffix) ? new.path : nil
          })
          guard matches.count == 1, let mapped = matches.first else {
            throw PrimerAnalysisSelectionExportError.unavailable("A native indexing command could not be linked to its final saved files.")
          }
          return mapped
        }
        builder = builder.step(.init(id: step.id, toolName: step.toolName, toolVersion: step.toolVersion,
          githubReleaseVersion: step.githubReleaseVersion, argv: step.argv, durableReplayArgv: replay,
          reproducibleCommand: replay.map(shellEscape).joined(separator: " "),
          resolvedOptions: step.resolvedOptions, runtimeIdentity: step.runtimeIdentity ?? runtime,
          inputs: stepInputs, outputs: stepOutputs, exitStatus: step.exitStatus,
          wallTimeSeconds: step.wallTimeSeconds, stderr: step.stderr, dependsOn: step.dependsOn,
          startedAt: step.startedAt, completedAt: step.completedAt))
      }
    }
    let envelope = try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
    try ProvenanceWriter(signingProvider: nil).write(envelope, to: built, bundleLayoutRoot: final)
  }

  private static func verifiedSource(_ path: String, bundle: PrimerAnalysisBundle) throws -> Data {
    guard let artifact = (bundle.manifest.artifacts + [bundle.manifest.provenance]).first(where: { $0.relativePath == path }) else {
      throw PrimerAnalysisBundleError.missingArtifact(path)
    }
    let bytes = try Data(contentsOf: bundle.artifactURL(forRelativePath: path))
    guard UInt64(bytes.count) == artifact.byteSize,
      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == artifact.sha256.lowercased() else {
      throw PrimerAnalysisBundleError.integrityMismatch(path)
    }
    return bytes
  }

  private static func referenceSequence(_ data: Data, id: String) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else { throw PrimerAnalysisSelectionExportError.unavailable("The saved reference is not readable FASTA.") }
    var current: String?, found: String?
    for line in text.split(whereSeparator: \.isNewline) {
      if line.hasPrefix(">") {
        current = line.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
        if current == id {
          guard found == nil else { throw PrimerAnalysisSelectionExportError.unavailable("The saved reference identifier is ambiguous.") }
          found = ""
        }
      } else if current == id { found? += line.filter { !$0.isWhitespace } }
    }
    guard let found, !found.isEmpty else { throw PrimerAnalysisSelectionExportError.unavailable("The selected mapping reference is missing.") }
    return found
  }

  private static func regularFiles(_ root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
      throw PrimerAnalysisSelectionExportError.unavailable("The staged reference could not be inventoried.")
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url) }
    }
    return files.sorted { $0.path < $1.path }
  }

  private static func requireAbsent(_ url: URL) throws {
    var info = stat()
    let status = url.path.withCString { lstat($0, &info) }
    guard status != 0, errno == ENOENT else {
      throw PrimerAnalysisSelectionExportError.unavailable("An output already exists at this destination.")
    }
  }
  private static func safeHeader(_ text: String) -> String {
    String(text.unicodeScalars.map { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) ? "_" : Character($0) })
  }
  private static func safeToken(_ text: String) -> String {
    let safe = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) ? Character($0) : "_" }
    return String(safe.prefix(80)).isEmpty ? "selection" : String(safe.prefix(80))
  }
  private static func safeQualifier(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-.:"))) ?? ""
  }
}
