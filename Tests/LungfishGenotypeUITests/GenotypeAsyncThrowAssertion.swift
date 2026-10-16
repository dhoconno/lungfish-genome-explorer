import XCTest

/// `XCTAssertThrowsError` for an async expression that runs in the caller's isolation (2.11 S35).
///
/// The store's edits are async and main-actor isolated, so a main-actor test awaits them here
/// without sending the expression to another isolation, which the shared
/// `XCTAssertThrowsErrorAsync` of LungfishTestSupport would do.
func XCTAssertThrowsErrorInIsolation<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "Expected expression to throw",
    isolation: isolated (any Actor)? = #isolation,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
