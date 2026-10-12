import Foundation
import XCTest

// A copy of `waitUntil` in Tests/LungfishAppTests/AssemblyViewportTestSupport.swift. The tests that
// moved here from LungfishAppTests called that one, and this target has no access to it. Keep the
// two in step.

/// Fails the test when `predicate` does not hold within the timeout. Swift
/// picks this over the shared `waitUntil` in LungfishTestSupport for a
/// synchronous main-actor closure, so its default matches that helper's 5 s,
/// which leaves room for the parallel unit tier. It returns as soon as the
/// predicate holds.
@MainActor
func waitUntil(
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if predicate() {
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}
