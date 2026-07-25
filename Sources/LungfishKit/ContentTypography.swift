import AppKit
import LungfishCore

/// Owns one block-based notification registration and cancels it when released.
///
/// Keeping removal in this RAII token prevents short-lived typography models
/// and monitors from leaving no-op block registrations in NotificationCenter.
@MainActor
final class ContentTypographyNotificationObservation {
    private var cancellation: (@MainActor () -> Void)?

    init(_ cancellation: @escaping @MainActor () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        guard let cancellation else { return }
        self.cancellation = nil
        cancellation()
    }

    isolated deinit {
        cancellation?()
    }
}

@MainActor
protocol ContentTypographyNotificationObserving: AnyObject {
    func observe(
        _ name: Notification.Name,
        using handler: @escaping @MainActor () -> Void
    ) -> ContentTypographyNotificationObservation

    func post(_ name: Notification.Name)
}

@MainActor
final class NotificationCenterContentTypographyNotifications:
    ContentTypographyNotificationObserving
{
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func observe(
        _ name: Notification.Name,
        using handler: @escaping @MainActor () -> Void
    ) -> ContentTypographyNotificationObservation {
        let token = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        return ContentTypographyNotificationObservation { [notificationCenter] in
            notificationCenter.removeObserver(token)
        }
    }

    func post(_ name: Notification.Name) {
        notificationCenter.post(name: name, object: nil)
    }
}

/// Supplies semantic preferred fonts so tests and the System-mode refresh
/// monitor can inject deterministic font metrics.
@MainActor
public protocol ContentPreferredFontProviding {
    func preferredFont(for role: ContentTypography.Role) -> NSFont
    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat
}

public extension ContentPreferredFontProviding {
    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        switch role {
        case .caption:
            return NSFont.smallSystemFontSize
        default:
            return NSFont.systemFontSize
        }
    }
}

@MainActor
public struct AppKitContentPreferredFontProvider: ContentPreferredFontProviding {
    public init() {}

    public func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .body:
            return .preferredFont(forTextStyle: .body)
        case .emphasizedBody:
            return convertedToBold(.preferredFont(forTextStyle: .body))
        case .detail:
            return .preferredFont(forTextStyle: .callout)
        case .caption:
            return .preferredFont(forTextStyle: .caption1)
        case .monospaced:
            let body = NSFont.preferredFont(forTextStyle: .body)
            return .monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        case .tableHeader:
            return convertedToBold(.preferredFont(forTextStyle: .subheadline))
        }
    }

    private func convertedToBold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}

/// Resolves semantic content fonts and adaptive table geometry from a stable
/// preferred-font baseline. Every resolution starts from the provider, so
/// repeated preference changes cannot compound scaling.
@MainActor
public struct ContentTypography {
    public enum Role: String, CaseIterable, Sendable {
        case body
        case emphasizedBody
        case detail
        case caption
        case monospaced
        case tableHeader
    }

    public static let minimumPointSize: CGFloat = 10

    public let preference: ContentTextSizePreference
    private let preferredFontProvider: any ContentPreferredFontProviding

    public init(
        preference: ContentTextSizePreference,
        preferredFontProvider: any ContentPreferredFontProviding = AppKitContentPreferredFontProvider()
    ) {
        self.preference = preference.normalized
        self.preferredFontProvider = preferredFontProvider
    }

    public static func current(
        settings: AppSettings = .shared,
        preferredFontProvider: any ContentPreferredFontProviding = AppKitContentPreferredFontProvider()
    ) -> Self {
        ContentTypographySystemMonitor.shared.start()
        return Self(
            preference: settings.contentTextSizePreference,
            preferredFontProvider: preferredFontProvider
        )
    }

    public func font(for role: Role) -> NSFont {
        let baseline = preferredFontProvider.preferredFont(for: role)
        let resolvedSize = max(
            Self.minimumPointSize,
            baseline.pointSize * CGFloat(preference.scaleFactor)
        )
        return NSFont(descriptor: baseline.fontDescriptor, size: resolvedSize) ?? baseline
    }

    public func tableRowHeight(
        minimum: CGFloat = 22,
        verticalPadding: CGFloat = 6
    ) -> CGFloat {
        max(minimum, ceil(font(for: .body).boundingRectForFont.height + verticalPadding))
    }

    public func tableHeaderHeight(
        minimum: CGFloat = 24,
        verticalPadding: CGFloat = 7
    ) -> CGFloat {
        max(minimum, ceil(font(for: .tableHeader).boundingRectForFont.height + verticalPadding))
    }

    fileprivate var preferredFontSignature: ContentPreferredFontSignature {
        ContentPreferredFontSignature(fonts: Role.allCases.map {
            let font = preferredFontProvider.preferredFont(for: $0)
            return .init(
                role: $0,
                postscriptName: font.fontName,
                pointSize: font.pointSize,
                symbolicTraits: font.fontDescriptor.symbolicTraits.rawValue
            )
        })
    }
}

private struct ContentPreferredFontSignature: Equatable {
    struct Font: Equatable {
        let role: ContentTypography.Role
        let postscriptName: String
        let pointSize: CGFloat
        let symbolicTraits: UInt32
    }

    let fonts: [Font]
}

/// Watches application activation for semantic preferred-font changes that
/// AppKit can expose while the user has selected System content sizing.
@MainActor
public final class ContentTypographySystemMonitor {
    public static let shared = ContentTypographySystemMonitor()

    private let notifications: any ContentTypographyNotificationObserving
    private let preferenceProvider: @MainActor () -> ContentTextSizePreference
    private let preferredFontProvider: any ContentPreferredFontProviding
    private var lastSignature: ContentPreferredFontSignature
    private var activationObservation: ContentTypographyNotificationObservation?
    private var contentSizeObservation: ContentTypographyNotificationObservation?

    public convenience init(
        notificationCenter: NotificationCenter = .default,
        preferenceProvider: @escaping @MainActor () -> ContentTextSizePreference = {
            AppSettings.shared.contentTextSizePreference
        },
        preferredFontProvider: any ContentPreferredFontProviding = AppKitContentPreferredFontProvider()
    ) {
        self.init(
            notifications: NotificationCenterContentTypographyNotifications(
                notificationCenter: notificationCenter
            ),
            preferenceProvider: preferenceProvider,
            preferredFontProvider: preferredFontProvider
        )
    }

    init(
        notifications: any ContentTypographyNotificationObserving,
        preferenceProvider: @escaping @MainActor () -> ContentTextSizePreference,
        preferredFontProvider: any ContentPreferredFontProviding
    ) {
        self.notifications = notifications
        self.preferenceProvider = preferenceProvider
        self.preferredFontProvider = preferredFontProvider
        self.lastSignature = ContentTypography(
            preference: .system,
            preferredFontProvider: preferredFontProvider
        ).preferredFontSignature
    }

    public func start() {
        guard activationObservation == nil, contentSizeObservation == nil else {
            return
        }
        activationObservation = notifications.observe(
            NSApplication.didBecomeActiveNotification
        ) { [weak self] in
            self?.refreshAfterApplicationActivation()
        }
        contentSizeObservation = notifications.observe(
            .contentTextSizeDidChange
        ) { [weak self] in
            self?.synchronizePreferredFontSignature()
        }
    }

    public func stop() {
        activationObservation?.cancel()
        activationObservation = nil
        contentSizeObservation?.cancel()
        contentSizeObservation = nil
    }

    public func refreshAfterApplicationActivation() {
        let signature = ContentTypography(
            preference: .system,
            preferredFontProvider: preferredFontProvider
        ).preferredFontSignature
        guard preferenceProvider().normalized == .system else {
            lastSignature = signature
            return
        }
        guard signature != lastSignature else { return }
        lastSignature = signature
        notifications.post(.contentTextSizeDidChange)
    }

    private func synchronizePreferredFontSignature() {
        lastSignature = ContentTypography(
            preference: .system,
            preferredFontProvider: preferredFontProvider
        ).preferredFontSignature
    }
}
