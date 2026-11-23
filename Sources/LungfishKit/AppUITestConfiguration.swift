import Foundation

public enum AppUITestBackendMode: String, Equatable, Sendable {
    case deterministic
    case liveSmoke = "live-smoke"
}

public struct AppUITestConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let scenarioName: String?
    public let projectPath: URL?
    public let mappingResultPath: URL?
    public let welcomeOpenProjectPath: URL?
    public let welcomeCreateProjectPath: URL?
    public let eventLogPath: URL?
    public let fixtureRootPath: URL?
    public let backendMode: AppUITestBackendMode
    /// Where view memory lives in UI-test mode for a launch whose home is not isolated (VS Q3): the folder that
    /// `LUNGFISH_UI_TEST_VIEW_STATE_PATH` names, or a temporary folder of this process that starts empty. Nil outside
    /// UI-test mode and under an isolated home, whose default path the smoke's relaunch task reads.
    public let viewStatePath: URL?

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
        mappingResultPath = Self.resolvePath(
            Self.nonEmptyPath(
                enabled ? environment["LUNGFISH_UI_TEST_MAPPING_RESULT_PATH"] : nil
            ),
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
        viewStatePath = enabled && !Self.homeIsIsolated(environment)
            ? Self.resolvePath(
                Self.nonEmptyPath(environment["LUNGFISH_UI_TEST_VIEW_STATE_PATH"]),
                fixtureRootPath: fixtureRootPath,
                isDirectory: true
            ) ?? Self.temporaryViewStatePath
            : nil
    }

    /// The temporary view memory folder of this process, which starts empty.
    private static let temporaryViewStatePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("lungfish-ui-test-view-state-\(UUID().uuidString)", isDirectory: true)

    /// Whether `HOME` or `CFFIXED_USER_HOME` names a home other than the account's own, as each smoke test's isolated
    /// home does.
    static func homeIsIsolated(_ environment: [String: String]) -> Bool {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return false }
        let accountHome = URL(fileURLWithPath: String(cString: directory)).standardizedFileURL.path
        return ["CFFIXED_USER_HOME", "HOME"].contains { name in
            guard let value = environment[name], !value.isEmpty else { return false }
            return URL(fileURLWithPath: value).standardizedFileURL.path != accountHome
        }
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

    private static func nonEmptyPath(_ rawPath: String?) -> String? {
        guard let rawPath,
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return rawPath
    }
}
