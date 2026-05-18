import Foundation

struct FASTQOperationStagingCleanup: Sendable {
    func cleanup(
        directories: [URL],
        preserving preservedURLs: [URL]
    ) {
        for directory in directories.map(\.standardizedFileURL) {
            guard Self.isTransientFASTQOperationStagingDirectory(directory),
                  !shouldPreserveTransientDirectory(directory, preserving: preservedURLs) else {
                continue
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func shouldPreserveTransientDirectory(
        _ directory: URL,
        preserving preservedURLs: [URL]
    ) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        return preservedURLs.map(\.standardizedFileURL.path).contains { preservedPath in
            preservedPath == directoryPath
                || preservedPath.hasPrefix(directoryPath + "/")
                || directoryPath.hasPrefix(preservedPath + "/")
        }
    }

    private static func isTransientFASTQOperationStagingDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("cli-output-") || name.hasPrefix("materialized-inputs-")
    }
}
