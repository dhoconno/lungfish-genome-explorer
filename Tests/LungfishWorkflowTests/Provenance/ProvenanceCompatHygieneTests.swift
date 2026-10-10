import Foundation
import Testing
import LungfishCore
import LungfishTestSupport

/// The corpus is committed, so no file in it may name the Mac or the account that captured it.
/// Every file under the corpus folder is scanned, the README and the manifest included. A file
/// fails when it holds one of `ProvenanceCompatCorpus.forbiddenPathMarkers` in the plain or the
/// escaped-slash spelling, or a `user` value other than the placeholder that stands in for the
/// capture account.
///
/// A file that a case references in place sits outside the corpus folder and is not scanned. The
/// tracked alpha.11 record is one, and it keeps the home paths its writer recorded, which is why the
/// facts rewrite any account folder.
@Suite("Provenance compatibility corpus hygiene")
struct ProvenanceCompatHygieneTests {
    /// Extensions the text scan skips. The bytes of a zip are compressed, so a scan of them says nothing.
    static let skippedExtensions: Set<String> = ["zip"]

    /// Every regular file under the corpus folder that the scan reads, as a path relative to the
    /// folder, in sorted order.
    static let scannedFiles: [String] = {
        let root = ProvenanceCompatCorpus.root
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !skippedExtensions.contains(url.pathExtension.lowercased()),
                  let relative = CanonicalFilePath.relativePath(of: url, within: root) else { continue }
            paths.append(relative)
        }
        return paths.sorted()
    }()

    @Test(
        "a corpus file holds no machine path and no account name",
        arguments: ProvenanceCompatHygieneTests.scannedFiles
    )
    func fileHoldsNoMachinePathOrAccountName(relativePath: String) throws {
        let data = try Data(contentsOf: ProvenanceCompatCorpus.root.appendingPathComponent(relativePath))
        let markers = ProvenanceCompatCorpus.machinePathMarkers(in: data)
        #expect(markers.isEmpty, "\(relativePath) holds the machine path marker(s) \(markers)")
        #expect(
            ProvenanceCompatCorpus.accountNameFindings(in: data).isEmpty,
            "\(relativePath) holds a user value other than \(ProvenanceCompatCorpus.accountPlaceholder)"
        )
    }

    @Test("the scan covers the manifest, the README, every stored case and every expected facts file")
    func scanCoversTheWholeCorpus() throws {
        let scanned = Set(Self.scannedFiles)
        #expect(scanned.contains("MANIFEST.tsv"))
        #expect(scanned.contains("README.md"))
        let cases = try ProvenanceCompatCorpus.cases()
        #expect(!cases.isEmpty)
        for item in cases where !item.isReferencedInPlace {
            #expect(scanned.contains(item.path), "the scan misses \(item.path)")
        }
        for id in ProvenanceCompatCorpus.caseIDs() {
            #expect(scanned.contains("expected/\(id).facts.json"), "the scan misses the facts of \(id)")
        }
    }

    @Test("the scanner flags each forbidden path fragment in both slash spellings")
    func scannerFlagsEachForbiddenPath() {
        for marker in ProvenanceCompatCorpus.forbiddenPathMarkers {
            let escaped = marker.replacingOccurrences(of: "/", with: "\\/")
            for spelling in [marker, escaped] {
                let data = Data("{\"path\": \"\(spelling)name/file\"}".utf8)
                #expect(
                    ProvenanceCompatCorpus.machinePathMarkers(in: data).contains(marker),
                    "the scanner misses \(spelling)"
                )
            }
        }
        for clean in ["{\"path\": \"@/Analyses/run\"}", "{\"path\": \"<tool-root>/envs/x\"}", "{\"path\": \"\\/srv\\/corpus\\/x\"}"] {
            #expect(ProvenanceCompatCorpus.machinePathMarkers(in: Data(clean.utf8)).isEmpty, "false alarm on \(clean)")
        }
    }

    @Test("the scanner flags an account name in a user key, in any spacing, and accepts the placeholder")
    func scannerFlagsAccountNames() {
        for text in ["\"user\" : \"jdoe\"", "\"user\":\"jdoe\"", "\"user\"  :\n  \"jdoe\""] {
            #expect(ProvenanceCompatCorpus.accountNameFindings(in: Data(text.utf8)) == ["jdoe"], "the scanner misses \(text)")
        }
        // Whatever the account is called, a user value that is not the placeholder counts.
        #expect(ProvenanceCompatCorpus.accountNameFindings(in: Data("{\"user\": \"someone-else\"}".utf8)) == ["someone-else"])
        // The placeholder passes, and so do keys that only begin with the word.
        let placeholder = "{\"user\" : \"\(ProvenanceCompatCorpus.accountPlaceholder)\"}"
        #expect(ProvenanceCompatCorpus.accountNameFindings(in: Data(placeholder.utf8)).isEmpty)
        #expect(ProvenanceCompatCorpus.accountNameFindings(in: Data("{\"username\": \"x\", \"users\": [\"a\"]}".utf8)).isEmpty)
    }
}
