import Foundation
import LungfishCore

public enum GeneiousArchiveToolError: LocalizedError, Sendable, Equatable {
    case unsafeMemberPath(String)
    case unsafeArchive(String)
    case unzipFailed(arguments: [String], status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .unsafeMemberPath(let path):
            return "Unsafe Geneious archive member path: \(path)"
        case .unsafeArchive(let reason):
            return "Unsafe Geneious archive: \(reason)"
        case .unzipFailed(let arguments, let status, let stderr):
            let command = (["/usr/bin/unzip"] + arguments).joined(separator: " ")
            return "\(command) failed with exit code \(status): \(stderr)"
        }
    }
}

public struct GeneiousArchiveTool: Sendable {
    private let unzipURL: URL

    public init(unzipURL: URL = URL(fileURLWithPath: "/usr/bin/unzip")) {
        self.unzipURL = unzipURL
    }

    public static func validateSafeMemberPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw GeneiousArchiveToolError.unsafeMemberPath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw GeneiousArchiveToolError.unsafeMemberPath(path)
        }

        for (index, component) in components.enumerated() {
            if component.isEmpty {
                let isTrailingDirectorySeparator = index == components.count - 1 && path.hasSuffix("/")
                if isTrailingDirectorySeparator {
                    continue
                }
                throw GeneiousArchiveToolError.unsafeMemberPath(path)
            }
            if component == "." || component == ".." {
                throw GeneiousArchiveToolError.unsafeMemberPath(path)
            }
        }
    }

    public func listMembers(archiveURL: URL) throws -> [String] {
        let result = try runUnzip(arguments: ["-Z1", archiveURL.path], capturesStdout: true)
        let members = result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        for member in members {
            try Self.validateSafeMemberPath(member)
        }
        return members
    }

    public func extract(archiveURL: URL, to destinationURL: URL) throws {
        _ = try listMembers(archiveURL: archiveURL)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        _ = try runUnzip(arguments: ["-qq", archiveURL.path, "-d", destinationURL.path])
        // unzip refuses `..` and absolute names and a write through a link, but it
        // extracts a symbolic link that leaves the folder, as SafeZipExtractor refuses.
        do {
            try SafeZipExtractor.verifySymbolicLinksStayInside(destinationURL)
        } catch DemoProjectError.unsafeArchive(let reason) {
            throw GeneiousArchiveToolError.unsafeArchive(reason)
        }
    }

    private func runUnzip(arguments: [String], capturesStdout: Bool = false) throws -> (stdout: String, stderr: String) {
        let spec = ToolProcessSpec(
            executableURL: unzipURL,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: capturesStdout ? .capture() : .discard,
            stderr: .capture(limit: 64 * 1024),
            label: "unzip"
        )
        let result = try ToolProcess.runBlocking(spec)
        guard result.isSuccess else {
            throw GeneiousArchiveToolError.unzipFailed(
                arguments: arguments,
                status: result.status,
                stderr: result.status == 0 ? (result.incompleteOutputReason ?? "") : result.stderrText
            )
        }
        return (result.stdoutText, result.stderrText)
    }
}
