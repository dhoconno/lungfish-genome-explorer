import CryptoKit
import Foundation

public enum PrimerToolPortableLauncherError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedTool(String)
    case invalidEnvironment(String)
    case invalidEntrypoint(String)
    case invalidReceipt(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTool(let tool):
            return "Portable primer launcher is unsupported for '\(tool)'."
        case .invalidEnvironment(let reason):
            return "Portable primer launcher environment is invalid: \(reason)"
        case .invalidEntrypoint(let reason):
            return "Portable primer launcher entrypoint is invalid: \(reason)"
        case .invalidReceipt(let reason):
            return "Portable primer launcher receipt is invalid: \(reason)"
        }
    }
}

public enum PrimerToolPortableLauncher {
    public struct Artifact: Sendable, Codable, Hashable {
        public let relativePath: String
        public let sha256: String
        public let sizeBytes: UInt64
        public let posixPermissions: Int
    }

    private struct Receipt: Sendable, Codable, Hashable {
        static let schemaVersion = 1
        let schemaVersion: Int
        let toolID: String
        let launcherFormatVersion: Int
        let source: Artifact
        let launcher: Artifact
        let mafftBinariesRelativePath: String?
    }

    private struct Definition {
        let toolID: String
        let mafftBinariesRelativePath: String?

        var launcherRelativePath: String { "bin/\(toolID)" }
        var sourceRelativePath: String {
            "share/lungfish/managed-tools/primer-launchers/\(toolID)-upstream.py"
        }
        var receiptRelativePath: String {
            "share/lungfish/managed-tools/primer-launchers/\(toolID)-launcher.json"
        }
    }

    private static let definitions: [String: Definition] = [
        "olivar": Definition(toolID: "olivar", mafftBinariesRelativePath: "libexec/mafft"),
        "varvamp": Definition(toolID: "varvamp", mafftBinariesRelativePath: nil),
        "primalscheme3": Definition(toolID: "primalscheme3", mafftBinariesRelativePath: nil),
    ]

    public static func supports(toolID: String) -> Bool {
        definitions[toolID] != nil
    }

    public static func prepare(toolID: String, environmentURL: URL) throws {
        let definition = try definition(for: toolID)
        let root = environmentURL.standardizedFileURL
        let python = root.appendingPathComponent("bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw PrimerToolPortableLauncherError.invalidEnvironment("missing executable bin/python")
        }
        if let helper = definition.mafftBinariesRelativePath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent(helper).path, isDirectory: &isDirectory),
                isDirectory.boolValue else {
                throw PrimerToolPortableLauncherError.invalidEnvironment("missing \(helper)")
            }
        }

        if (try? validate(toolID: toolID, environmentURL: root)) != nil { return }

        let launcherURL = root.appendingPathComponent(definition.launcherRelativePath)
        let sourceURL = root.appendingPathComponent(definition.sourceRelativePath)
        let receiptURL = root.appendingPathComponent(definition.receiptRelativePath)
        let sourceData: Data
        let sourcePermissions: Int
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            sourceData = try regularFileData(at: sourceURL, root: root)
            sourcePermissions = try permissions(at: sourceURL)
        } else {
            sourceData = try regularFileData(at: launcherURL, root: root)
            sourcePermissions = try permissions(at: launcherURL)
        }
        guard !sourceData.starts(with: Data("#!/bin/sh\n# lungfish-primer-launcher-v1\n".utf8)) else {
            throw PrimerToolPortableLauncherError.invalidEntrypoint(
                "managed launcher exists without its preserved upstream entrypoint")
        }

        let launcherData = Data(launcherScript(for: definition).utf8)
        let managedDirectory = receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: sourceURL.path) {
            try sourceData.write(to: sourceURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: sourcePermissions], ofItemAtPath: sourceURL.path)
        }
        try launcherData.write(to: launcherURL, options: .atomic)
        let launcherPermissions = sourcePermissions | 0o100
        try FileManager.default.setAttributes(
            [.posixPermissions: launcherPermissions], ofItemAtPath: launcherURL.path)

        let receipt = Receipt(
            schemaVersion: Receipt.schemaVersion,
            toolID: toolID,
            launcherFormatVersion: 1,
            source: try artifact(
                relativePath: definition.sourceRelativePath, url: sourceURL, root: root),
            launcher: try artifact(
                relativePath: definition.launcherRelativePath, url: launcherURL, root: root),
            mafftBinariesRelativePath: definition.mafftBinariesRelativePath
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try validate(toolID: toolID, environmentURL: root)
    }

    public static func validate(toolID: String, environmentURL: URL) throws {
        let definition = try definition(for: toolID)
        let root = environmentURL.standardizedFileURL
        let receiptURL = root.appendingPathComponent(definition.receiptRelativePath)
        let receipt: Receipt
        do {
            receipt = try JSONDecoder().decode(Receipt.self, from: regularFileData(at: receiptURL, root: root))
        } catch let error as PrimerToolPortableLauncherError {
            throw error
        } catch {
            throw PrimerToolPortableLauncherError.invalidReceipt("missing or unreadable receipt")
        }
        guard receipt.schemaVersion == Receipt.schemaVersion,
              receipt.launcherFormatVersion == 1,
              receipt.toolID == toolID,
              receipt.source.relativePath == definition.sourceRelativePath,
              receipt.launcher.relativePath == definition.launcherRelativePath,
              receipt.mafftBinariesRelativePath == definition.mafftBinariesRelativePath else {
            throw PrimerToolPortableLauncherError.invalidReceipt("identity does not match \(toolID)")
        }
        guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/python").path) else {
            throw PrimerToolPortableLauncherError.invalidEnvironment("missing executable bin/python")
        }
        if let helper = definition.mafftBinariesRelativePath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent(helper).path, isDirectory: &isDirectory),
                isDirectory.boolValue else {
                throw PrimerToolPortableLauncherError.invalidEnvironment("missing \(helper)")
            }
        }
        try validate(receipt.source, root: root, requireExecutable: false)
        try validate(receipt.launcher, root: root, requireExecutable: true)
        let expectedLauncher = Data(launcherScript(for: definition).utf8)
        guard try regularFileData(
            at: root.appendingPathComponent(definition.launcherRelativePath), root: root) == expectedLauncher else {
            throw PrimerToolPortableLauncherError.invalidReceipt("launcher bytes do not match version 1")
        }
    }

    public static func artifacts(toolID: String, environmentURL: URL) throws -> [Artifact] {
        try validate(toolID: toolID, environmentURL: environmentURL)
        let definition = try definition(for: toolID)
        let root = environmentURL.standardizedFileURL
        let receiptURL = root.appendingPathComponent(definition.receiptRelativePath)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        return [
            try artifact(
                relativePath: receipt.source.relativePath,
                url: root.appendingPathComponent(receipt.source.relativePath),
                root: root),
            try artifact(
                relativePath: receipt.launcher.relativePath,
                url: root.appendingPathComponent(receipt.launcher.relativePath),
                root: root),
            try artifact(relativePath: definition.receiptRelativePath, url: receiptURL, root: root),
        ]
    }

    private static func definition(for toolID: String) throws -> Definition {
        guard let definition = definitions[toolID] else {
            throw PrimerToolPortableLauncherError.unsupportedTool(toolID)
        }
        return definition
    }

    private static func launcherScript(for definition: Definition) -> String {
        var lines = [
            "#!/bin/sh",
            "# lungfish-primer-launcher-v1",
            "set -eu",
            "HERE=\"$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\"",
            "ENV_ROOT=\"$(CDPATH= cd -- \"$HERE/..\" && pwd)\"",
            "export PATH=\"$ENV_ROOT/bin${PATH:+:$PATH}\"",
        ]
        if let helper = definition.mafftBinariesRelativePath {
            lines.append("export MAFFT_BINARIES=\"$ENV_ROOT/\(helper)\"")
        }
        lines.append("exec \"$ENV_ROOT/bin/python\" \"$ENV_ROOT/\(definition.sourceRelativePath)\" \"$@\"")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func validate(
        _ artifact: Artifact,
        root: URL,
        requireExecutable: Bool
    ) throws {
        guard validRelativePath(artifact.relativePath) else {
            throw PrimerToolPortableLauncherError.invalidReceipt("unsafe relative path")
        }
        let url = root.appendingPathComponent(artifact.relativePath)
        let current = try self.artifact(relativePath: artifact.relativePath, url: url, root: root)
        guard current.relativePath == artifact.relativePath,
              current.sha256 == artifact.sha256,
              current.sizeBytes == artifact.sizeBytes else {
            throw PrimerToolPortableLauncherError.invalidReceipt("artifact changed: \(artifact.relativePath)")
        }
        guard !requireExecutable || current.posixPermissions & 0o111 != 0 else {
            throw PrimerToolPortableLauncherError.invalidReceipt(
                "launcher is not executable: \(artifact.relativePath)")
        }
    }

    private static func artifact(relativePath: String, url: URL, root: URL) throws -> Artifact {
        let data = try regularFileData(at: url, root: root)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        guard let size else {
            throw PrimerToolPortableLauncherError.invalidReceipt("missing size for \(relativePath)")
        }
        return Artifact(
            relativePath: relativePath,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            sizeBytes: size.uint64Value,
            posixPermissions: try permissions(at: url)
        )
    }

    private static func regularFileData(at url: URL, root: URL) throws -> Data {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PrimerToolPortableLauncherError.invalidEntrypoint("unsafe or missing file at \(url.path)")
        }
        var current = root
        for component in path.dropFirst(rootPath.count).split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw PrimerToolPortableLauncherError.invalidEntrypoint("symbolic-link ancestor at \(current.path)")
            }
        }
        return try Data(contentsOf: url)
    }

    private static func permissions(at url: URL) throws -> Int {
        guard let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            throw PrimerToolPortableLauncherError.invalidEntrypoint("missing permissions for \(url.path)")
        }
        return value.intValue
    }

    private static func validRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
