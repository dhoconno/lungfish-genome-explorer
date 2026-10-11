import Foundation

/// The view an analyst last chose for a `.lungfishgenotype` result, kept as
/// app state inside the bundle (plan decision S11).
///
/// The file is hidden, so directory digests skip it, and no record names it.
/// The viewer writes it only after a user change, never on open and never
/// when it restores a view. A view switch therefore writes no
/// `annotations.json` and no record. `BundleKindRegistry` declares the file
/// name in the genotype kind's `appStateFileNames`.
///
/// An older sidecar kept these fields in `GenotypeAnnotationSidecar.Settings`.
/// They stay there, decode as before and reach the Excel export record, and a
/// bundle with no app state file opens with them as its starting view without
/// any write on read. Fields that shape an export, such as
/// `genotypeLocusDisplayOrder`, the dropout thresholds and the candidate row
/// display, stay in the sidecar and are recorded.
public struct GenotypeResultViewState: Codable, Equatable, Sendable {
    public static let filename = ".genotype-viewstate.json"

    /// The Haplotype Calls (`outline`) or Genotype Matrix (`matrix`) choice,
    /// or nil for the result's default.
    public var preferredSummaryViewMode: String?
    public var viewMode: String
    public var panelLayout: String
    public var cardDensity: String
    public var cardDensityThreshold: Int

    public init(
        preferredSummaryViewMode: String?,
        viewMode: String,
        panelLayout: String,
        cardDensity: String,
        cardDensityThreshold: Int
    ) {
        self.preferredSummaryViewMode = preferredSummaryViewMode
        self.viewMode = viewMode
        self.panelLayout = panelLayout
        self.cardDensity = cardDensity
        self.cardDensityThreshold = cardDensityThreshold
    }

    /// The starting view of a bundle with no app state file, from the view
    /// fields its sidecar holds.
    public init(startingFrom settings: GenotypeAnnotationSidecar.Settings) {
        self.init(
            preferredSummaryViewMode: settings.preferredSummaryViewMode,
            viewMode: settings.viewMode,
            panelLayout: settings.panelLayout,
            cardDensity: settings.cardDensity,
            cardDensityThreshold: settings.cardDensityThreshold
        )
    }

    private enum CodingKeys: String, CodingKey {
        case preferredSummaryViewMode, viewMode, panelLayout, cardDensity, cardDensityThreshold
    }

    /// A field this build does not know is skipped, and a missing one takes
    /// the sidecar default, so a newer or older file still opens.
    public init(from decoder: Decoder) throws {
        let defaults = GenotypeAnnotationSidecar.Settings.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredSummaryViewMode = try container.decodeIfPresent(String.self, forKey: .preferredSummaryViewMode)
        viewMode = try container.decodeIfPresent(String.self, forKey: .viewMode) ?? defaults.viewMode
        panelLayout = try container.decodeIfPresent(String.self, forKey: .panelLayout) ?? defaults.panelLayout
        cardDensity = try container.decodeIfPresent(String.self, forKey: .cardDensity) ?? defaults.cardDensity
        cardDensityThreshold = try container.decodeIfPresent(Int.self, forKey: .cardDensityThreshold)
            ?? defaults.cardDensityThreshold
    }

    public static func fileURL(forBundleAt bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(filename)
    }

    /// The state the app state file holds, or nil when the bundle has none or
    /// it cannot be read. Reading never writes.
    public static func load(fromBundleAt bundleURL: URL) -> GenotypeResultViewState? {
        guard let data = try? Data(contentsOf: fileURL(forBundleAt: bundleURL)) else { return nil }
        return try? JSONDecoder().decode(GenotypeResultViewState.self, from: data)
    }

    /// The view a bundle opens with, the app state file when it has one and
    /// otherwise the view fields of its sidecar.
    public static func starting(
        forBundleAt bundleURL: URL,
        sidecarSettings: GenotypeAnnotationSidecar.Settings
    ) -> GenotypeResultViewState {
        load(fromBundleAt: bundleURL) ?? GenotypeResultViewState(startingFrom: sidecarSettings)
    }

    /// Writes the app state file. Only a user change calls this.
    public func save(toBundleAt bundleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL(forBundleAt: bundleURL), options: .atomic)
    }
}
