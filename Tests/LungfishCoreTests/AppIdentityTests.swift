import Foundation
import Testing
@testable import LungfishCore

@Suite("Lungfish app identity")
struct AppIdentityTests {
    @Test("Preview bundle values remain Preview")
    func previewIdentity() throws {
        let identity = try LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Lungfish Genome Explorer Preview",
            "CFBundleName": "Lungfish Preview",
            "CFBundleIdentifier": "com.lungfish.browser.preview",
            "LungfishReleaseChannel": "preview",
        ])

        #expect(identity == .preview)
        #expect(identity.bundleIdentifier == "com.lungfish.browser.preview")
        #expect(identity.previewCaveat == LungfishAppIdentity.previewCaveatText)
        #expect(identity.applicationSupportDirectoryName == "Lungfish")
        #expect(identity.managedStorageDirectoryName == ".lungfish")
        #expect(identity.keychainService == "com.lungfish.secrets")
    }

    @Test("Stable bundle values remain Stable")
    func stableIdentity() throws {
        let identity = try LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Lungfish Genome Explorer",
            "CFBundleName": "Lungfish",
            "CFBundleIdentifier": "com.lungfish.browser",
            "LungfishReleaseChannel": "stable",
        ])

        #expect(identity == .stable)
        #expect(identity.previewCaveat == nil)
        #expect(identity.applicationSupportDirectoryName == "Lungfish")
        #expect(identity.managedStorageDirectoryName == ".lungfish")
        #expect(identity.keychainService == "com.lungfish.secrets")
    }

    @Test("Debug bundle values use an isolated Debug identity")
    func debugIdentity() throws {
        let identity = try LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Lungfish Genome Explorer Debug",
            "CFBundleName": "Lungfish Debug",
            "CFBundleIdentifier": "com.lungfish.browser.debug",
            "LungfishReleaseChannel": "debug",
        ])

        #expect(identity == .debug)
        #expect(identity.previewCaveat == nil)
        #expect(identity.applicationSupportDirectoryName == "Lungfish Debug")
        #expect(identity.logDirectoryName == "Lungfish Debug")
        #expect(identity.cacheDirectoryName == "com.lungfish.debug")
        #expect(identity.containerCacheDirectoryName == "com.lungfish.debug.containers")
        #expect(identity.temporaryDirectoryName == "com.lungfish.debug")
        #expect(identity.managedStorageConfigDirectoryName == "lungfish-debug")
        #expect(identity.managedStorageDirectoryName == ".lungfish-debug")
        #expect(identity.keychainService == "com.lungfish.secrets.debug")
    }

    @Test("Nextflow state is isolated only for Debug")
    func nextflowHomeIdentity() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(LungfishAppIdentity.stable.nextflowHomeURL(homeDirectory: home).path == "/Users/example/.nextflow")
        #expect(LungfishAppIdentity.preview.nextflowHomeURL(homeDirectory: home).path == "/Users/example/.nextflow")
        #expect(
            LungfishAppIdentity.debug.nextflowHomeURL(homeDirectory: home).path
                == "/Users/example/Library/Caches/com.lungfish.debug/nextflow"
        )
    }

    @Test("Missing bundle metadata is rejected instead of becoming Stable")
    func missingMetadataIsRejected() {
        #expect(throws: LungfishAppIdentityError.self) {
            try LungfishAppIdentity.from(infoDictionary: [:])
        }
    }

    @Test("Unknown or internally inconsistent bundle metadata is rejected")
    func malformedMetadataIsRejected() {
        #expect(throws: LungfishAppIdentityError.self) {
            try LungfishAppIdentity.from(infoDictionary: [
                "CFBundleDisplayName": "Lungfish Genome Explorer Preview",
                "CFBundleName": "Lungfish Preview",
                "CFBundleIdentifier": "com.lungfish.browser",
                "LungfishReleaseChannel": "stable",
            ])
        }
        #expect(throws: LungfishAppIdentityError.self) {
            try LungfishAppIdentity.from(infoDictionary: [
                "CFBundleDisplayName": "Lungfish Genome Explorer Debug",
                "CFBundleName": "Lungfish Debug",
                "CFBundleIdentifier": "com.lungfish.browser",
                "LungfishReleaseChannel": "debug",
            ])
        }
        #expect(throws: LungfishAppIdentityError.self) {
            try LungfishAppIdentity.from(infoDictionary: [
                "CFBundleDisplayName": 42,
                "CFBundleName": "Lungfish",
                "CFBundleIdentifier": "com.lungfish.browser",
                "LungfishReleaseChannel": "stable",
            ])
        }
    }
}

extension AppIdentityTests {
    private func forkInfo(channel: String = "preview", namespace: String = "org.example.genome") -> [String: Any] {
        [
            "CFBundleDisplayName": "Example Genome",
            "CFBundleName": "Example",
            "CFBundleIdentifier": namespace + (channel == "stable" ? "" : "." + channel),
            "LungfishReleaseChannel": channel,
            "LungfishIdentitySchemaVersion": 1,
            "LungfishRuntimeNamespace": namespace,
        ]
    }

    @Test("Fork channels isolate all persisted runtime paths")
    func forkPaths() throws {
        for channel in ["stable", "preview", "debug"] {
            let identity = try LungfishAppIdentity.from(infoDictionary: forkInfo(channel: channel))
            let namespace = "org.example.genome.\(channel)"
            #expect(identity.isFork)
            #expect(!identity.allowsUpstreamLegacyMigration)
            #expect(identity.runtimeNamespace == "org.example.genome")
            #expect(identity.applicationSupportDirectoryName == namespace)
            #expect(identity.logDirectoryName == namespace)
            #expect(identity.cacheDirectoryName == namespace)
            #expect(identity.containerCacheDirectoryName == namespace + ".containers")
            #expect(identity.temporaryDirectoryName == namespace)
            #expect(identity.managedStorageConfigDirectoryName == namespace)
            #expect(identity.managedStorageDirectoryName == "." + namespace)
            #expect(identity.keychainService == namespace + ".secrets")
            #expect(identity.nextflowHomeURL(homeDirectory: URL(fileURLWithPath: "/Users/example")).path
                == "/Users/example/Library/Caches/\(namespace)/nextflow")
            #expect(identity.websiteURL == nil)
            #expect(identity.documentationURL == nil)
            #expect(identity.releaseHistoryURL == nil)
            #expect(identity.helpBookName == "Example Genome Help")
        }
    }

    @Test("Fork preferences use a suite distinct from the executable bundle identifier")
    func forkPreferenceDomainDoesNotAliasBundleIdentifier() throws {
        for channel in ["stable", "preview", "debug"] {
            let identity = try LungfishAppIdentity.from(infoDictionary: forkInfo(channel: channel))
            #expect(identity.preferencesSuiteName == "org.example.genome.\(channel).preferences")
            #expect(identity.preferencesSuiteName != identity.bundleIdentifier)
        }
        for identity in [LungfishAppIdentity.stable, .preview, .debug] {
            #expect(identity.preferencesSuiteName == nil)
            #expect(identity.preferences === UserDefaults.standard)
        }
    }

    @Test("Fork preference suites do not share values across channels")
    func forkPreferences() throws {
        let namespace = "org.example.test-" + UUID().uuidString.lowercased()
        let preview = try LungfishAppIdentity.from(infoDictionary: forkInfo(namespace: namespace))
        let stable = try LungfishAppIdentity.from(infoDictionary: forkInfo(channel: "stable", namespace: namespace))
        let debug = try LungfishAppIdentity.from(infoDictionary: forkInfo(channel: "debug", namespace: namespace))
        let previewDefaults = preview.preferences
        let stableDefaults = stable.preferences
        let debugDefaults = debug.preferences
        defer {
            previewDefaults.removePersistentDomain(forName: preview.preferencesSuiteName!)
            stableDefaults.removePersistentDomain(forName: stable.preferencesSuiteName!)
            debugDefaults.removePersistentDomain(forName: debug.preferencesSuiteName!)
        }
        previewDefaults.set("preview-only", forKey: "identity-test")
        #expect(preview.preferences.string(forKey: "identity-test") == "preview-only")
        #expect(stableDefaults.string(forKey: "identity-test") == nil)
        #expect(debugDefaults.string(forKey: "identity-test") == nil)
        #expect(previewDefaults.persistentDomain(forName: preview.preferencesSuiteName!)?["identity-test"] as? String == "preview-only")
        debugDefaults.set("debug-only", forKey: "identity-test")
        #expect(debug.preferences.string(forKey: "identity-test") == "debug-only")
        #expect(preview.preferences.string(forKey: "identity-test") == "preview-only")
        #expect(stableDefaults.string(forKey: "identity-test") == nil)
    }

    @Test("Fork metadata rejects partial, invalid and reserved namespaces")
    func invalidForkMetadata() {
        let mutations: [(String, Any?)] = [
            ("LungfishIdentitySchemaVersion", nil), ("LungfishIdentitySchemaVersion", true),
            ("LungfishIdentitySchemaVersion", "1"), ("LungfishIdentitySchemaVersion", 2),
            ("LungfishIdentitySchemaVersion", 1.5), ("LungfishRuntimeNamespace", nil),
            ("LungfishRuntimeNamespace", "com.lungfish"), ("LungfishRuntimeNamespace", "org.lungfish.fork"),
            ("LungfishRuntimeNamespace", "../example"), ("LungfishRuntimeNamespace", "org.example/escape"),
            ("LungfishRuntimeNamespace", "org..example"), ("LungfishRuntimeNamespace", "org.example%2ffoo"),
            ("CFBundleIdentifier", "com.lungfish.browser.preview"),
            ("CFBundleDisplayName", "$(UNRESOLVED)"), ("CFBundleName", "Bad\nName"),
            ("LungfishReleaseChannel", "nightly"),
        ]
        for (key, value) in mutations {
            var info = forkInfo()
            info[key] = value
            #expect(throws: LungfishAppIdentityError.self) { try LungfishAppIdentity.from(infoDictionary: info) }
        }
    }

    @Test("Fork product links accept HTTPS without credentials only")
    func forkProductLinks() throws {
        var info = forkInfo()
        info["LungfishWebsiteURL"] = "https://example.org/genome"
        let identity = try LungfishAppIdentity.from(infoDictionary: info)
        #expect(identity.websiteURL?.absoluteString == "https://example.org/genome")
        #expect(identity.cliInformationURL == identity.websiteURL)
        for invalid in ["http://example.org", "https://user:secret@example.org", "file:///tmp/file", "https:///", "https://example.org\n"] {
            info["LungfishWebsiteURL"] = invalid
            #expect(throws: LungfishAppIdentityError.self) { try LungfishAppIdentity.from(infoDictionary: info) }
        }
    }

    @Test("Fork executable identity survives copying and crosschecks its enclosing app")
    func forkExecutableResolution() throws {
        let info = forkInfo()
        let identity = try LungfishAppIdentity.from(infoDictionary: info)
        #expect(try RuntimeAppIdentityResolver.resolve(mainAppInfo: info) == identity)
        #expect(try RuntimeAppIdentityResolver.resolve(embeddedExecutableInfo: info) == identity)
        #expect(try RuntimeAppIdentityResolver.resolve(embeddedExecutableInfo: info, enclosingAppInfo: info) == identity)
        #expect(throws: LungfishAppIdentityError.self) {
            try RuntimeAppIdentityResolver.resolve(enclosingAppInfo: info)
        }
        #expect(throws: LungfishAppIdentityError.self) {
            try RuntimeAppIdentityResolver.resolve(embeddedExecutableInfo: info, enclosingAppInfo: forkInfo(channel: "stable"))
        }
        #expect(throws: LungfishAppIdentityError.self) {
            try RuntimeAppIdentityResolver.resolve(embeddedExecutableInfo: [:], enclosingAppInfo: info)
        }
        #expect(throws: LungfishAppIdentityError.self) {
            try RuntimeAppIdentityResolver.resolve(embeddedExecutableInfo: info, enclosingAppInfo: [:])
        }
    }

    @Test("Historical upstream command line state remains Stable")
    func historicalCLIResolution() throws {
        #expect(try RuntimeAppIdentityResolver.resolve() == .stable)
        let debug: [String: Any] = [
            "CFBundleDisplayName": LungfishAppIdentity.debug.fullName,
            "CFBundleName": LungfishAppIdentity.debug.shortName,
            "CFBundleIdentifier": LungfishAppIdentity.debug.bundleIdentifier,
            "LungfishReleaseChannel": "debug",
        ]
        #expect(try RuntimeAppIdentityResolver.resolve(enclosingAppInfo: debug) == .stable)
        #expect(try RuntimeAppIdentityResolver.resolve(embeddedExecutableInfo: debug, enclosingAppInfo: debug) == .stable)
        #expect(throws: LungfishAppIdentityError.self) {
            try RuntimeAppIdentityResolver.resolve(embeddedExecutableInfo: debug, enclosingAppInfo: forkInfo())
        }
    }

    @Test("Canonical CLI symlinks resolve only their owning app metadata")
    func enclosingAppResolution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Moved Example.app")
        let executable = app.appendingPathComponent("Contents/MacOS/lungfish-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let data = try PropertyListSerialization.data(fromPropertyList: forkInfo(), format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let alias = root.appendingPathComponent("installed-cli")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        let resolved = try RuntimeAppIdentityResolver.enclosingAppInfo(executableURL: alias)
        #expect(try LungfishAppIdentity.from(infoDictionary: resolved).runtimeNamespace == "org.example.genome")
        let copied = root.appendingPathComponent("copied-cli")
        try Data().write(to: copied)
        #expect(try RuntimeAppIdentityResolver.enclosingAppInfo(executableURL: copied) == nil)
    }
}
