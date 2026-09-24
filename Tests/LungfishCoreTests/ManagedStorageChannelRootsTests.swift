import Foundation
import Testing
@testable import LungfishCore

@Suite("Managed storage channel roots")
struct ManagedStorageChannelRootsTests {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("channel-roots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test("Defaults are the three channel roots under the home directory")
    func defaultRoots() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let roots = ManagedStorageChannelRoots.knownChannelRoots(homeDirectory: home)
        #expect(roots.map(\.lastPathComponent) == [".lungfish", ".lungfish-stable", ".lungfish-debug"])
        #expect(ManagedStorageChannelRoots.sharedCondaPackageCacheURL(homeDirectory: home).path
            == home.standardizedFileURL.appendingPathComponent(".lungfish-shared/conda/pkgs").path)
        #expect(ManagedStorageChannelRoots.existingRoots(homeDirectory: home).isEmpty)
    }

    @Test("A channel's bootstrap config replaces its default root")
    func bootstrapConfigOverridesDefault() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("Volumes-like/stable-root", isDirectory: true)
        let configDirectory = home.appendingPathComponent(".config/lungfish-stable", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = ManagedStorageBootstrapConfig(activeRootPath: custom.path)
        try JSONEncoder().encode(config).write(to: configDirectory.appendingPathComponent("storage-location.json"))
        let pending = ManagedStorageBootstrapConfig(activeRootPath: home.appendingPathComponent("moving").path, migrationState: .pending)
        let debugConfig = home.appendingPathComponent(".config/lungfish-debug", isDirectory: true)
        try FileManager.default.createDirectory(at: debugConfig, withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: debugConfig.appendingPathComponent("storage-location.json"))

        let roots = ManagedStorageChannelRoots.knownChannelRoots(homeDirectory: home)
        #expect(roots[1] == custom.standardizedFileURL)
        // A pending migration keeps the default until it completes.
        #expect(roots[2].lastPathComponent == ".lungfish-debug")
    }

    @Test("Siblings are the other existing roots on the same volume")
    func siblingRoots() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let preview = home.appendingPathComponent(".lungfish", isDirectory: true)
        let stable = home.appendingPathComponent(".lungfish-stable", isDirectory: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stable, withIntermediateDirectories: true)

        #expect(ManagedStorageChannelRoots.siblingRoots(of: preview, homeDirectory: home) == [stable.standardizedFileURL])
        #expect(ManagedStorageChannelRoots.siblingRoots(of: stable, homeDirectory: home) == [preview.standardizedFileURL])
        let debug = home.appendingPathComponent(".lungfish-debug", isDirectory: true)
        #expect(Set(ManagedStorageChannelRoots.siblingRoots(of: debug, homeDirectory: home))
            == [preview.standardizedFileURL, stable.standardizedFileURL])
        #expect(ManagedStorageChannelRoots.existingRoots(homeDirectory: home).count == 2)
    }
}
