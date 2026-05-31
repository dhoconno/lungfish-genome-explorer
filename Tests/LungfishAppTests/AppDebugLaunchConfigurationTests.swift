import XCTest
@testable import LungfishApp

final class AppDebugLaunchConfigurationTests: XCTestCase {
    func testEnvVarEnablesRequiredSetupBypassInDebug() {
        let config = AppDebugLaunchConfiguration(
            environment: ["LUNGFISH_DEBUG_BYPASS_REQUIRED_SETUP": "1"]
        )

        #if DEBUG
        XCTAssertTrue(config.bypassRequiredSetup)
        #else
        XCTAssertFalse(config.bypassRequiredSetup)
        #endif
    }

    func testBypassDefaultsToDisabled() {
        let config = AppDebugLaunchConfiguration(environment: [:])

        XCTAssertFalse(config.bypassRequiredSetup)
    }

    private static func packageRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBuildAppDebugBundleUsesDistinctLaunchServicesIdentity() throws {
        let script = try String(
            contentsOf: Self.packageRoot().appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        // The debug bundle's distinct Launch Services identity.
        XCTAssertTrue(script.contains("DEBUG_BUNDLE_ID=\"org.lungfish.genome-browser.debug\""))
        XCTAssertTrue(script.contains("DEBUG_BUNDLE_NAME=\"Lungfish Debug\""))
        XCTAssertTrue(script.contains("DEBUG_BUNDLE_DISPLAY_NAME=\"Lungfish Genome Browser Debug\""))
        // build-app.sh now copies the shared source Info.plist and substitutes the
        // identity fields via plutil (it no longer embeds an inline plist heredoc).
        XCTAssertTrue(script.contains("Lungfish-Info.plist"))
        XCTAssertTrue(script.contains("plutil -replace CFBundleIdentifier -string \"$BUNDLE_ID\""))
        XCTAssertTrue(script.contains("plutil -replace CFBundleName -string \"$BUNDLE_NAME\""))
        XCTAssertTrue(script.contains("plutil -replace CFBundleDisplayName -string \"$BUNDLE_DISPLAY_NAME\""))
    }

    /// Drift guard: the shared source Info.plist (consumed by BOTH the notarized
    /// xcodeproj build and scripts/build-app.sh) must register every directory
    /// bundle type that the runtime opens, so the document-type registration can
    /// never silently diverge from the code. Mirrors LungfishApp.DocumentType's
    /// directory-bundle extensions.
    func testSharedInfoPlistRegistersDirectoryBundleDocumentTypes() throws {
        let plistURL = Self.packageRoot().appendingPathComponent("Lungfish-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        // Exported UTI declarations: collect identifier -> declared extensions.
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        var extensionsByUTI: [String: Set<String>] = [:]
        for declaration in exported {
            guard let identifier = declaration["UTTypeIdentifier"] as? String else { continue }
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            let exts = (tags?["public.filename-extension"] as? [String]) ?? []
            extensionsByUTI[identifier] = Set(exts)
        }

        // Every directory-bundle UTI must conform to com.apple.package and declare
        // its extension, and a matching CFBundleDocumentTypes entry must reference it.
        let docTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let declaredContentTypes = Set(docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })

        // The four directory reference/alignment/tree bundles this work cares about,
        // keyed UTI -> expected filename extension.
        let requiredBundleUTIs: [String: String] = [
            "org.lungfish.reference-bundle": "lungfishref",
            "org.lungfish.mhc-reference-bundle": "lungfishmhcref",
            "org.lungfish.msa-bundle": "lungfishmsa",
            "org.lungfish.tree-bundle": "lungfishtree",
        ]
        for (uti, ext) in requiredBundleUTIs {
            XCTAssertEqual(extensionsByUTI[uti], [ext], "UTI \(uti) should declare extension .\(ext)")
            XCTAssertTrue(
                declaredContentTypes.contains(uti),
                "CFBundleDocumentTypes should declare a handler for \(uti)"
            )
            let declaration = try XCTUnwrap(exported.first { ($0["UTTypeIdentifier"] as? String) == uti })
            let conformsTo = Set((declaration["UTTypeConformsTo"] as? [String]) ?? [])
            XCTAssertTrue(
                conformsTo.contains("com.apple.package"),
                "Directory bundle \(uti) must conform to com.apple.package"
            )
        }
    }
}
