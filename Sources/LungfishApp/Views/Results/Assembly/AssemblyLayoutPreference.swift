import Foundation

@MainActor
enum AssemblyPanelLayout: String, CaseIterable, Sendable {
    case detailLeading
    case listLeading
    case stacked

    static let defaultsKey = "assemblyPanelLayout"

    static func current(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = Self(rawValue: raw) else {
            return .detailLeading
        }
        return value
    }

    func persist(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        notificationCenter.post(name: .assemblyLayoutSwapRequested, object: nil)
    }
}
