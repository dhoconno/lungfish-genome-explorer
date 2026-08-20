import Foundation

public enum LungfishReleaseChannel: String, Sendable {
    case preview
    case stable
}

public struct LungfishAppIdentity: Equatable, Sendable {
    public static let previewCaveatText = "Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback."

    public let fullName: String
    public let shortName: String
    public let releaseChannel: LungfishReleaseChannel

    public var isPreview: Bool { releaseChannel == .preview }
    public var previewCaveat: String? { isPreview ? Self.previewCaveatText : nil }

    public static var current: Self { from(infoDictionary: Bundle.main.infoDictionary) }

    public static func from(infoDictionary: [String: Any]?) -> Self {
        guard infoDictionary?["LungfishReleaseChannel"] as? String == LungfishReleaseChannel.preview.rawValue else {
            return .init(fullName: "Lungfish Genome Explorer", shortName: "Lungfish", releaseChannel: .stable)
        }
        return .init(
            fullName: infoDictionary?["CFBundleDisplayName"] as? String ?? "Lungfish Genome Explorer Preview",
            shortName: infoDictionary?["CFBundleName"] as? String ?? "Lungfish Preview",
            releaseChannel: .preview
        )
    }
}
