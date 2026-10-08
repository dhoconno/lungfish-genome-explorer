import Testing
import XCTest
@testable import LungfishCore

final class ManagedStorageTestWriteGuardTests: XCTestCase {
    private func makeTemporaryHomeDirectory() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-guard-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: home)
        }
        return home
    }

    private func forbiddenRoot(
        _ url: URL,
        home: URL,
        isTestProcess: Bool = true,
        environment: [String: String] = [:]
    ) -> URL? {
        ManagedStorageTestWriteGuard.forbiddenRoot(
            containing: url,
            isTestProcess: isTestProcess,
            environment: environment,
            realHomeDirectory: home
        )
    }

    func testThisProcessIsDetectedAsATestProcess() {
        XCTAssertTrue(ManagedStorageTestWriteGuard.isTestProcess)
    }

    func testEveryChannelRootAndTheSharedRootAreForbiddenInATestProcess() throws {
        let home = try makeTemporaryHomeDirectory()
        for directory in [".lungfish", ".lungfish-stable", ".lungfish-debug", ".lungfish-shared"] {
            let target = home.appendingPathComponent("\(directory)/databases/kraken2/ncbi-taxonomy", isDirectory: true)
            XCTAssertEqual(
                forbiddenRoot(target, home: home)?.lastPathComponent,
                directory,
                "a test process must not install under ~/\(directory)"
            )
        }
    }

    func testTemporaryRootsAndLookalikeDirectoriesAreAllowed() throws {
        let home = try makeTemporaryHomeDirectory()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("injected-\(UUID().uuidString)/databases", isDirectory: true)
        XCTAssertNil(forbiddenRoot(temporaryRoot, home: home))
        XCTAssertNil(forbiddenRoot(home.appendingPathComponent(".lungfish-stable-backup/databases"), home: home))
    }

    func testACustomRootFromTheBootstrapConfigIsForbidden() throws {
        let home = try makeTemporaryHomeDirectory()
        let customRoot = home.appendingPathComponent("ExternalStorage/lungfish", isDirectory: true)
        let configDirectory = home.appendingPathComponent(".config/lungfish-stable", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(ManagedStorageBootstrapConfig(activeRootPath: customRoot.path))
            .write(to: configDirectory.appendingPathComponent("storage-location.json"))

        XCTAssertEqual(
            forbiddenRoot(customRoot.appendingPathComponent("databases/metagenomics-db-registry.json"), home: home)?.path,
            customRoot.standardizedFileURL.path
        )
    }

    func testTheGuardIsOffOutsideTestsUnlessForbiddenAndOffWhenAllowed() throws {
        let home = try makeTemporaryHomeDirectory()
        let target = home.appendingPathComponent(".lungfish-stable/databases", isDirectory: true)

        XCTAssertNil(forbiddenRoot(target, home: home, isTestProcess: false))
        XCTAssertNotNil(forbiddenRoot(
            target, home: home, isTestProcess: false,
            environment: [ManagedStorageTestWriteGuard.forbidEnvironmentKey: "1"]
        ))
        XCTAssertNil(forbiddenRoot(
            target, home: home,
            environment: [ManagedStorageTestWriteGuard.allowEnvironmentKey: "1"]
        ))
    }
}

struct ManagedStorageTestWriteGuardExitTests {
    // The guard stops the process before any write, so this never touches the real root.
    @Test func aTestProcessInstallingUnderTheRealStorageRootStops() async {
        await #expect(processExitsWith: .failure) {
            let home = ManagedStorageTestWriteGuard.realHomeDirectory
            let root = ManagedStorageChannelRoots.knownChannelRoots(homeDirectory: home)[0]
            ManagedStorageTestWriteGuard.checkWrite(
                to: root.appendingPathComponent("databases/kraken2/ncbi-taxonomy", isDirectory: true),
                operation: "Exit test install"
            )
        }
    }
}
