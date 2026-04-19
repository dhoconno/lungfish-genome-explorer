import Foundation

enum AppUITestBackendMode: String, Equatable, Sendable {
    case deterministic
    case liveSmoke = "live-smoke"
}

struct AppUITestConfiguration: Equatable, Sendable {
    let isEnabled: Bool
    let scenarioName: String?
    let projectPath: URL?
    let welcomeOpenProjectPath: URL?
    let welcomeCreateProjectPath: URL?
    let eventLogPath: URL?
    let fixtureRootPath: URL?
    let backendMode: AppUITestBackendMode

    init(arguments: [String], environment: [String: String]) {
        let explicitFlag = arguments.contains("--ui-test-mode")
        let environmentFlag = environment["LUNGFISH_UI_TEST_MODE"] == "1"

        isEnabled = explicitFlag || environmentFlag
        scenarioName = environment["LUNGFISH_UI_TEST_SCENARIO"]
        fixtureRootPath = environment["LUNGFISH_UI_TEST_FIXTURE_ROOT"].map(URL.init(fileURLWithPath:))
        projectPath = Self.resolvePath(
            environment["LUNGFISH_UI_TEST_PROJECT_PATH"],
            fixtureRootPath: fixtureRootPath,
            isDirectory: true
        )
        welcomeOpenProjectPath = Self.resolvePath(
            environment["LUNGFISH_UI_TEST_WELCOME_OPEN_PROJECT_PATH"],
            fixtureRootPath: fixtureRootPath,
            isDirectory: true
        )
        welcomeCreateProjectPath = Self.resolvePath(
            environment["LUNGFISH_UI_TEST_WELCOME_CREATE_PROJECT_PATH"],
            fixtureRootPath: fixtureRootPath,
            isDirectory: true
        )
        eventLogPath = Self.resolvePath(
            environment["LUNGFISH_UI_TEST_EVENT_LOG_PATH"],
            fixtureRootPath: fixtureRootPath,
            isDirectory: false
        )
        backendMode = AppUITestBackendMode(
            rawValue: environment["LUNGFISH_UI_TEST_BACKEND_MODE"] ?? ""
        ) ?? .deterministic
    }

    func appendEvent(_ event: String) {
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

    static let current = AppUITestConfiguration(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )

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
