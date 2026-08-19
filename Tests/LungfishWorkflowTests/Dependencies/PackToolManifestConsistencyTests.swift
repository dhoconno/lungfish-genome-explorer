import XCTest
@testable import LungfishWorkflow

final class PackToolManifestConsistencyTests: XCTestCase {
    func testEveryPinnedPackRequirementComesFromManifest() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for pack in PluginPack.builtIn where pack.kind == .optionalTools {
            for req in pack.requirements where !req.installPackages.isEmpty && req.managedDatabaseID == nil {
                guard let spec = manifest.packTool(packID: pack.id, id: req.id) else {
                    // Unpinned shorthand requirements (`.package("x")`) install the bare package
                    // name and legitimately have no manifest entry.
                    XCTAssertEqual(
                        req.installPackages,
                        [req.id],
                        "\(pack.id)/\(req.id) is pinned but has no packTools entry"
                    )
                    continue
                }
                if let build = spec.sourceBuild {
                    // A source-built tool installs the manifest's toolchain pins and
                    // applies the manifest's overlay; its version is the build's.
                    XCTAssertEqual(
                        req.installPackages,
                        build.toolchainPackages,
                        "\(pack.id)/\(req.id) must install the manifest sourceBuild toolchain"
                    )
                    XCTAssertEqual(req.version, build.version, "\(pack.id)/\(req.id) version must be the sourceBuild's")
                    XCTAssertEqual(req.sourceOverlay?.version, build.version)
                    XCTAssertEqual(req.sourceOverlay?.sourceURL.absoluteString, build.url)
                    XCTAssertEqual(req.sourceOverlay?.sha256, build.sha256)
                } else {
                    XCTAssertEqual(
                        req.installPackages,
                        [spec.packageSpec],
                        "\(pack.id)/\(req.id) must install the manifest spec"
                    )
                    XCTAssertNil(req.sourceOverlay, "\(pack.id)/\(req.id) has an overlay with no manifest sourceBuild")
                    XCTAssertEqual(req.version, spec.version, "\(pack.id)/\(req.id) version must match the manifest")
                }
                XCTAssertEqual(req.environment, spec.environment, "\(pack.id)/\(req.id) environment must match the manifest")
                XCTAssertEqual(req.license, spec.license, "\(pack.id)/\(req.id) license must match the manifest")
                XCTAssertEqual(req.sourceURL, spec.sourceUrl, "\(pack.id)/\(req.id) sourceURL must match the manifest")
            }
        }
    }

    func testNoManifestPackToolIsOrphaned() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let known = Set(PluginPack.builtIn.flatMap { pack in pack.requirements.map { "\(pack.id)/\($0.id)" } })
        for spec in manifest.packTools {
            XCTAssertTrue(known.contains(spec.id), "manifest packTools entry \(spec.id) has no PluginPack requirement")
        }
    }

    func testBundledManifestMatchesTheBundleLoad() throws {
        let loaded = try ManagedToolLock.loadFromBundle()

        XCTAssertEqual(ManagedToolLock.bundled, loaded)
    }
}
