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

    private let notificationCenter: NotificationCenter
    private let preferenceProvider: @MainActor () -> ContentTextSizePreference
    private let preferredFontProvider: any ContentPreferredFontProviding
    private var notificationObserver: NSObjectProtocol?

    public init(
        notificationCenter: NotificationCenter = .default,
        preferenceProvider: @escaping @MainActor () -> ContentTextSizePreference = {
            AppSettings.shared.contentTextSizePreference
        },
        preferredFontProvider: any ContentPreferredFontProviding = AppKitContentPreferredFontProvider()
    ) {
        self.notificationCenter = notificationCenter
        self.preferenceProvider = preferenceProvider
        self.preferredFontProvider = preferredFontProvider
        self.typography = ContentTypography(
            preference: preferenceProvider(),
            preferredFontProvider: preferredFontProvider
        )
        notificationObserver = notificationCenter.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
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
