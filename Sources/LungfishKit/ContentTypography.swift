import AppKit
import LungfishCore

/// Supplies semantic preferred fonts so tests and the System-mode refresh
/// monitor can inject deterministic font metrics.
@MainActor
public protocol ContentPreferredFontProviding {
    func preferredFont(for role: ContentTypography.Role) -> NSFont
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

    private let notificationCenter: NotificationCenter
    private let preferenceProvider: @MainActor () -> ContentTextSizePreference
    private let preferredFontProvider: any ContentPreferredFontProviding
    private var lastSignature: ContentPreferredFontSignature
    private var activationObserver: NSObjectProtocol?

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
        self.lastSignature = ContentTypography(
            preference: .system,
            preferredFontProvider: preferredFontProvider
        ).preferredFontSignature
    }

    public func start() {
        guard activationObserver == nil else { return }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAfterApplicationActivation()
            }
        }
    }

    public func stop() {
        guard let activationObserver else { return }
        notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    public func refreshAfterApplicationActivation() {
        guard preferenceProvider().normalized == .system else { return }
        let signature = ContentTypography(
            preference: .system,
            preferredFontProvider: preferredFontProvider
        ).preferredFontSignature
        guard signature != lastSignature else { return }
        lastSignature = signature
        notificationCenter.post(name: .contentTextSizeDidChange, object: nil)
    }
}
