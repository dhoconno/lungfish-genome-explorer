import XCTest
import LungfishTestSupport
@testable import LungfishIO

final class PrimerSchemesFolderTests: XCTestCase {
    func testEnsureFolderCreatesPrimerSchemesDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try PrimerSchemesFolder.ensureFolder(in: tmp)
        XCTAssertEqual(url.lastPathComponent, "Primer Schemes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testListReturnsBundlesSortedByName() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let folder = try PrimerSchemesFolder.ensureFolder(in: tmp)

        // Copy the fixture bundle twice with different names, then rewrite each
        // copy's manifest.json so the two bundles have distinct `manifest.name`
        // values. `listBundles` sorts by `manifest.name` (the user-visible
        // identifier), matching `BuiltInPrimerSchemeService`'s sort key.
        let fixture = try fixtureURL(
            "primerschemes/valid-simple.lungfishprimers",
            in: .module
        )
        let zBundle = folder.appendingPathComponent("ZZZ.lungfishprimers", isDirectory: true)
        let aBundle = folder.appendingPathComponent("AAA.lungfishprimers", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: zBundle)
        try FileManager.default.copyItem(at: fixture, to: aBundle)
        try rewriteManifestName(in: aBundle, to: "aaa")
        try rewriteManifestName(in: zBundle, to: "zzz")

        let bundles = PrimerSchemesFolder.listBundles(in: tmp)
        XCTAssertEqual(bundles.count, 2)
        XCTAssertEqual(bundles.first?.manifest.name, "aaa")
        XCTAssertEqual(bundles.last?.manifest.name, "zzz")
    }

    /// Rewrites `manifest.json`'s `name` field inside a copied fixture bundle.
    /// Uses JSONSerialization to preserve the rest of the document as-is.
    private func rewriteManifestName(in bundleURL: URL, to newName: String) throws {
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "PrimerSchemesFolderTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "manifest.json is not a JSON object"])
        }
        obj["name"] = newName
        let rewritten = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        try rewritten.write(to: manifestURL)
    }
}
