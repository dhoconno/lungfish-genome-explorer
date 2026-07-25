import AppKit
import LungfishCore
import Observation
import SwiftUI

/// Observable bridge between the narrow content-size notification and SwiftUI.
@Observable
@MainActor
public final class ContentTypographyModel {
    public static let shared: ContentTypographyModel = {
        ContentTypographySystemMonitor.shared.start()
        return ContentTypographyModel()
    }()

    public private(set) var typography: ContentTypography

    private let notifications: any ContentTypographyNotificationObserving
    private let preferenceProvider: @MainActor () -> ContentTextSizePreference
    private let preferredFontProvider: any ContentPreferredFontProviding
    private var notificationObservation: ContentTypographyNotificationObservation?

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
        self.typography = ContentTypography(
            preference: preferenceProvider(),
            preferredFontProvider: preferredFontProvider
        )
        notificationObservation = notifications.observe(
            .contentTextSizeDidChange
        ) { [weak self] in
            self?.refresh()
        }
    }

    public func refresh() {
        typography = ContentTypography(
            preference: preferenceProvider(),
            preferredFontProvider: preferredFontProvider
        )
    }

    public func resolvedNSFont(for role: ContentTypography.Role) -> NSFont {
        typography.font(for: role)
    }

    public func font(for role: ContentTypography.Role) -> SwiftUI.Font {
        SwiftUI.Font(resolvedNSFont(for: role))
    }

    /// Resolves a stable fixed-size content baseline through the same live
    /// System/custom scale used by AppKit result content.
    public func scaledPointSize(fromCanonicalPointSize pointSize: CGFloat) -> CGFloat {
        let canonicalBodySize = max(
            preferredFontProvider.canonicalUnscaledPointSize(for: .body),
            1
        )
        let contentScale = resolvedNSFont(for: .body).pointSize / canonicalBodySize
        return max(ContentTypography.minimumPointSize, pointSize * contentScale)
    }
}

private struct ContentTypographyFontModifier: ViewModifier {
    @State var model: ContentTypographyModel
    let role: ContentTypography.Role

    func body(content: Content) -> some View {
        content.font(model.font(for: role))
    }
}

public extension View {
    /// Applies a live-updating semantic Lungfish content font.
    @MainActor
    func contentTypographyFont(
        _ role: ContentTypography.Role,
        model: ContentTypographyModel = .shared
    ) -> some View {
        modifier(ContentTypographyFontModifier(model: model, role: role))
    }
}
