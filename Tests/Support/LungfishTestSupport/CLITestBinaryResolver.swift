import Foundation

public enum CLITestBinaryResolver {
    public static func repositoryRoot(containing filePath: String) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static func cliBinaryURL(
        repoRoot: URL,
        buildProductsDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [URL] = []

        if let environmentPath = environment["LUNGFISH_CLI_BINARY"], !environmentPath.isEmpty {
            candidates.append(URL(fileURLWithPath: environmentPath))
        }

        if let buildProductsDirectory {
            candidates.append(buildProductsDirectory.appendingPathComponent("lungfish-cli"))
        }

        if let binPath = swiftPMBinPath(packageRoot: repoRoot) {
            candidates.append(binPath.appendingPathComponent("lungfish-cli"))
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func swiftPMBinPath(packageRoot: URL) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift",
            "build",
            "--package-path", packageRoot.path,
            "--show-bin-path",
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard let path = stdoutText
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        } catch {
            return nil
        }
    }
}
