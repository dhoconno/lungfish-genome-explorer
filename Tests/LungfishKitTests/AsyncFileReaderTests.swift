import XCTest
@testable import LungfishKit

final class AsyncFileReaderTests: XCTestCase {
    func testWriteThenReadRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-asyncfilereader-\(ProcessInfo.processInfo.globallyUniqueString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AsyncFileReader.writeString("hello", to: url)
        let read = try await AsyncFileReader.readString(url)
        XCTAssertEqual(read, "hello")
    }

    func testReadMissingFileThrows() async {
        let url = URL(fileURLWithPath: "/nonexistent/lungfish/\(UUID().uuidString)")
        do { _ = try await AsyncFileReader.readString(url); XCTFail("expected throw") }
        catch { /* expected */ }
    }
}
