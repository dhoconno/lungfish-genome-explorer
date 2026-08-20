import Testing
@testable import LungfishCore

@Suite("Lungfish app identity")
struct AppIdentityTests {
    @Test("Preview bundle values remain Preview")
    func previewIdentity() {
        let identity = LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Lungfish Genome Explorer Preview",
            "CFBundleName": "Lungfish Preview",
            "LungfishReleaseChannel": "preview",
        ])
        #expect(identity.fullName == "Lungfish Genome Explorer Preview")
        #expect(identity.shortName == "Lungfish Preview")
        #expect(identity.releaseChannel == .preview)
        #expect(identity.previewCaveat == "Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback.")
    }

    @Test("Missing or malformed bundle values fall back to Stable")
    func stableFallback() {
        let identity = LungfishAppIdentity.from(infoDictionary: [:])
        #expect(identity.fullName == "Lungfish Genome Explorer")
        #expect(identity.shortName == "Lungfish")
        #expect(identity.releaseChannel == .stable)
        #expect(identity.previewCaveat == nil)
    }
}
