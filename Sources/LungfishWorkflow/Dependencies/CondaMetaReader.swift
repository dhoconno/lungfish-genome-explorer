import Foundation

public struct CondaMetaPackage: Sendable, Equatable, Codable {
    public let name: String
    public let version: String
    public let build: String?
    public let subdir: String?
    public let channel: String?
    public init(name: String, version: String, build: String?, subdir: String?, channel: String?) {
        self.name = name; self.version = version; self.build = build; self.subdir = subdir; self.channel = channel
    }
}

public struct CondaSpec: Sendable, Equatable {
    public let channel: String?
    public let name: String
    public let version: String
    public let build: String?

    public init?(spec: String) {
        let channelSplit = spec.components(separatedBy: "::")
        let channel = channelSplit.count == 2 ? channelSplit[0] : nil
        let rest = channelSplit.last ?? spec
        let parts = rest.split(separator: "=", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.channel = channel; self.name = parts[0]; self.version = parts[1]
        self.build = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : nil
    }

    public func matches(_ meta: CondaMetaPackage) -> Bool {
        guard meta.name == name, meta.version == version else { return false }
        if let build { return meta.build == build }
        return true
    }
}

public enum CondaMetaReader {
    private struct Raw: Decodable { let name: String?; let version: String?; let build: String?; let subdir: String?; let channel: String? }

    public static func packages(inEnvironment envURL: URL) -> [CondaMetaPackage] {
        let metaURL = envURL.appendingPathComponent("conda-meta", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: metaURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let raw = try? JSONDecoder().decode(Raw.self, from: data),
                  let name = raw.name, let version = raw.version else { return nil }
            return CondaMetaPackage(name: name, version: version, build: raw.build, subdir: raw.subdir, channel: raw.channel)
        }
    }

    public static func primaryPackage(named name: String, inEnvironment envURL: URL) -> CondaMetaPackage? {
        packages(inEnvironment: envURL).first { $0.name == name }
    }
}
