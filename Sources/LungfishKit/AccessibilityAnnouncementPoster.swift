import AppKit

public enum ContentAccessibilityAnnouncementPriority: Equatable, Sendable {
    case low
    case medium
    case high

    fileprivate var appKitValue: NSAccessibilityPriorityLevel {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

@MainActor
public protocol AccessibilityAnnouncementPosting {
    func post(_ message: String, priority: ContentAccessibilityAnnouncementPriority)
}

/// Posts VoiceOver announcements, with an injectable handler for deterministic
/// UI action tests.
@MainActor
public struct AccessibilityAnnouncementPoster: AccessibilityAnnouncementPosting {
    public typealias Handler = @MainActor (
        _ message: String,
        _ priority: ContentAccessibilityAnnouncementPriority
    ) -> Void

    private let handler: Handler

    public init() {
        self.handler = Self.postToAppKit
    }

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func post(
        _ message: String,
        priority: ContentAccessibilityAnnouncementPriority = .medium
    ) {
        handler(message, priority)
    }

    private static func postToAppKit(
        _ message: String,
        _ priority: ContentAccessibilityAnnouncementPriority
    ) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.appKitValue.rawValue,
            ]
        )
    }
}
