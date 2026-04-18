import Foundation

@MainActor
enum MetagenomicsPanelLayout: String, CaseIterable, Sendable {
    case detailLeading
    case listLeading
    case stacked

    static let defaultsKey = "metagenomicsPanelLayout"
    static let legacyTableOnLeftKey = "metagenomicsTableOnLeft"

    static func current(defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.string(forKey: defaultsKey),
           let value = Self(rawValue: raw) {
            return value
        }

        return defaults.bool(forKey: legacyTableOnLeftKey) ? .listLeading : .detailLeading
    }

    func persist(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        notificationCenter.post(name: .metagenomicsLayoutSwapRequested, object: nil)
    }
}
