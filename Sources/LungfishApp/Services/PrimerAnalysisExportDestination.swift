import Darwin
import Foundation
import LungfishIO

/// Keeps contextual scientific exports inside the captured project's own Analyses directory.
struct PrimerAnalysisExportDestination: Sendable {
  let url: URL
  private let projectURL: URL
  private let parentURL: URL
  private let projectIdentity: DirectoryIdentity
  private let parentIdentity: DirectoryIdentity

  init(projectURL: URL, name: String) throws {
    guard projectURL.isFileURL, let physical = realpath(projectURL.path, nil) else {
      throw Self.invalid("The originating project is unavailable.")
    }
    let project = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    free(physical)
    self.projectURL = project
    projectIdentity = try DirectoryIdentity(project)
    parentURL = project.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
    if !FileManager.default.fileExists(atPath: parentURL.path),
      (try? FileManager.default.destinationOfSymbolicLink(atPath: parentURL.path)) == nil {
      try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
    }
    parentIdentity = try DirectoryIdentity(parentURL)
    let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
    let cleaned = String(name.unicodeScalars.map { permitted.contains($0) ? Character($0) : "-" })
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let stem = String((cleaned.isEmpty ? "Primer extract" : cleaned).prefix(50))
    url = parentURL.appendingPathComponent(stem + "-" + UUID().uuidString.prefix(8) + ".lungfishref", isDirectory: true)
    try validateBeforePublication()
  }

  func validateBeforePublication() throws {
    guard try DirectoryIdentity(projectURL) == projectIdentity,
      try DirectoryIdentity(parentURL) == parentIdentity else {
      throw Self.invalid("The originating project or Analyses folder changed during export.")
    }
    guard !FileManager.default.fileExists(atPath: url.path),
      (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
      throw Self.invalid("The export destination already exists.")
    }
  }

  private struct DirectoryIdentity: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    init(_ url: URL) throws {
      var info = stat()
      guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
        throw PrimerAnalysisExportDestination.invalid("Project export folders must be real directories, not symbolic links.")
      }
      device = info.st_dev
      inode = info.st_ino
    }
  }

  private static func invalid(_ message: String) -> NSError {
    NSError(domain: "PrimerAnalysisExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
