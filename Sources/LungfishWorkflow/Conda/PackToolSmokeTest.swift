@preconcurrency import Foundation

public struct PackToolSmokeTest: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case command
        case bbtoolsReformat
    }

    public let kind: Kind
    public let executable: String?
    public let arguments: [String]
    public let timeoutSeconds: Double
    public let acceptedExitCodes: [Int32]
    public let requiredOutputSubstring: String?

    public init(
        kind: Kind,
        executable: String? = nil,
        arguments: [String] = [],
        timeoutSeconds: Double = 30,
        acceptedExitCodes: [Int32] = [0],
        requiredOutputSubstring: String? = nil
    ) {
        self.kind = kind
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.acceptedExitCodes = acceptedExitCodes
        self.requiredOutputSubstring = requiredOutputSubstring
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case executable
        case arguments
        case timeoutSeconds
        case acceptedExitCodes
        case requiredOutputSubstring
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(Kind.self, forKey: .kind)
        self.executable = try container.decodeIfPresent(String.self, forKey: .executable)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
        self.acceptedExitCodes = try container.decodeIfPresent([Int32].self, forKey: .acceptedExitCodes) ?? [0]
        self.requiredOutputSubstring = try container.decodeIfPresent(String.self, forKey: .requiredOutputSubstring)
    }

    public static func command(
        executable: String? = nil,
        arguments: [String],
        timeoutSeconds: Double = 30,
        acceptedExitCodes: [Int32] = [0],
        requiredOutputSubstring: String? = nil
    ) -> PackToolSmokeTest {
        PackToolSmokeTest(
            kind: .command,
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            acceptedExitCodes: acceptedExitCodes,
            requiredOutputSubstring: requiredOutputSubstring
        )
    }

    public static func usage(
        executable: String? = nil,
        timeoutSeconds: Double = 30,
        acceptedExitCodes: [Int32] = [255],
        requiredOutputSubstring: String = "usage:"
    ) -> PackToolSmokeTest {
        PackToolSmokeTest(
            kind: .command,
            executable: executable,
            arguments: [],
            timeoutSeconds: timeoutSeconds,
            acceptedExitCodes: acceptedExitCodes,
            requiredOutputSubstring: requiredOutputSubstring
        )
    }

    public static let bbtoolsReformat = PackToolSmokeTest(
        kind: .bbtoolsReformat,
        executable: "reformat.sh",
        timeoutSeconds: 30
    )
}
