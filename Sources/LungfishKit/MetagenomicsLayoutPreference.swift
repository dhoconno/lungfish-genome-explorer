import Foundation

public extension Notification.Name {
    /// Posted when the persisted metagenomics panel layout preference changes.
    static let metagenomicsLayoutSwapRequested = Notification.Name("com.lungfish.metagenomicsLayoutSwapRequested")

    /// Posted when sample selection changes in the Inspector-embedded sample picker.
    /// Shared across every metagenomics result view controller (Taxonomy, NAO-MGS,
    /// TaxTriage, EsViritu, NVD) so it lives in the kernel rather than any one leaf.
    static let metagenomicsSampleSelectionChanged = Notification.Name("com.lungfish.metagenomicsSampleSelectionChanged")
}

@MainActor
public enum MetagenomicsPanelLayout: String, CaseIterable, Sendable {
    case detailLeading
    case listLeading
    case stacked

    public nonisolated static let defaultsKey = "metagenomicsPanelLayout"
    public nonisolated static let legacyTableOnLeftKey = "metagenomicsTableOnLeft"

    public static func current(defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.string(forKey: defaultsKey),
           let value = Self(rawValue: raw) {
            return value
        }

        return defaults.bool(forKey: legacyTableOnLeftKey) ? .listLeading : .detailLeading
    }

    public func persist(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
        // Temporary compatibility for Task 3: controllers still read the legacy
        // bool, so keep it mirrored while the enum remains the source of truth.
        defaults.set(self == .listLeading, forKey: Self.legacyTableOnLeftKey)
        notificationCenter.post(name: .metagenomicsLayoutSwapRequested, object: nil)
    }
}
