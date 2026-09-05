import Foundation
import XCTest
@testable import LungfishCore

final class ProjectStoreConcurrencyTests: XCTestCase {
    func testConcurrentHandlesSerializeCompleteVersionTransactions() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try await ProjectStore(creating: url)
        let sequenceID = try await first.storeSequence(name: "invented", content: "ACGT")
        let second = try await ProjectStore(opening: url)
        let stores = [first, second]
        let diff = SequenceDiff.compute(from: "ACGT", to: "NCGT")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<48 {
                group.addTask {
                    _ = try await stores[index % 2].recordVersion(sequenceId: sequenceID,
                        diff: diff, newContentHash: "invented-version-\(index)", message: "Concurrent fixture \(index)")
                }
            }
            try await group.waitForAll()
        }
        let versions = try await first.getVersionHistory(for: sequenceID)
        let current = try await second.getCurrentVersionIndex(for: sequenceID)
        XCTAssertEqual(versions.count, 48)
        XCTAssertEqual(Set(versions.map(\.contentHash)).count, 48)
        XCTAssertEqual(current, 48)
        let ownsLease = await ProjectStore.ownsWriterLease(at: url)
        XCTAssertTrue(ownsLease)
    }

    func testConcurrentOpenKeepsLeaseUntilEveryHandleIsReleased() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentLease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        var owner: ProjectStore? = try await ProjectStore(creating: url)
        _ = try await owner?.storeSequence(name: "invented", content: "ACGT")
        let readers = try await withThrowingTaskGroup(of: ProjectStore.self, returning: [ProjectStore].self) { group in
            for _ in 0..<8 { group.addTask { try await ProjectStore(opening: url) } }
            var handles: [ProjectStore] = []
            for try await store in group { handles.append(store) }
            return handles
        }
        owner = nil
        for store in readers {
            let summaries = try await store.listSequences()
            XCTAssertEqual(summaries.count, 1)
        }
        let ownsLease = await ProjectStore.ownsWriterLease(at: url)
        XCTAssertTrue(ownsLease)
        withExtendedLifetime(readers) {}
    }
}
