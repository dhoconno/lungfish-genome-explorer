import Foundation
import CoreFoundation
import MachO

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

    /// A validated base namespace; channels always receive separate state.
    public let runtimeNamespace: String?
    private let configuredWebsiteURL: URL?
    private let configuredDocumentationURL: URL?
    private let configuredReleaseHistoryURL: URL?

    private init(fullName: String, shortName: String, bundleIdentifier: String,
                 releaseChannel: LungfishReleaseChannel, runtimeNamespace: String? = nil,
                 websiteURL: URL? = nil, documentationURL: URL? = nil, releaseHistoryURL: URL? = nil) {
        self.fullName = fullName
        self.shortName = shortName
        self.bundleIdentifier = bundleIdentifier
        self.releaseChannel = releaseChannel
        self.runtimeNamespace = runtimeNamespace
        self.configuredWebsiteURL = websiteURL
        self.configuredDocumentationURL = documentationURL
        self.configuredReleaseHistoryURL = releaseHistoryURL
    }

    public var isFork: Bool { runtimeNamespace != nil }
    public var effectiveRuntimeNamespace: String? { runtimeNamespace.map { "\($0).\(releaseChannel.rawValue)" } }
    public var allowsUpstreamLegacyMigration: Bool { !isFork && !isDebug }
    public var isDebug: Bool { releaseChannel == .debug }
    public var isPreview: Bool { releaseChannel == .preview }
    public var previewCaveat: String? { isPreview ? Self.previewCaveatText : nil }
    public var websiteURL: URL? {
        configuredWebsiteURL ?? (isFork ? nil : URL(string: "https://dho.pathology.wisc.edu"))
    }
    public var documentationURL: URL? {
        configuredDocumentationURL ?? (isFork ? nil : URL(string: "https://lungfish-genome-explorer.readthedocs.io/en/latest/"))
    }
    public var releaseHistoryURL: URL? {
        configuredReleaseHistoryURL ?? (isFork ? nil : URL(string: "https://github.com/dhoconno/lungfish-genome-explorer/releases"))
    }
    public var cliInformationURL: URL? {
        isFork ? (documentationURL ?? websiteURL ?? releaseHistoryURL)
            : URL(string: "https://github.com/dhoconno/lungfish-genome-explorer")
    }
    public var helpBookName: String { isFork ? "\(fullName) Help" : "Lungfish Genome Explorer Help" }

    /// An explicit suite must not equal the process's own bundle identifier.
    /// Fork GUI and CLI share this separate domain for their selected channel.
    public var preferencesSuiteName: String? {
        effectiveRuntimeNamespace.map { "\($0).preferences" }
    }

    public var preferences: UserDefaults {
        guard let namespace = preferencesSuiteName else { return .standard }
        guard let defaults = UserDefaults(suiteName: namespace) else {
            preconditionFailure("Unable to open validated fork preference domain")
        }
        return defaults
    }

    public var applicationSupportDirectoryName: String { effectiveRuntimeNamespace ?? (isDebug ? "Lungfish Debug" : "Lungfish") }
    public var logDirectoryName: String { applicationSupportDirectoryName }
    public var cacheDirectoryName: String { effectiveRuntimeNamespace ?? (isDebug ? "com.lungfish.debug" : "com.lungfish") }
    public var containerCacheDirectoryName: String {
        effectiveRuntimeNamespace.map { "\($0).containers" } ?? (isDebug ? "com.lungfish.debug.containers" : "com.lungfish.containers")
    }
    public var temporaryDirectoryName: String { cacheDirectoryName }
    public var managedStorageConfigDirectoryName: String { effectiveRuntimeNamespace ?? (isDebug ? "lungfish-debug" : "lungfish") }
    public var managedStorageDirectoryName: String { effectiveRuntimeNamespace.map { ".\($0)" } ?? (isDebug ? ".lungfish-debug" : ".lungfish") }
    public var keychainService: String { effectiveRuntimeNamespace.map { "\($0).secrets" } ?? (isDebug ? "com.lungfish.secrets.debug" : "com.lungfish.secrets") }

    public func nextflowHomeURL(homeDirectory: URL) -> URL {
        guard isDebug || isFork else {
            return homeDirectory.appendingPathComponent(".nextflow", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
            .appendingPathComponent("nextflow", isDirectory: true)
    }

    public static let current: Self = {
        do { return try RuntimeAppIdentityResolver.current() }
        catch { preconditionFailure("Lungfish executable has invalid or conflicting identity metadata") }
    }()

    public static func from(infoDictionary: [String: Any]?) throws -> Self {
        guard let info = infoDictionary,
              let fullName = info["CFBundleDisplayName"] as? String,
              let shortName = info["CFBundleName"] as? String,
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              let rawChannel = info["LungfishReleaseChannel"] as? String,
              let channel = LungfishReleaseChannel(rawValue: rawChannel)
        else { throw LungfishAppIdentityError.invalidMetadata }

        let website = try productURL(info, key: "LungfishWebsiteURL")
        let documentation = try productURL(info, key: "LungfishDocumentationURL")
        let history = try productURL(info, key: "LungfishReleaseHistoryURL")
        if info["LungfishIdentitySchemaVersion"] != nil || info["LungfishRuntimeNamespace"] != nil {
            guard let schema = info["LungfishIdentitySchemaVersion"] as? NSNumber,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(),
                  String(cString: schema.objCType) != "d", String(cString: schema.objCType) != "f",
                  schema.intValue == 1,
                  let namespace = info["LungfishRuntimeNamespace"] as? String,
                  validNamespace(namespace), validNamespace(bundleIdentifier),
                  validName(fullName), validName(shortName)
            else { throw LungfishAppIdentityError.invalidMetadata }
            return Self(fullName: fullName, shortName: shortName, bundleIdentifier: bundleIdentifier,
                        releaseChannel: channel, runtimeNamespace: namespace,
                        websiteURL: website, documentationURL: documentation, releaseHistoryURL: history)
        }
        let candidate: Self
        switch channel {
        case .debug: candidate = .debug
        case .preview: candidate = .preview
        case .stable: candidate = .stable
        }
        guard fullName == candidate.fullName, shortName == candidate.shortName,
              bundleIdentifier == candidate.bundleIdentifier else {
            throw LungfishAppIdentityError.invalidMetadata
        }
        if website == nil && documentation == nil && history == nil { return candidate }
        return Self(fullName: fullName, shortName: shortName, bundleIdentifier: bundleIdentifier,
                    releaseChannel: channel, websiteURL: website, documentationURL: documentation,
                    releaseHistoryURL: history)
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.contains("$(") && !value.contains("${")
    }

    private static func validNamespace(_ value: String) -> Bool {
        guard value.utf8.count <= 180,
              value.range(of: "^[a-z][a-z0-9-]*(\\.[a-z][a-z0-9-]*)+$", options: .regularExpression) != nil
        else { return false }
        return !["com.lungfish", "org.lungfish"].contains { value == $0 || value.hasPrefix($0 + ".") }
    }

    private static func productURL(_ info: [String: Any], key: String) throws -> URL? {
        guard let raw = info[key] else { return nil }
        guard let text = raw as? String, text.utf8.count <= 2048,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: text), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url else { throw LungfishAppIdentityError.invalidMetadata }
        return url
    }
}

/// Pure dictionary resolution keeps CLI identity checks testable without globals.
enum RuntimeAppIdentityResolver {
    static func resolve(mainAppInfo: [String: Any]? = nil,
                        embeddedExecutableInfo: [String: Any]? = nil,
                        enclosingAppInfo: [String: Any]? = nil) throws -> LungfishAppIdentity {
        if let mainAppInfo { return try LungfishAppIdentity.from(infoDictionary: mainAppInfo) }
        let embedded = try embeddedExecutableInfo.map { try LungfishAppIdentity.from(infoDictionary: $0) }
        let enclosing = try enclosingAppInfo.map { try LungfishAppIdentity.from(infoDictionary: $0) }
        if let enclosing {
            if let embedded {
                guard embedded == enclosing else { throw LungfishAppIdentityError.invalidMetadata }
            } else if enclosing.isFork { throw LungfishAppIdentityError.invalidMetadata }
        }
        // Historical upstream command-line processes keep Stable state, including
        // a CLI run from an upstream Debug/Preview app. Forks never take this path.
        return embedded?.isFork == true ? embedded! : .stable
    }

    static func current() throws -> LungfishAppIdentity {
        let executable = _dyld_get_image_name(0).map {
            URL(fileURLWithPath: String(cString: $0)).resolvingSymlinksInPath().standardizedFileURL
        }
        if Bundle.main.bundleURL.pathExtension == "app",
           let name = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String,
           executable?.lastPathComponent == name {
            return try resolve(mainAppInfo: Bundle.main.infoDictionary ?? [:])
        }
        let section = try embeddedInfoDictionary()
        // A library can run in a host such as Apple's xctest, which has its own
        // unrelated __info_plist. Only identity-bearing metadata (or our CLI's
        // required section) participates in Lungfish identity resolution.
        let hasIdentity = section.map { info in
            ["LungfishReleaseChannel", "LungfishRuntimeNamespace", "LungfishIdentitySchemaVersion"]
                .contains { info[$0] != nil }
        } ?? false
        let embedded = hasIdentity || executable?.lastPathComponent == "lungfish-cli" ? section : nil
        let enclosing = try executable.flatMap { try enclosingAppInfo(executableURL: $0) }
        return try resolve(embeddedExecutableInfo: embedded, enclosingAppInfo: enclosing)
    }

    static func enclosingAppInfo(executableURL: URL) throws -> [String: Any]? {
        let executable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" {
                // App executables live in Contents/MacOS. Tools inside a host
                // IDE's Contents/Developer tree are independent command tools.
                guard executable.path.hasPrefix(directory.appendingPathComponent("Contents/MacOS").path + "/") else {
                    return nil
                }
                let data = try Data(contentsOf: directory.appendingPathComponent("Contents/Info.plist"))
                guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw LungfishAppIdentityError.invalidMetadata
                }
                return info
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func embeddedInfoDictionary() throws -> [String: Any]? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        guard header.pointee.magic == MH_MAGIC_64 else { throw LungfishAppIdentityError.invalidMetadata }
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0
        guard let bytes = getsectiondata(header64, "__TEXT", "__info_plist", &size) else { return nil }
        guard size > 0, size <= 65_536 else { throw LungfishAppIdentityError.invalidMetadata }
        let data = Data(bytes: bytes, count: Int(size))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LungfishAppIdentityError.invalidMetadata
        }
        return info
    }
}
