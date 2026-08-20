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

    @Test("Preview channel with a missing Preview name falls back to Stable")
    func missingPreviewNameFallsBackToStable() {
        let identity = LungfishAppIdentity.from(infoDictionary: [
            "CFBundleName": "Lungfish Preview",
            "LungfishReleaseChannel": "preview",
        ])

        #expect(identity == stableIdentity)
    }

    @Test("Preview channel with a non-String Preview name falls back to Stable")
    func nonStringPreviewNameFallsBackToStable() {
        let identity = LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": 42,
            "CFBundleName": "Lungfish Preview",
            "LungfishReleaseChannel": "preview",
        ])

        #expect(identity == stableIdentity)
    }

    @Test("Preview channel with a wrong Preview identity value falls back to Stable")
    func wrongPreviewIdentityFallsBackToStable() {
        let identity = LungfishAppIdentity.from(infoDictionary: [
            "CFBundleDisplayName": "Lungfish Genome Explorer Preview",
            "CFBundleName": "Lungfish Beta",
            "LungfishReleaseChannel": "preview",
        ])

        #expect(identity == stableIdentity)
    }

    private var stableIdentity: LungfishAppIdentity {
        .init(
            fullName: "Lungfish Genome Explorer",
            shortName: "Lungfish",
            releaseChannel: .stable
        )
    }
}
