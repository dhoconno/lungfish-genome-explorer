import Foundation

/// Async helpers that perform blocking file I/O off the main actor.
///
/// All four functions are `nonisolated` and use `Task.detached` to ensure that
/// the blocking Foundation call runs on the cooperative thread pool rather than
/// the caller's actor executor (including @MainActor).  Every parameter type
/// (`URL`, `Data`, `String`, `String.Encoding`, `Data.WritingOptions`, `Bool`)
/// is `Sendable`, so there is no data-race risk.
///
/// Callers `await` the result and then commit any UI changes on `@MainActor`.
public enum AsyncFileReader {
    /// Reads the contents of `url` as a `String`.
    public nonisolated static func readString(
        _ url: URL,
        encoding: String.Encoding = .utf8
    ) async throws -> String {
        try await Task.detached {
            try String(contentsOf: url, encoding: encoding)
        }.value
    }

    /// Reads the raw bytes of `url`.
    public nonisolated static func readData(_ url: URL) async throws -> Data {
        try await Task.detached {
            try Data(contentsOf: url)
        }.value
    }

    /// Writes `data` to `url`.
    public nonisolated static func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions = .atomic
    ) async throws {
        try await Task.detached {
            try data.write(to: url, options: options)
        }.value
    }

    /// Writes `string` to `url`.
    public nonisolated static func writeString(
        _ string: String,
        to url: URL,
        atomically: Bool = true,
        encoding: String.Encoding = .utf8
    ) async throws {
        try await Task.detached {
            try string.write(to: url, atomically: atomically, encoding: encoding)
        }.value
    }
}
