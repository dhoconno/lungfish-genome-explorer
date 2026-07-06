import Foundation

public enum AppUITestBackendMode: String, Equatable, Sendable {
    case deterministic
    case liveSmoke = "live-smoke"
}

public struct AppUITestConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let scenarioName: String?
    public let projectPath: URL?
    public let welcomeOpenProjectPath: URL?
    public let welcomeCreateProjectPath: URL?
    public let eventLogPath: URL?
    public let fixtureRootPath: URL?
    public let backendMode: AppUITestBackendMode

    public init(arguments: [String], environment: [String: String]) {
        self.init(
            arguments: arguments,
            environment: environment,
            allowsUITestMode: Self.buildAllowsUITestMode
        )
    }

    public init(
        arguments: [String],
        environment: [String: String],
        allowsUITestMode: Bool
    ) {
        let explicitFlag = arguments.contains("--ui-test-mode")
        let environmentFlag = environment["LUNGFISH_UI_TEST_MODE"] == "1"
        let enabled = allowsUITestMode && (explicitFlag || environmentFlag)

        isEnabled = enabled
        scenarioName = enabled ? environment["LUNGFISH_UI_TEST_SCENARIO"] : nil
        fixtureRootPath = enabled
            ? environment["LUNGFISH_UI_TEST_FIXTURE_ROOT"].map(URL.init(fileURLWithPath:))
            : nil
        projectPath = Self.resolvePath(
            enabled ? environment["LUNGFISH_UI_TEST_PROJECT_PATH"] : nil,
            fixtureRootPath: fixtureRootPath,
            isDirectory: true
        )
        welcomeOpenProjectPath = Self.resolvePath(
            enabled ? environment["LUNGFISH_UI_TEST_WELCOME_OPEN_PROJECT_PATH"] : nil,
            fixtureRootPath: fixtureRootPath,
            isDirectory: true
        )
        welcomeCreateProjectPath = Self.resolvePath(
            enabled ? environment["LUNGFISH_UI_TEST_WELCOME_CREATE_PROJECT_PATH"] : nil,
            fixtureRootPath: fixtureRootPath,
            isDirectory: true
        )
        eventLogPath = Self.resolvePath(
            enabled ? environment["LUNGFISH_UI_TEST_EVENT_LOG_PATH"] : nil,
            fixtureRootPath: fixtureRootPath,
            isDirectory: false
        )
        backendMode = enabled
            ? AppUITestBackendMode(rawValue: environment["LUNGFISH_UI_TEST_BACKEND_MODE"] ?? "") ?? .deterministic
            : .liveSmoke
    }

    public func appendEvent(_ event: String) {
        guard let eventLogPath else { return }

        let line = event + "\n"
        guard let data = line.data(using: .utf8) else { return }

        let fileManager = FileManager.default
        let directoryURL = eventLogPath.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: eventLogPath.path) {
            guard let handle = try? FileHandle(forWritingTo: eventLogPath) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            fileManager.createFile(atPath: eventLogPath.path, contents: data)
        }
    }

    public static let current = AppUITestConfiguration(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

    private static var buildAllowsUITestMode: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func resolvePath(
        _ rawPath: String?,
        fixtureRootPath: URL?,
        isDirectory: Bool
    ) -> URL? {
        guard let rawPath else { return nil }
        if (rawPath as NSString).isAbsolutePath || fixtureRootPath == nil {
            return URL(fileURLWithPath: rawPath)
        }
        return fixtureRootPath?.appendingPathComponent(rawPath, isDirectory: isDirectory)
    }
}
