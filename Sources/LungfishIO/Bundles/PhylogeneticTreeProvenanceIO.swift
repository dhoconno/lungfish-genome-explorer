import CryptoKit
import Foundation
import SQLite3

func derivedTreeProvenance(
    workflowName: String,
    actionID: String,
    provenance: PhylogeneticTreeBundleTransformProvenance,
    sourceBundleURL: URL,
    outputBundleURL: URL,
    payloadPaths: [String],
    warnings: [String],
    wallTimeSeconds: TimeInterval,
    metadataURL: URL?
) throws -> [String: Any] {
    let command = provenance.command ?? treeShellCommand(provenance.argv)
    var object: [String: Any] = [
        "schemaVersion": 1,
        "workflowName": workflowName,
        "actionID": actionID,
        "toolName": provenance.toolName,
        "toolVersion": provenance.toolVersion,
        "argv": provenance.argv,
        "command": command,
        "reproducibleCommand": command,
        "options": provenance.options,
        "runtime": treeRuntimeIdentityDictionary(),
        "runtimeIdentity": treeRuntimeIdentityDictionary(),
        "input": try treeFileRecord(path: sourceBundleURL.path, url: sourceBundleURL),
        "inputBundle": try treeFileRecord(path: sourceBundleURL.path, url: sourceBundleURL),
        "inputTreeFile": try treeFileRecord(
            path: sourceBundleURL.appendingPathComponent("tree/primary.nwk").path,
            url: sourceBundleURL.appendingPathComponent("tree/primary.nwk")
        ),
        "output": try treeFileRecord(path: outputBundleURL.path, url: outputBundleURL),
        "outputBundle": try treeFileRecord(path: outputBundleURL.path, url: outputBundleURL),
        "checksums": try treeChecksumMap(paths: payloadPaths, bundleURL: outputBundleURL),
        "fileSizes": try treeFileSizeMap(paths: payloadPaths, bundleURL: outputBundleURL),
        "exitStatus": 0,
        "wallTimeSeconds": wallTimeSeconds,
        "warnings": warnings,
        "stderr": provenance.stderr as Any,
        "createdAt": ISO8601DateFormatter().string(from: Date()),
    ]
    if let metadataURL {
        object["metadataFile"] = try treeFileRecord(path: metadataURL.path, url: metadataURL)
    }
    return object
}

func writeTreeJSONObject(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

private func treeRuntimeIdentityDictionary() -> [String: Any] {
    [
        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        "swiftRuntime": "swift",
        "condaEnvironment": ProcessInfo.processInfo.environment["CONDA_DEFAULT_ENV"] as Any,
        "containerImage": NSNull(),
    ]
}

private func treeFileRecord(path: String, url: URL) throws -> [String: Any] {
    [
        "path": path,
        "sha256": try treeDigest(url: url),
        "fileSizeBytes": try treeFileSize(at: url),
    ]
}

func treeChecksumMap(paths: [String], bundleURL: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for path in paths {
        result[path] = try treeDigest(url: bundleURL.appendingPathComponent(path))
    }
    return result
}

func treeFileSizeMap(paths: [String], bundleURL: URL) throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    for path in paths {
        result[path] = try treeFileSize(at: bundleURL.appendingPathComponent(path))
    }
    return result
}

private func treeDigest(url: URL) throws -> String {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        let checksums = try treeDirectoryChecksums(url: url)
        let joined = checksums.keys.sorted().map { "\($0)=\(checksums[$0] ?? "")" }.joined(separator: "\n")
        return PhylogeneticTreeBundleImporter.sha256Hex(for: Data(joined.utf8))
    }
    return PhylogeneticTreeBundleImporter.sha256Hex(for: try Data(contentsOf: url))
}

private func treeDirectoryChecksums(url: URL) throws -> [String: String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return [:]
    }
    var result: [String: String] = [:]
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let relative = String(fileURL.path.dropFirst(url.path.count + 1))
        result[relative] = PhylogeneticTreeBundleImporter.sha256Hex(for: try Data(contentsOf: fileURL))
    }
    return result
}

private func treeFileSize(at url: URL) throws -> Int64 {
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        return try treeDirectorySize(at: url)
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.size] as? NSNumber)?.int64Value ?? 0
}

private func treeDirectorySize(at url: URL) throws -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
        return 0
    }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            total += Int64(values.fileSize ?? 0)
        }
    }
    return total
}

private func treeShellCommand(_ argv: [String]) -> String {
    argv.map(treeShellEscaped).joined(separator: " ")
}

private func treeShellEscaped(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=/:.,")
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
