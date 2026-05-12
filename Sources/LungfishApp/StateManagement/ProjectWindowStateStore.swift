import Foundation

public struct CodableWindowFrame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RestorableContentState: Codable, Hashable, Sendable {
    public var kind: String
    public var url: URL?
    public var payload: [String: String]

    public init(kind: String, url: URL?, payload: [String: String] = [:]) {
        self.kind = kind
        self.url = url
        self.payload = payload
    }
}

public struct ProjectWindowSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var projectURL: URL
    public var windowOrdinal: Int
    public var windowOrder: Int
    public var windowTitleSuffix: String?
    public var frame: CodableWindowFrame?
    public var isFullScreen: Bool
    public var selectedSidebarURL: URL?
    public var expandedSidebarURLs: [URL]
    public var sidebarSearchText: String?
    public var activeContent: RestorableContentState?
    public var inspectorTab: String?
    public var sidebarCollapsed: Bool
    public var inspectorCollapsed: Bool
    public var sidebarWidth: Double?
    public var inspectorWidth: Double?
    public var operationsPanelFilter: String?
    public var operationsPanelVisible: Bool

    public init(
        id: UUID,
        projectURL: URL,
        windowOrdinal: Int,
        windowOrder: Int,
        windowTitleSuffix: String?,
        frame: CodableWindowFrame?,
        isFullScreen: Bool,
        selectedSidebarURL: URL?,
        expandedSidebarURLs: [URL],
        sidebarSearchText: String?,
        activeContent: RestorableContentState?,
        inspectorTab: String?,
        sidebarCollapsed: Bool,
        inspectorCollapsed: Bool,
        sidebarWidth: Double?,
        inspectorWidth: Double?,
        operationsPanelFilter: String?,
        operationsPanelVisible: Bool
    ) {
        self.id = id
        self.projectURL = projectURL.standardizedFileURL
        self.windowOrdinal = windowOrdinal
        self.windowOrder = windowOrder
        self.windowTitleSuffix = windowTitleSuffix
        self.frame = frame
        self.isFullScreen = isFullScreen
        self.selectedSidebarURL = selectedSidebarURL?.standardizedFileURL
        self.expandedSidebarURLs = expandedSidebarURLs.map(\.standardizedFileURL)
        self.sidebarSearchText = sidebarSearchText
        self.activeContent = activeContent
        self.inspectorTab = inspectorTab
        self.sidebarCollapsed = sidebarCollapsed
        self.inspectorCollapsed = inspectorCollapsed
        self.sidebarWidth = sidebarWidth
        self.inspectorWidth = inspectorWidth
        self.operationsPanelFilter = operationsPanelFilter
        self.operationsPanelVisible = operationsPanelVisible
    }
}

public struct ProjectWindowStateEnvelope: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var savedAt: Date
    public var windows: [ProjectWindowSnapshot]

    public init(schemaVersion: Int = 1, savedAt: Date = Date(), windows: [ProjectWindowSnapshot]) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.windows = windows
    }
}

public final class ProjectWindowStateStore {
    public let stateURL: URL
    private let fileManager: FileManager

    public init(
        stateURL: URL = ProjectWindowStateStore.defaultStateURL(),
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.fileManager = fileManager
    }

    public static func defaultStateURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Lungfish", isDirectory: true)
            .appendingPathComponent("window-state.json", isDirectory: false)
    }

    public func load() throws -> ProjectWindowStateEnvelope {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return ProjectWindowStateEnvelope(windows: [])
        }

        let data = try Data(contentsOf: stateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ProjectWindowStateEnvelope.self, from: data)
        guard envelope.schemaVersion == 1 else {
            return ProjectWindowStateEnvelope(windows: [])
        }
        return envelope
    }

    public func save(_ envelope: ProjectWindowStateEnvelope) throws {
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: stateURL, options: [.atomic])
    }
}
