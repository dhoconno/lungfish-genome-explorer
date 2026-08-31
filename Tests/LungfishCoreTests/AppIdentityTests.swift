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
