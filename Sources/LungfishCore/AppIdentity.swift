import Foundation

public enum LungfishReleaseChannel: String, Sendable {
    case debug
    case preview
    case stable
}

public enum LungfishAppIdentityError: Error, Equatable, Sendable {
    case invalidMetadata
}

public struct LungfishAppIdentity: Equatable, Sendable {
    public static let previewCaveatText = "Preview builds are under rapid iterative development. Features may be incomplete, change quickly, or require additional feedback."

    public static let debug = Self(
        fullName: "Lungfish Genome Explorer Debug",
        shortName: "Lungfish Debug",
        bundleIdentifier: "com.lungfish.browser.debug",
        releaseChannel: .debug
    )
    public static let preview = Self(
        fullName: "Lungfish Genome Explorer Preview",
        shortName: "Lungfish Preview",
        bundleIdentifier: "com.lungfish.browser.preview",
        releaseChannel: .preview
    )
    public static let stable = Self(
        fullName: "Lungfish Genome Explorer",
        shortName: "Lungfish",
        bundleIdentifier: "com.lungfish.browser",
        releaseChannel: .stable
    )

    public let fullName: String
    public let shortName: String
    public let bundleIdentifier: String
    public let releaseChannel: LungfishReleaseChannel

    public var isDebug: Bool { releaseChannel == .debug }
    public var isPreview: Bool { releaseChannel == .preview }
    public var previewCaveat: String? { isPreview ? Self.previewCaveatText : nil }

    public var applicationSupportDirectoryName: String { isDebug ? "Lungfish Debug" : "Lungfish" }
    public var logDirectoryName: String { applicationSupportDirectoryName }
    public var cacheDirectoryName: String { isDebug ? "com.lungfish.debug" : "com.lungfish" }
    public var containerCacheDirectoryName: String {
        isDebug ? "com.lungfish.debug.containers" : "com.lungfish.containers"
    }
    public var temporaryDirectoryName: String { cacheDirectoryName }
    public var managedStorageConfigDirectoryName: String { isDebug ? "lungfish-debug" : "lungfish" }
    public var managedStorageDirectoryName: String { isDebug ? ".lungfish-debug" : ".lungfish" }
    public var keychainService: String { isDebug ? "com.lungfish.secrets.debug" : "com.lungfish.secrets" }

    public func nextflowHomeURL(homeDirectory: URL) -> URL {
        guard isDebug else {
            return homeDirectory.appendingPathComponent(".nextflow", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
            .appendingPathComponent("nextflow", isDirectory: true)
    }

    /// The runtime identity for an app bundle. Command-line and test processes
    /// have no app plist and retain the historical Stable defaults.
    public static var current: Self {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return .stable
        }
        do {
            return try from(infoDictionary: Bundle.main.infoDictionary)
        } catch {
            preconditionFailure("Lungfish app bundle has unknown identity metadata")
        }
    }

    public static func from(infoDictionary: [String: Any]?) throws -> Self {
        guard
            let fullName = infoDictionary?["CFBundleDisplayName"] as? String,
            let shortName = infoDictionary?["CFBundleName"] as? String,
            let bundleIdentifier = infoDictionary?["CFBundleIdentifier"] as? String,
            let rawChannel = infoDictionary?["LungfishReleaseChannel"] as? String,
            let channel = LungfishReleaseChannel(rawValue: rawChannel)
        else {
            throw LungfishAppIdentityError.invalidMetadata
        }

        let candidate: Self
        switch channel {
        case .debug:
            candidate = .debug
        case .preview:
            candidate = .preview
        case .stable:
            candidate = .stable
        }
        guard
            fullName == candidate.fullName,
            shortName == candidate.shortName,
            bundleIdentifier == candidate.bundleIdentifier
        else {
            throw LungfishAppIdentityError.invalidMetadata
        }
        return candidate
    }
}
