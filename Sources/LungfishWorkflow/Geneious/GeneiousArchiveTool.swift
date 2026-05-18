import Foundation

public enum GeneiousArchiveToolError: LocalizedError, Sendable, Equatable {
    case unsafeMemberPath(String)
    case unzipFailed(arguments: [String], status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .unsafeMemberPath(let path):
            return "Unsafe Geneious archive member path: \(path)"
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
        let result = try runUnzip(arguments: ["-Z1", archiveURL.path])
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
    }

    private func runUnzip(arguments: [String]) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = unzipURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw GeneiousArchiveToolError.unzipFailed(
                arguments: arguments,
                status: process.terminationStatus,
                stderr: stderrText
            )
        }
        return (stdoutText, stderrText)
    }
}
