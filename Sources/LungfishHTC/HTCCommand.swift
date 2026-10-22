import Foundation
import LungfishPortable

/// The probe command line of `lungfish-htc`.
///
/// Grammar: `lungfish-htc [--version] [<file>]`. The version line always prints first. A file argument adds a
/// `shasum -a 256` style line, `<64 hex digits>  <path>`. The executor proper (`run --plan <file>`) arrives in a
/// later lane, so this command exists to prove the static build, the digest and the test targets on every platform.
enum HTCCommand {
    /// The probe version. The executor names itself by the SHA-256 of `/proc/self/exe`, so there is no other version site.
    static let version = "0.1.0-k0"

    struct Result: Equatable {
        var status: Int32
        var standardOutput: String
        var standardError: String
    }

    static func run(arguments: [String]) -> Result {
        let versionLine = "lungfish-htc \(version)\n"
        let files = arguments.filter { $0 != "--version" }
        guard files.count <= 1 else {
            return Result(
                status: 64,
                standardOutput: versionLine,
                standardError: "usage: lungfish-htc [--version] [<file>]\n"
            )
        }
        guard let path = files.first else {
            return Result(status: 0, standardOutput: versionLine, standardError: "")
        }
        do {
            let digest = try PortableDigest.sha256Hex(ofFileAt: URL(fileURLWithPath: path))
            return Result(status: 0, standardOutput: versionLine + "\(digest)  \(path)\n", standardError: "")
        } catch {
            return Result(
                status: 1,
                standardOutput: versionLine,
                standardError: "lungfish-htc: cannot hash \(path): \(error)\n"
            )
        }
    }
}
