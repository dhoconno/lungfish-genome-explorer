import AppKit
import LungfishCore
import LungfishIO

/// Window-owned, bundle-keyed presentation state. A viewer keeps one instance
/// for its lifetime and shares it with replacement result controllers.
@MainActor
public final class GenotypeManualHaplotypeBandDisclosureStore {
    private var expansionByBundlePath: [String: Bool] = [:]

    public init() {}

    public func expansion(for bundleURL: URL) -> Bool? {
        expansionByBundlePath[bundleURL.standardizedFileURL.path]
    }

    public func setExpansion(_ expanded: Bool, for bundleURL: URL) {
        expansionByBundlePath[bundleURL.standardizedFileURL.path] = expanded
    }
}
