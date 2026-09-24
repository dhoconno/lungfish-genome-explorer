import XCTest
import LungfishIO
@testable import LungfishApp
@testable import LungfishCLI

/// FEA-12: the Operations panel's "Copy CLI Command" for a VCF import into a
/// reference bundle must be a real `lungfish-cli` command. This asserts the
/// recorded string parses through `LungfishCLI`'s root parser and lands on
/// `ImportCommand.VCFSubcommand` with the path, bundle and import profile the
/// GUI used, and no custom track name (the GUI never sets one).
final class VCFImportCLICommandTests: XCTestCase {
    func testBuiltCommandParsesAsImportVCFWithBundleAndProfile() throws {
        let vcfURL = URL(fileURLWithPath: "/tmp/project/Imports/calls.vcf.gz")
        let bundleURL = URL(fileURLWithPath: "/tmp/project/Reference Sequences/ref.lungfishref")

        for profile in VCFImportProfile.allCases {
            let command = VCFImportCLICommand.build(vcfURL: vcfURL, bundleURL: bundleURL, importProfile: profile)
            let argv = shellSplit(command)
            XCTAssertEqual(argv.first, "lungfish-cli")
            let parsed = try LungfishCLI.parseAsRoot(Array(argv.dropFirst()))
            let vcf = try XCTUnwrap(parsed as? ImportCommand.VCFSubcommand)

            XCTAssertEqual(vcf.inputFile, vcfURL.path)
            XCTAssertEqual(vcf.outputDir, bundleURL.path)
            XCTAssertEqual(vcf.importProfile, profile)
            XCTAssertNil(vcf.name)
        }
    }

    func testBuiltCommandQuotesPathsWithSpaces() throws {
        let vcfURL = URL(fileURLWithPath: "/tmp/My Project/Imports/sample one.vcf")
        let bundleURL = URL(fileURLWithPath: "/tmp/My Project/Reference Sequences/ref one.lungfishref")

        let command = VCFImportCLICommand.build(vcfURL: vcfURL, bundleURL: bundleURL, importProfile: .lowMemory)
        let argv = shellSplit(command)
        let parsed = try LungfishCLI.parseAsRoot(Array(argv.dropFirst()))
        let vcf = try XCTUnwrap(parsed as? ImportCommand.VCFSubcommand)

        XCTAssertEqual(vcf.inputFile, vcfURL.path)
        XCTAssertEqual(vcf.outputDir, bundleURL.path)
        XCTAssertEqual(vcf.importProfile, .lowMemory)
        XCTAssertNil(vcf.name)
    }

    /// Minimal POSIX-shell-style tokenizer sufficient for the single-quoted
    /// escaping `OperationCenter.buildCLICommand` produces.
    private func shellSplit(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuotes = false
        for char in command {
            if inSingleQuotes {
                if char == "'" { inSingleQuotes = false } else { current.append(char) }
                continue
            }
            switch char {
            case "'":
                inSingleQuotes = true
            case " ":
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
