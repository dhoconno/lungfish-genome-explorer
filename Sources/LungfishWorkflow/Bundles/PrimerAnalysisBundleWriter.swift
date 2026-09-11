import CryptoKit
import Darwin
import Foundation
import LungfishIO

public struct PrimerAnalysisSourceArtifact: Sendable {
  public let sourceURL: URL
  public let relativePath: String
  public let role: String
  public let format: String

  public init(sourceURL: URL, relativePath: String, role: String, format: String) {
    self.sourceURL = sourceURL
    self.relativePath = relativePath
    self.role = role
    self.format = format
  }
}

public struct PrimerAnalysisWrapperInvocation: Sendable {
  public let argv: [String]
  public let callerVersion: String
  public let explicitOptions: [String: ParameterValue]
  public let runtimeIdentity: ProvenanceRuntimeIdentity

  public init(
    argv: [String], callerVersion: String, explicitOptions: [String: ParameterValue],
    runtimeIdentity: ProvenanceRuntimeIdentity
  ) {
    self.argv = argv
    self.callerVersion = callerVersion
    self.explicitOptions = explicitOptions
    self.runtimeIdentity = runtimeIdentity
  }
}

public struct PrimerAnalysisBundleWriteRequest: Sendable {
  public let analysisID: UUID
  public let runID: UUID
  public let grouping: PrimerAnalysisGrouping
  public let inputs: [PrimerAnalysisInput]
  public let results: [PrimerAnalysisResult]
  public let artifacts: [PrimerAnalysisSourceArtifact]
  public let destinationURL: URL
  public let invocation: PrimerAnalysisWrapperInvocation

  public init(
    analysisID: UUID, runID: UUID, grouping: PrimerAnalysisGrouping, inputs: [PrimerAnalysisInput],
    results: [PrimerAnalysisResult], artifacts: [PrimerAnalysisSourceArtifact], destinationURL: URL,
    invocation: PrimerAnalysisWrapperInvocation
  ) {
    self.analysisID = analysisID
    self.runID = runID
    self.grouping = grouping
    self.inputs = inputs
    self.results = results
    self.artifacts = artifacts
    self.destinationURL = destinationURL
    self.invocation = invocation
  }
}

public enum PrimerAnalysisBundleWriterError: Error, LocalizedError, Sendable, Equatable {
  case invalidRequest(String)
  case unsafeSource(String)
  case destinationExists(String)
  case publicationFailed(String, Int32)

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let reason): return "Invalid primer analysis write request: \(reason)"
    case .unsafeSource(let path):
      return "Primer analysis source is not a safely traversed regular file: \(path)"
    case .destinationExists(let path): return "Primer analysis destination already exists: \(path)"
    case .publicationFailed(let path, let code):
      return
        "Could not publish primer analysis at \(path): \(POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription)"
    }
  }
}

public struct PrimerAnalysisBundleWriter: Sendable {
  private let provenanceWriter: ProvenanceWriter

  public init(provenanceWriter: ProvenanceWriter = ProvenanceWriter()) {
    self.provenanceWriter = provenanceWriter
  }

  public func write(_ request: PrimerAnalysisBundleWriteRequest) throws -> PrimerAnalysisBundle {
    try validate(request)
    let startedAt = Date()
    let parent = request.destinationURL.deletingLastPathComponent()
    guard request.destinationURL.isFileURL, request.destinationURL.path.hasPrefix("/"),
      !request.destinationURL.pathComponents.contains("..")
    else { throw PrimerAnalysisBundleWriterError.invalidRequest("destination path is unsafe") }
    let parentDescriptor = try openSafeExistingDirectory(parent)
    defer { close(parentDescriptor) }
    var existing = stat()
    guard lstat(request.destinationURL.path, &existing) != 0, errno == ENOENT else {
      throw PrimerAnalysisBundleWriterError.destinationExists(request.destinationURL.path)
    }
    let stagingName = ".\(request.destinationURL.lastPathComponent).staging-\(UUID().uuidString)"
    let staging = parent.appendingPathComponent(stagingName, isDirectory: true)
    guard mkdirat(parentDescriptor, stagingName, S_IRWXU) == 0 else {
      throw PrimerAnalysisBundleWriterError.publicationFailed(staging.path, errno)
    }
    let stagingIdentity = try directoryIdentity(
      parentDescriptor: parentDescriptor, name: stagingName)

    do {
      var inventory: [PrimerAnalysisArtifact] = []
      var inputs: [ProvenanceFileDescriptor] = []
      var outputs: [ProvenanceFileDescriptor] = []
      for artifact in request.artifacts {
        let copied = try copyVerifiedRegularFile(artifact, to: staging)
        inventory.append(
          PrimerAnalysisArtifact(
            relativePath: artifact.relativePath, role: artifact.role, format: artifact.format,
            sha256: copied.sha256, byteSize: copied.size))
        inputs.append(
          ProvenanceFileDescriptor(
            path: artifact.sourceURL.path, checksumSHA256: copied.sha256, fileSize: copied.size,
            format: fileFormat(artifact.format), role: .input))
        outputs.append(
          ProvenanceFileDescriptor(
            path: request.destinationURL.appendingPathComponent(artifact.relativePath).path,
            checksumSHA256: copied.sha256, fileSize: copied.size,
            format: fileFormat(artifact.format), role: .output, originPath: copied.stagedURL.path))
      }

      var builder = ProvenanceRunBuilder(
        workflowName: "lungfish.primer-analysis.wrap", workflowVersion: "1",
        toolName: "Lungfish Primer Analysis Storage", toolVersion: request.invocation.callerVersion
      )
      .argv(request.invocation.argv)
      .options(
        explicit: request.invocation.explicitOptions,
        defaults: ["manifestSchemaVersion": .integer(PrimerAnalysisManifest.currentSchemaVersion)],
        resolved: [
          "manifestSchemaVersion": .integer(PrimerAnalysisManifest.currentSchemaVersion),
          "publication": .string("exclusive-atomic"),
          "payloadHandling": .string("opaque-byte-preserving"),
          "analysisID": .string(request.analysisID.uuidString),
          "runID": .string(request.runID.uuidString),
          "grouping": .string(request.grouping.rawValue),
        ]
      )
      .runtime(request.invocation.runtimeIdentity)
      for descriptor in inputs { builder = try builder.consumedInputSnapshot(descriptor) }
      for descriptor in outputs { builder = try builder.relocatedOutput(descriptor) }
      let envelope = try builder.complete(exitStatus: 0, startedAt: startedAt, endedAt: Date())
      let provenanceDirectory = staging.appendingPathComponent("provenance", isDirectory: true)
      let provenanceURL = provenanceDirectory.appendingPathComponent("wrapper.json")
      _ = try provenanceWriter.write(envelope, toSidecar: provenanceURL)
      try requireDirectoryIdentity(at: staging, expected: stagingIdentity)
      let provenanceInventory = try inventoryProvenanceDirectory(provenanceDirectory, root: staging)
      guard
        let mainProvenance = provenanceInventory.first(where: {
          $0.relativePath == "provenance/wrapper.json"
        })
      else {
        throw PrimerAnalysisBundleWriterError.invalidRequest(
          "provenance writer did not create the canonical envelope")
      }
      inventory.append(
        contentsOf: provenanceInventory.filter { $0.relativePath != mainProvenance.relativePath })

      let manifest = PrimerAnalysisManifest(
        analysisID: request.analysisID, runID: request.runID, inputs: request.inputs,
        results: request.results, artifacts: inventory, provenance: mainProvenance,
        grouping: request.grouping, publishedRootPath: request.destinationURL.path)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(manifest).write(
        to: staging.appendingPathComponent(PrimerAnalysisManifest.filename), options: .atomic)
      _ = try PrimerAnalysisBundle.load(from: staging)
      try requireDirectoryIdentity(at: staging, expected: stagingIdentity)
      let status = stagingName.withCString { sourceName in
        request.destinationURL.lastPathComponent.withCString { destinationName in
          renameatx_np(
            parentDescriptor, sourceName, parentDescriptor, destinationName, UInt32(RENAME_EXCL))
        }
      }
      guard status == 0 else {
        throw PrimerAnalysisBundleWriterError.publicationFailed(request.destinationURL.path, errno)
      }
      return try PrimerAnalysisBundle.load(from: request.destinationURL)
    } catch {
      let original = error
      do {
        try removeOwnedStaging(
          staging, parentDescriptor: parentDescriptor, name: stagingName, expected: stagingIdentity)
      } catch {
        throw PrimerAnalysisBundleWriterError.invalidRequest(
          "publication failed (\(original.localizedDescription)); owned staging cleanup failed or was preserved safely (\(error.localizedDescription))"
        )
      }
      throw original
    }
  }

  private func validate(_ request: PrimerAnalysisBundleWriteRequest) throws {
    guard !request.invocation.argv.isEmpty,
      request.invocation.argv.allSatisfy({ !$0.contains("\0") }),
      !request.invocation.callerVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw PrimerAnalysisBundleWriterError.invalidRequest(
        "exact caller argv and version are required")
    }
    guard !request.inputs.isEmpty, !request.artifacts.isEmpty else {
      throw PrimerAnalysisBundleWriterError.invalidRequest(
        "input metadata and artifacts are required")
    }
    guard request.destinationURL.pathExtension == "lungfishprimeranalysis" else {
      throw PrimerAnalysisBundleWriterError.invalidRequest(
        "destination must use .lungfishprimeranalysis")
    }
    let paths = request.artifacts.map(\.relativePath)
    guard Set(paths).count == paths.count else {
      throw PrimerAnalysisBundleWriterError.invalidRequest("duplicate artifact path")
    }
    for path in paths {
      let parts = path.split(separator: "/", omittingEmptySubsequences: false)
      guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
        path != PrimerAnalysisManifest.filename,
        parts.first != "provenance", parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
      else {
        throw PrimerAnalysisBundleWriterError.invalidRequest(
          "unsafe or reserved artifact path \(path)")
      }
    }
    guard request.artifacts.contains(where: { $0.role == "nativeOutput" }),
      request.artifacts.allSatisfy({ $0.role != "provenance" && $0.role != "provenance-support" })
    else {
      throw PrimerAnalysisBundleWriterError.invalidRequest(
        "nativeOutput is required and provenance roles are reserved")
    }
    let artifactByPath = Dictionary(
      uniqueKeysWithValues: request.artifacts.map { ($0.relativePath, $0) })
    let artifactPaths = Set(paths)
    let inputIDs = request.inputs.map(\.id)
    guard Set(inputIDs).count == inputIDs.count,
      request.inputs.allSatisfy({
        !$0.artifactPaths.isEmpty && $0.artifactPaths.allSatisfy(artifactPaths.contains)
          && $0.artifactPaths.contains(where: { artifactByPath[$0]?.role == "input" })
      })
    else { throw PrimerAnalysisBundleWriterError.invalidRequest("invalid input references") }
    let resultIDs = request.results.map(\.id)
    let knownInputs = Set(inputIDs)
    guard Set(resultIDs).count == resultIDs.count,
      request.results.allSatisfy({
        !$0.inputIDs.isEmpty && $0.inputIDs.allSatisfy(knownInputs.contains)
          && !$0.artifactPaths.isEmpty && $0.artifactPaths.allSatisfy(artifactPaths.contains)
      })
    else { throw PrimerAnalysisBundleWriterError.invalidRequest("invalid result references") }
  }

  private func copyVerifiedRegularFile(_ artifact: PrimerAnalysisSourceArtifact, to root: URL)
    throws -> (stagedURL: URL, sha256: String, size: UInt64)
  {
    guard artifact.sourceURL.isFileURL, artifact.sourceURL.path.hasPrefix("/"),
      !artifact.sourceURL.pathComponents.contains("..")
    else { throw PrimerAnalysisBundleWriterError.unsafeSource(artifact.sourceURL.path) }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else {
      throw PrimerAnalysisBundleWriterError.unsafeSource(artifact.sourceURL.path)
    }
    let components = artifact.sourceURL.path.split(separator: "/").map(String.init)
    for component in components.dropLast() {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(descriptor)
      guard next >= 0 else {
        throw PrimerAnalysisBundleWriterError.unsafeSource(artifact.sourceURL.path)
      }
      descriptor = next
    }
    guard let fileName = components.last else {
      close(descriptor)
      throw PrimerAnalysisBundleWriterError.unsafeSource(artifact.sourceURL.path)
    }
    let sourceDescriptor = openat(descriptor, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    close(descriptor)
    guard sourceDescriptor >= 0 else {
      throw PrimerAnalysisBundleWriterError.unsafeSource(artifact.sourceURL.path)
    }
    var info = stat()
    guard fstat(sourceDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      close(sourceDescriptor)
      throw PrimerAnalysisBundleWriterError.unsafeSource(artifact.sourceURL.path)
    }
    let source = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
    defer { try? source.close() }
    let destination = root.appendingPathComponent(artifact.relativePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destinationDescriptor = open(
      destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard destinationDescriptor >= 0 else {
      throw PrimerAnalysisBundleWriterError.invalidRequest(
        "could not exclusively create staged artifact")
    }
    let output = FileHandle(fileDescriptor: destinationDescriptor, closeOnDealloc: true)
    defer { try? output.close() }
    var hasher = SHA256()
    var size: UInt64 = 0
    while true {
      let data = try source.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
      try output.write(contentsOf: data)
      size += UInt64(data.count)
    }
    try output.synchronize()
    return (destination, hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
  }

  private func inventoryProvenanceDirectory(_ directory: URL, root: URL) throws
    -> [PrimerAnalysisArtifact]
  {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try names.sorted().map { name in
      let path = "provenance/\(name)"
      let url = root.appendingPathComponent(path)
      let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else {
        throw PrimerAnalysisBundleWriterError.invalidRequest(
          "provenance support is not a regular file")
      }
      var info = stat()
      guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
        close(descriptor)
        throw PrimerAnalysisBundleWriterError.invalidRequest(
          "provenance support is not a regular file")
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      var hasher = SHA256()
      var size: UInt64 = 0
      while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
        size += UInt64(data.count)
      }
      return PrimerAnalysisArtifact(
        relativePath: path, role: name == "wrapper.json" ? "provenance" : "provenance-support",
        format: "json", sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        byteSize: size)
    }
  }

  private func fileFormat(_ format: String) -> FileFormat {
    FileFormat(rawValue: format) ?? .unknown
  }

  private func openSafeExistingDirectory(_ url: URL) throws -> Int32 {
    var descriptor = open("/", O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else {
      throw PrimerAnalysisBundleWriterError.invalidRequest("destination parent cannot be opened")
    }
    for component in url.path.split(separator: "/").map(String.init) {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(descriptor)
      guard next >= 0 else {
        throw PrimerAnalysisBundleWriterError.invalidRequest(
          "destination parent traversal is unsafe")
      }
      descriptor = next
    }
    return descriptor
  }

  private typealias DirectoryIdentity = (device: UInt64, inode: UInt64)

  private func directoryIdentity(parentDescriptor: Int32, name: String) throws -> DirectoryIdentity
  {
    var info = stat()
    guard fstatat(parentDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
      (info.st_mode & S_IFMT) == S_IFDIR
    else {
      throw PrimerAnalysisBundleWriterError.invalidRequest(
        "staging directory identity is unavailable")
    }
    return (UInt64(info.st_dev), UInt64(info.st_ino))
  }

  private func requireDirectoryIdentity(at url: URL, expected: DirectoryIdentity) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      UInt64(info.st_dev) == expected.device, UInt64(info.st_ino) == expected.inode
    else {
      throw PrimerAnalysisBundleWriterError.invalidRequest("owned staging path identity changed")
    }
  }

  private func removeOwnedStaging(
    _ url: URL, parentDescriptor: Int32, name: String, expected: DirectoryIdentity
  ) throws {
    var info = stat()
    guard fstatat(parentDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw PrimerAnalysisBundleWriterError.publicationFailed(url.path, errno)
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR, UInt64(info.st_dev) == expected.device,
      UInt64(info.st_ino) == expected.inode
    else {
      throw PrimerAnalysisBundleWriterError.invalidRequest("staging replacement was preserved")
    }
    try requireDirectoryIdentity(at: url, expected: expected)
    do { try FileManager.default.removeItem(at: url) } catch {
      throw PrimerAnalysisBundleWriterError.invalidRequest(
        "could not remove owned staging: \(error.localizedDescription)")
    }
  }
}
