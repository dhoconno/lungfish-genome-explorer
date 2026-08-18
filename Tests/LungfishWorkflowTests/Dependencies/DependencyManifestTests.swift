import XCTest
@testable import LungfishWorkflow

final class DependencyManifestTests: XCTestCase {
    func testBundledManifestHasDependencySetAndSections() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        XCTAssertNotNil(manifest.dependencySet)
        XCTAssertTrue(manifest.resolvedDependencySet.range(of: #"^\d{4}\.[12]$"#, options: .regularExpression) != nil,
                      "dependencySet must be YYYY.N, got \(manifest.resolvedDependencySet)")
        XCTAssertFalse(manifest.packTools.isEmpty)
        XCTAssertNotNil(manifest.pipeline(id: "taxtriage"))
        XCTAssertNotNil(manifest.database(id: "human-scrubber"))
        XCTAssertNotNil(manifest.bootstrap?.micromamba.version)
    }

    func testEveryCondaSpecHasFullBuildString() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        // freyja=2.0.0 was never published for osx-arm64 or noarch (only linux-64/osx-64);
        // per task-A1-brief.md it keeps the current unbuilt PluginPack literal until the
        // pin moves off 2.0.0. See task-A1-report.md concerns.
        let knownUnresolvedBuilds: Set<String> = ["bioconda::freyja=2.0.0"]
        for spec in manifest.allCondaSpecs where !knownUnresolvedBuilds.contains(spec) {
            let parts = spec.split(separator: "=", omittingEmptySubsequences: false)
            XCTAssertEqual(parts.count, 3, "spec must be channel::name=version=build, got \(spec)")
            XCTAssertTrue(spec.contains("::"), "spec must carry a channel, got \(spec)")
        }
    }

    func testLegacyShapeStillDecodes() throws {
        let legacy = """
        {"packID":"lungfish-tools","displayName":"Third-Party Tools","version":"0.5.0-beta29",
         "tools":[{"id":"samtools","environment":"samtools","packageSpec":"bioconda::samtools=1.23.1=hc612e98_0","executables":["samtools"],"version":"1.23.1"}],
         "managedData":[]}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(ManagedToolLock.self, from: legacy)
        XCTAssertNil(manifest.dependencySet)
        XCTAssertEqual(manifest.resolvedDependencySet, "legacy-0.5.0-beta29")
        XCTAssertTrue(manifest.packTools.isEmpty)
    }

    func testManifestHashIsStableAcrossKeyOrder() throws {
        let a = try JSONDecoder().decode(ManagedToolLock.self, from: Data(#"{"packID":"p","displayName":"d","version":"1","tools":[],"managedData":[],"dependencySet":"2026.1"}"#.utf8))
        let b = try JSONDecoder().decode(ManagedToolLock.self, from: Data(#"{"dependencySet":"2026.1","managedData":[],"tools":[],"version":"1","displayName":"d","packID":"p"}"#.utf8))
        XCTAssertEqual(a.manifestHash, b.manifestHash)
        XCTAssertEqual(a.manifestHash.count, 64)
    }
}
