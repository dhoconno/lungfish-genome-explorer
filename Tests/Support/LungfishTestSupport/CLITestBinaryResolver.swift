import Foundation

public enum CLITestBinaryResolver {
    private static let environmentKeys = [
        "LUNGFISH_TEST_CLI",
        "LUNGFISH_CLI",
        "LUNGFISH_CLI_PATH",
        "LUNGFISH_CLI_BINARY",
    ]

    public static func repositoryRoot(containing filePath: String) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Resolves a CLI prepared by the test runner without invoking SwiftPM.
    public static func cliBinaryURL(
        buildProductsDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let environmentPath = environmentKeys.compactMap({ environment[$0] }).first(where: { !$0.isEmpty }) {
            let injectedBinary = URL(fileURLWithPath: environmentPath)
            return FileManager.default.isExecutableFile(atPath: injectedBinary.path) ? injectedBinary : nil
        }

        if let buildProductsDirectory {
            let siblingBinary = buildProductsDirectory.appendingPathComponent("lungfish-cli")
            return FileManager.default.isExecutableFile(atPath: siblingBinary.path) ? siblingBinary : nil
        }

        return nil
    }
}
