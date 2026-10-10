import CryptoKit
import LungfishCore
import XCTest
@testable import LungfishWorkflow

final class ManagedToolLockIdentityTests: XCTestCase {
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func bundledLockURL() throws -> URL {
        try XCTUnwrap(RuntimeResourceLocator.path("ManagedTools/third-party-tools-lock.json", in: .workflow))
    }

    private func sourceLockURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json")
    }

    func testBundledIdentityHashesTheResourceBytes() throws {
        let identity = try XCTUnwrap(ManagedToolLock.bundledIdentity)
        let resourceBytes = try Data(contentsOf: bundledLockURL())
        let sourceBytes = try Data(contentsOf: sourceLockURL())
        XCTAssertEqual(identity.fileSHA256, sha256(resourceBytes))
        XCTAssertEqual(identity.fileSHA256, sha256(sourceBytes))
        XCTAssertEqual(identity.fileSHA256.count, 64)
        XCTAssertEqual(identity.fileSHA256, identity.fileSHA256.lowercased())
        XCTAssertEqual(identity.lockVersion, ManagedToolLock.bundled.version)
        XCTAssertEqual(identity.dependencySet, ManagedToolLock.bundled.resolvedDependencySet)
    }

    func testBundledEqualsFreshDecodeOfTheSameBytes() throws {
        let bytes = try Data(contentsOf: bundledLockURL())
        let fresh = try JSONDecoder().decode(ManagedToolLock.self, from: bytes)
        XCTAssertEqual(ManagedToolLock.bundled, fresh)
        XCTAssertEqual(ManagedToolLock.bundled.manifestHash, fresh.manifestHash)
    }

    func testWhitespaceByteChangesFileHashButNotManifestHash() throws {
        let bytes = try Data(contentsOf: bundledLockURL())
        let edited = bytes + Data("\n".utf8)
        let original = try JSONDecoder().decode(ManagedToolLock.self, from: bytes)
        let whitespace = try JSONDecoder().decode(ManagedToolLock.self, from: edited)
        let a = ManagedToolLockIdentity(lock: original, lockData: bytes)
        let b = ManagedToolLockIdentity(lock: whitespace, lockData: edited)
        XCTAssertNotEqual(a.fileSHA256, b.fileSHA256)
        XCTAssertEqual(original.manifestHash, whitespace.manifestHash)
    }

    func testContentByteChangeChangesFileHash() throws {
        let bytes = try Data(contentsOf: bundledLockURL())
        var changed = bytes
        let index = try XCTUnwrap(changed.firstIndex(of: UInt8(ascii: "0")))
        changed[index] = UInt8(ascii: "1")
        let lock = try JSONDecoder().decode(ManagedToolLock.self, from: bytes)
        XCTAssertNotEqual(ManagedToolLockIdentity(lock: lock, lockData: bytes).fileSHA256,
                          ManagedToolLockIdentity(lock: lock, lockData: changed).fileSHA256)
    }

    func testUnreadableOrUndecodableFileGivesNilIdentity() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-lock-\(UUID().uuidString).json")
        XCTAssertNil(ManagedToolLockIdentity.read(at: missing))
        XCTAssertNil(ManagedToolLockIdentity.read(at: nil))
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-lock-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        XCTAssertNil(ManagedToolLockIdentity.read(at: garbage))
        XCTAssertNotNil(ManagedToolLockIdentity.read(at: try bundledLockURL()))
    }
}
