import CryptoKit
import Darwin
import Foundation

public enum PrimerAnalysisBundleError: Error, LocalizedError, Sendable, Equatable {
  case invalidManifest(String)
  case unsafePath(String)
  case missingArtifact(String)
  case invalidArtifact(String)
  case integrityMismatch(String)
  case invalidProvenance(String)

  public var errorDescription: String? {
    switch self {
    case .invalidManifest(let reason): return "Invalid primer analysis manifest: \(reason)"
    case .unsafePath(let path): return "Unsafe primer analysis path: \(path)"
    case .missingArtifact(let path): return "Missing primer analysis artifact: \(path)"
    case .invalidArtifact(let path):
      return "Primer analysis artifact is not a regular file: \(path)"
    case .integrityMismatch(let path): return "Primer analysis artifact integrity mismatch: \(path)"
    case .invalidProvenance(let reason): return "Invalid primer analysis provenance: \(reason)"
    }
  }
}

public struct PrimerAnalysisBundle: Sendable {
  public let manifest: PrimerAnalysisManifest
  public let url: URL
  public let canonicalProvenanceData: Data

  public static func load(
    from suppliedURL: URL,
    cancellationCheck: () throws -> Void = {}
  ) throws -> Self {
    try cancellationCheck()
    guard suppliedURL.isFileURL, suppliedURL.path.hasPrefix("/"),
      !suppliedURL.pathComponents.contains("..")
    else { throw PrimerAnalysisBundleError.unsafePath(suppliedURL.path) }
    let root = suppliedURL
    let manifestData = try readData(
      root: root, relativePath: PrimerAnalysisManifest.filename,
      cancellationCheck: cancellationCheck)
    let manifest: PrimerAnalysisManifest
    do {
      manifest = try JSONDecoder().decode(PrimerAnalysisManifest.self, from: manifestData)
    } catch { throw PrimerAnalysisBundleError.invalidManifest(error.localizedDescription) }
    try validateManifest(manifest)
    var provenanceData: Data?
    for artifact in manifest.artifacts + [manifest.provenance] {
      try cancellationCheck()
      let actual: (digest: String, size: UInt64)
      if artifact.relativePath == manifest.provenance.relativePath {
        let bytes = try readData(
          root: root, relativePath: artifact.relativePath,
          cancellationCheck: cancellationCheck)
        provenanceData = bytes
        actual = digestAndSize(bytes)
      } else {
        actual = try digestAndSize(
          root: root, relativePath: artifact.relativePath,
          cancellationCheck: cancellationCheck)
      }
      guard actual.digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame,
        actual.size == artifact.byteSize
      else {
        throw PrimerAnalysisBundleError.integrityMismatch(artifact.relativePath)
      }
    }
    let canonicalProvenanceData = provenanceData ?? Data()
    try validateCanonicalProvenance(data: canonicalProvenanceData, manifest: manifest)
    return Self(
      manifest: manifest, url: root, canonicalProvenanceData: canonicalProvenanceData)
  }

  public func artifactURL(forRelativePath relativePath: String) throws -> URL {
    guard
      (manifest.artifacts + [manifest.provenance]).contains(where: {
        $0.relativePath == relativePath
      })
    else {
      throw PrimerAnalysisBundleError.missingArtifact(relativePath)
    }
    return try Self.validatedRegularFileURL(root: url, relativePath: relativePath)
  }

  private static func validateManifest(_ manifest: PrimerAnalysisManifest) throws {
    guard manifest.schemaVersion == PrimerAnalysisManifest.currentSchemaVersion else {
      throw PrimerAnalysisBundleError.invalidManifest("unsupported schema version")
    }
    let all = manifest.artifacts + [manifest.provenance]
    guard !manifest.inputs.isEmpty, !manifest.artifacts.isEmpty else {
      throw PrimerAnalysisBundleError.invalidManifest(
        "input metadata and payload inventory are required")
    }
    guard manifest.publishedRootPath.hasPrefix("/"), !manifest.publishedRootPath.contains("\0"),
      !manifest.publishedRootPath.split(separator: "/").contains("..")
    else { throw PrimerAnalysisBundleError.invalidManifest("published root path is invalid") }
    guard manifest.provenance.role == "provenance", manifest.provenance.format == "json",
      manifest.provenance.byteSize > 0
    else {
      throw PrimerAnalysisBundleError.invalidManifest("mandatory provenance descriptor is invalid")
    }
    var paths = Set<String>()
    for artifact in all {
      try validateRelativePath(artifact.relativePath)
      guard artifact.relativePath != PrimerAnalysisManifest.filename else {
        throw PrimerAnalysisBundleError.invalidManifest("manifest cannot inventory itself")
      }
      guard paths.insert(artifact.relativePath).inserted else {
        throw PrimerAnalysisBundleError.invalidManifest(
          "duplicate artifact path \(artifact.relativePath)")
      }
      guard !artifact.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !artifact.format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        artifact.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
      else {
        throw PrimerAnalysisBundleError.invalidManifest(
          "invalid artifact descriptor \(artifact.relativePath)")
      }
    }
    let artifactPaths = Set(manifest.artifacts.map(\.relativePath))
    let artifactByPath = Dictionary(
      uniqueKeysWithValues: manifest.artifacts.map { ($0.relativePath, $0) })
    guard manifest.artifacts.contains(where: { $0.role == "nativeOutput" }) else {
      throw PrimerAnalysisBundleError.invalidManifest(
        "at least one nativeOutput artifact is required")
    }
    let inputIDs = manifest.inputs.map(\.id)
    let resultIDs = manifest.results.map(\.id)
    guard Set(inputIDs).count == inputIDs.count else {
      throw PrimerAnalysisBundleError.invalidManifest("duplicate input ID")
    }
    guard Set(resultIDs).count == resultIDs.count else {
      throw PrimerAnalysisBundleError.invalidManifest("duplicate result ID")
    }
    let knownInputs = Set(inputIDs)
    for input in manifest.inputs {
      guard !input.artifactPaths.isEmpty,
        Set(input.artifactPaths).count == input.artifactPaths.count,
        input.artifactPaths.allSatisfy(artifactPaths.contains),
        input.artifactPaths.contains(where: { artifactByPath[$0]?.role == "input" })
      else {
        throw PrimerAnalysisBundleError.invalidManifest(
          "input lacks an input snapshot or references an absent artifact")
      }
    }
    for result in manifest.results {
      guard !result.inputIDs.isEmpty, Set(result.inputIDs).count == result.inputIDs.count,
        result.inputIDs.allSatisfy(knownInputs.contains), !result.artifactPaths.isEmpty,
        Set(result.artifactPaths).count == result.artifactPaths.count,
        result.artifactPaths.allSatisfy(artifactPaths.contains)
      else { throw PrimerAnalysisBundleError.invalidManifest("result reference is invalid") }
    }
  }

  private static func validateRelativePath(_ path: String) throws {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw PrimerAnalysisBundleError.unsafePath(path) }
  }

  static func validatedRegularFileURL(root: URL, relativePath: String) throws -> URL {
    let handle = try openRegularFile(root: root, relativePath: relativePath)
    try? handle.close()
    return root.appendingPathComponent(relativePath)
  }

  private static func openAbsoluteDirectory(_ url: URL) throws -> Int32 {
    guard url.path.hasPrefix("/") else { throw PrimerAnalysisBundleError.unsafePath(url.path) }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else { throw PrimerAnalysisBundleError.invalidArtifact(url.path) }
    for component in url.path.split(separator: "/").map(String.init) {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(descriptor)
      guard next >= 0 else { throw PrimerAnalysisBundleError.unsafePath(url.path) }
      descriptor = next
    }
    return descriptor
  }

  static func digestAndSize(
    root: URL, relativePath: String, cancellationCheck: () throws -> Void = {}
  ) throws -> (
    digest: String, size: UInt64
  ) {
    let handle = try openRegularFile(root: root, relativePath: relativePath)
    defer { try? handle.close() }
    var hasher = SHA256()
    var size: UInt64 = 0
    while true {
      try cancellationCheck()
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
      size += UInt64(data.count)
    }
    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
  }

  private static func digestAndSize(_ data: Data) -> (digest: String, size: UInt64) {
    (SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), UInt64(data.count))
  }

  // LungfishIO intentionally validates only the stable canonical JSON contract,
  // avoiding a dependency on LungfishWorkflow's provenance model.
  private static func validateCanonicalProvenance(data: Data, manifest: PrimerAnalysisManifest)
    throws
  {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let workflow = object["workflowName"] as? String, !workflow.isEmpty,
      let workflowVersion = object["workflowVersion"] as? String, !workflowVersion.isEmpty,
      let tool = object["tool"] as? [String: Any], !(tool["name"] as? String ?? "").isEmpty,
      !(tool["version"] as? String ?? "").isEmpty,
      let argv = object["argv"] as? [String], !argv.isEmpty,
      let command = object["reproducibleCommand"] as? String, !command.isEmpty,
      let options = object["options"] as? [String: Any], options["explicit"] is [String: Any],
      options["defaults"] is [String: Any], options["resolvedDefaults"] is [String: Any],
      let runtime = object["runtimeIdentity"] as? [String: Any],
      !(runtime["appVersion"] as? String ?? "").isEmpty,
      !(runtime["executablePath"] as? String ?? "").isEmpty,
      !(runtime["operatingSystemVersion"] as? String ?? "").isEmpty,
      !(runtime["architecture"] as? String ?? "").isEmpty,
      let outputs = object["outputs"] as? [[String: Any]], !outputs.isEmpty,
      let files = object["files"] as? [[String: Any]],
      (object["exitStatus"] as? NSNumber)?.intValue == 0,
      let wall = object["wallTimeSeconds"] as? NSNumber, wall.doubleValue >= 0
    else { throw PrimerAnalysisBundleError.invalidProvenance("canonical fields are missing") }
    guard let resolved = options["resolvedDefaults"] as? [String: Any] else {
      throw PrimerAnalysisBundleError.invalidProvenance("resolved options are missing")
    }
    let boundAnalysisID = canonicalStringOption(resolved["analysisID"])
    let boundRunID = canonicalStringOption(resolved["runID"])
    let boundGrouping = canonicalStringOption(resolved["grouping"])
    guard boundAnalysisID == manifest.analysisID.uuidString,
      boundRunID == manifest.runID.uuidString,
      boundGrouping == manifest.grouping.rawValue
    else {
      throw PrimerAnalysisBundleError.invalidProvenance(
        "manifest identities are not bound to resolved options")
    }
    let signatureSupportPaths = try signatureSupportPaths(from: object)
    for artifact in manifest.artifacts where !signatureSupportPaths.contains(artifact.relativePath)
    {
      guard artifact.role != "provenance-support" else {
        throw PrimerAnalysisBundleError.invalidProvenance(
          "unreferenced provenance support artifact")
      }
      guard
        outputs.contains(where: { output in
          guard let path = output["path"] as? String,
            let digest = (output["checksumSHA256"] ?? output["sha256"]) as? String,
            let size = (output["fileSize"] ?? output["sizeBytes"]) as? NSNumber
          else { return false }
          return path
            == URL(fileURLWithPath: manifest.publishedRootPath).appendingPathComponent(
              artifact.relativePath
            ).path && digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame
            && size.uint64Value == artifact.byteSize
        })
      else {
        throw PrimerAnalysisBundleError.invalidProvenance(
          "output inventory does not match \(artifact.relativePath)")
      }
    }
    let inventoriedSupport = Set(
      manifest.artifacts.filter { $0.role == "provenance-support" }.map(\.relativePath))
    guard inventoriedSupport == signatureSupportPaths else {
      throw PrimerAnalysisBundleError.invalidProvenance(
        "signature support inventory does not match canonical references")
    }
    for input in manifest.inputs {
      for path in input.artifactPaths {
        guard let artifact = manifest.artifacts.first(where: { $0.relativePath == path }),
          files.contains(where: { descriptor in
            guard (descriptor["role"] as? String) == "input",
              let sourcePath = descriptor["path"] as? String, sourcePath.hasPrefix("/"),
              let digest = (descriptor["checksumSHA256"] ?? descriptor["sha256"]) as? String,
              let size = (descriptor["fileSize"] ?? descriptor["sizeBytes"]) as? NSNumber
            else { return false }
            return digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame
              && size.uint64Value == artifact.byteSize
          })
        else {
          throw PrimerAnalysisBundleError.invalidProvenance(
            "consumed input snapshot does not match \(path)")
        }
      }
    }
  }

  private static func canonicalStringOption(_ value: Any?) -> String? {
    guard let dictionary = value as? [String: Any], dictionary.count == 2,
      dictionary["type"] as? String == "string",
      let string = dictionary["value"] as? String
    else { return nil }
    return string
  }

  private static func signatureSupportPaths(from object: [String: Any]) throws -> Set<String> {
    let signatures = object["signatures"] as? [[String: Any]] ?? []
    var result = Set<String>()
    for signature in signatures {
      for key in ["signaturePath", "publicKeyPath"] {
        guard let stored = signature[key] as? String else { continue }
        let parts = stored.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1, !stored.isEmpty, stored != ".", stored != "..",
          !stored.contains("\\"), !stored.contains("\0")
        else { throw PrimerAnalysisBundleError.invalidProvenance("unsafe signature support path") }
        result.insert("provenance/\(stored)")
      }
    }
    return result
  }

  private static func readData(
    root: URL, relativePath: String, cancellationCheck: () throws -> Void = {}
  ) throws -> Data {
    let handle = try openRegularFile(root: root, relativePath: relativePath)
    defer { try? handle.close() }
    var result = Data()
    while true {
      try cancellationCheck()
      let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
      if chunk.isEmpty { return result }
      result.append(chunk)
    }
  }

  private static func openRegularFile(root: URL, relativePath: String) throws -> FileHandle {
    try validateRelativePath(relativePath)
    var descriptor = try openAbsoluteDirectory(root)
    let parts = relativePath.split(separator: "/").map(String.init)
    for component in parts.dropLast() {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      close(descriptor)
      guard next >= 0 else { throw PrimerAnalysisBundleError.unsafePath(relativePath) }
      descriptor = next
    }
    let fileDescriptor = openat(descriptor, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    close(descriptor)
    guard fileDescriptor >= 0 else { throw PrimerAnalysisBundleError.missingArtifact(relativePath) }
    var info = stat()
    guard fstat(fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      close(fileDescriptor)
      throw PrimerAnalysisBundleError.invalidArtifact(relativePath)
    }
    return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
  }
}
