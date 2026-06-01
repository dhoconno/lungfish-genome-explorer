import Foundation

public extension Notification.Name {
    /// Posted when the persisted assembly panel layout preference changes.
    static let assemblyLayoutSwapRequested = Notification.Name("com.lungfish.assemblyLayoutSwapRequested")
}

@MainActor
public enum AssemblyPanelLayout: String, CaseIterable, Sendable {
    case detailLeading
    case listLeading
    case stacked

    public nonisolated static let defaultsKey = "assemblyPanelLayout"

    public static func current(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = Self(rawValue: raw) else {
            return .detailLeading
        }
        return value
    }

    public func persist(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        notificationCenter.post(name: .assemblyLayoutSwapRequested, object: nil)
    }
}
