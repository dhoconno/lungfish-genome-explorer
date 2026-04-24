import Foundation

@MainActor
enum BundleBrowserPanelLayout: String, CaseIterable, Sendable {
    case detailLeading
    case listLeading
    case stacked

    static let defaultsKey = "bundleBrowserPanelLayout"

    static func current(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = Self(rawValue: raw) else {
            return .listLeading
        }
        return value
    }

    func persist(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        notificationCenter.post(name: .bundleBrowserLayoutSwapRequested, object: nil)
    }
}

extension Notification.Name {
    static let bundleBrowserLayoutSwapRequested = Notification.Name("com.lungfish.bundleBrowserLayoutSwapRequested")
}
