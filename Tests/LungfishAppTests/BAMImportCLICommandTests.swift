import XCTest
@testable import LungfishApp
@testable import LungfishCLI

/// FEA-12: the Operations panel's "Copy CLI Command" for a BAM import used to
/// show `lungfish-cli --bam-import-helper ...`, an internal re-launch flag
/// the CLI's ArgumentParser cannot parse at all. This asserts the replacement
/// command is real: it parses through `LungfishCLI`'s root parser and lands
/// on `ImportCommand.BAMSubcommand` with the exact path, bundle, and name the
/// import used.
final class BAMImportCLICommandTests: XCTestCase {
    func testBuiltCommandParsesAsImportBAMWithOutputDirAndName() throws {
        let bamURL = URL(fileURLWithPath: "/tmp/project/Imports/sample.sorted.bam")
        let bundleURL = URL(fileURLWithPath: "/tmp/project/Reference Sequences/ref.lungfishref")

        let command = BAMImportCLICommand.build(bamURL: bamURL, bundleURL: bundleURL)

        // Reconstruct argv the same way a shell would, then feed it to the
        // root parser exactly like `lungfish-cli <command>` would be invoked.
        let argv = try XCTUnwrap(shellSplit(command))
        XCTAssertEqual(argv.first, "lungfish-cli")
        let parsed = try LungfishCLI.parseAsRoot(Array(argv.dropFirst()))
        let bam = try XCTUnwrap(parsed as? ImportCommand.BAMSubcommand)

        XCTAssertEqual(bam.inputFile, bamURL.path)
        XCTAssertEqual(bam.outputDir, bundleURL.path)
        XCTAssertEqual(bam.name, bamURL.lastPathComponent)
    }

    func testBuiltCommandQuotesPathsWithSpaces() throws {
        let bamURL = URL(fileURLWithPath: "/tmp/My Project/Imports/sample one.bam")
        let bundleURL = URL(fileURLWithPath: "/tmp/My Project/Reference Sequences/ref one.lungfishref")

        let command = BAMImportCLICommand.build(bamURL: bamURL, bundleURL: bundleURL)
        let argv = try XCTUnwrap(shellSplit(command))
        let parsed = try LungfishCLI.parseAsRoot(Array(argv.dropFirst()))
        let bam = try XCTUnwrap(parsed as? ImportCommand.BAMSubcommand)

        XCTAssertEqual(bam.inputFile, bamURL.path)
        XCTAssertEqual(bam.outputDir, bundleURL.path)
        XCTAssertEqual(bam.name, bamURL.lastPathComponent)
    }

    /// Minimal POSIX-shell-style tokenizer sufficient for the single-quoted
    /// escaping `OperationCenter.buildCLICommand` produces (it wraps any
    /// argument containing whitespace/metacharacters in single quotes with
    /// internal `'` escaped as `'\''`).
    private func shellSplit(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuotes = false
        var iterator = command.makeIterator()
        while let char = iterator.next() {
            if inSingleQuotes {
                if char == "'" {
                    inSingleQuotes = false
                } else {
                    current.append(char)
                }
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
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
