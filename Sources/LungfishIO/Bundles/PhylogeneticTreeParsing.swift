import CryptoKit
import Foundation
import SQLite3

final class ParsedTreeNode {
    var rawLabel: String?
    var displayLabel: String
    var branchLength: Double?
    var metadata: [String: String]
    var children: [ParsedTreeNode]

    init(
        rawLabel: String? = nil,
        displayLabel: String = "",
        branchLength: Double? = nil,
        metadata: [String: String] = [:],
        children: [ParsedTreeNode] = []
    ) {
        self.rawLabel = rawLabel
        self.displayLabel = displayLabel
        self.branchLength = branchLength
        self.metadata = metadata
        self.children = children
    }
}

struct ParsedTree {
    let tree: ParsedTreeNode
    let sourceFormat: String
    let treeCount: Int
    let isRooted: Bool
}

enum TreeInputParser {
    static func parse(text: String, sourceURL: URL, requestedFormat: String?) throws -> ParsedTree {
        let format = try resolvedFormat(text: text, sourceURL: sourceURL, requestedFormat: requestedFormat)
        switch format {
        case "newick":
            let parser = NewickParser(text: text, translations: [:])
            let root = try parser.parse()
            return ParsedTree(tree: root, sourceFormat: "newick", treeCount: 1, isRooted: parser.isRooted(root: root))
        case "nexus":
            let nexus = try NexusTreeBlockParser.parse(text: text)
            let parser = NewickParser(text: nexus.newick, translations: nexus.translations)
            let root = try parser.parse()
            let rooted = parser.explicitRooted ?? nexus.explicitRooted ?? parser.isRooted(root: root)
            return ParsedTree(tree: root, sourceFormat: "nexus", treeCount: nexus.treeCount, isRooted: rooted)
        default:
            throw PhylogeneticTreeBundleError.unsupportedFormat(format)
        }
    }

    private static func resolvedFormat(text: String, sourceURL: URL, requestedFormat: String?) throws -> String {
        if let requestedFormat {
            let lower = requestedFormat.lowercased()
            if lower == "newick" || lower == "nexus" {
                return lower
            }
            throw PhylogeneticTreeBundleError.unsupportedFormat(requestedFormat)
        }
        let ext = sourceURL.pathExtension.lowercased()
        if ["nwk", "newick", "tree", "tre", "treefile", "contree"].contains(ext) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("#nexus")
                ? "nexus" : "newick"
        }
        if ["nex", "nexus"].contains(ext) {
            return "nexus"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("#nexus") {
            return "nexus"
        }
        return "newick"
    }
}

private struct NexusTreeBlockParser {
    let translations: [String: String]
    let newick: String
    let treeCount: Int
    let explicitRooted: Bool?

    static func parse(text: String) throws -> NexusTreeBlockParser {
        guard let block = treeBlock(in: text) else {
            throw PhylogeneticTreeBundleError.parseFailed("NEXUS file does not contain a trees block.")
        }
        let translations = parseTranslations(in: block)
        let treeStatements = treeStatementPayloads(in: block)
        guard let first = treeStatements.first else {
            throw PhylogeneticTreeBundleError.parseFailed("NEXUS trees block does not contain a tree statement.")
        }
        return NexusTreeBlockParser(
            translations: translations,
            newick: first.newick,
            treeCount: treeStatements.count,
            explicitRooted: first.rooted
        )
    }

    private static func treeBlock(in text: String) -> String? {
        let lower = text.lowercased()
        guard let beginRange = lower.range(of: "begin trees;") ?? lower.range(of: "begin trees") else {
            return nil
        }
        guard let endRange = lower[beginRange.upperBound...].range(of: "end;")
            ?? lower[beginRange.upperBound...].range(of: "end") else {
            return nil
        }
        return String(text[beginRange.upperBound..<endRange.lowerBound])
    }

    private static func parseTranslations(in block: String) -> [String: String] {
        let lower = block.lowercased()
        guard let translateRange = lower.range(of: "translate") else { return [:] }
        guard let semicolon = block[translateRange.upperBound...].firstIndex(of: ";") else { return [:] }
        let body = block[translateRange.upperBound..<semicolon]
        var result: [String: String] = [:]
        for entry in body.split(separator: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = unquote(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func treeStatementPayloads(in block: String) -> [(newick: String, rooted: Bool?)] {
        var results: [(String, Bool?)] = []
        let scanner = NewickTextScanner(text: block)
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard scanner.consumeKeyword("tree") || scanner.consumeKeyword("utree") else {
                scanner.advance()
                continue
            }
            guard scanner.consumeUntil("=") else { continue }
            scanner.skipWhitespace()
            var rooted: Bool?
            if scanner.peekCommentPrefix() {
                let comment = scanner.readComment() ?? ""
                let lower = comment.lowercased()
                if lower == "&r" { rooted = true }
                if lower == "&u" { rooted = false }
            }
            let newick = scanner.readBalancedNewickStatement()
            if !newick.isEmpty {
                results.append((newick, rooted))
            }
        }
        return results
    }

    private static func unquote(_ value: String) -> String {
        var value = value
        if value.hasSuffix(";") { value.removeLast() }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

private final class NewickParser {
    private let scanner: NewickTextScanner
    private let translations: [String: String]
    private(set) var explicitRooted: Bool?

    init(text: String, translations: [String: String]) {
        self.scanner = NewickTextScanner(text: text)
        self.translations = translations
    }

    func parse() throws -> ParsedTreeNode {
        scanner.skipWhitespace()
        if scanner.peekCommentPrefix(), let comment = scanner.readComment() {
            if comment.lowercased() == "&r" { explicitRooted = true }
            if comment.lowercased() == "&u" { explicitRooted = false }
        }
        let root = try parseSubtree()
        scanner.skipWhitespace()
        guard scanner.consume(";") else {
            throw PhylogeneticTreeBundleError.parseFailed("Expected ';' at end of Newick tree.")
        }
        scanner.skipWhitespace()
        if !scanner.isAtEnd {
            throw PhylogeneticTreeBundleError.parseFailed("Unexpected content after Newick terminator.")
        }
        return root
    }

    func isRooted(root: ParsedTreeNode) -> Bool {
        explicitRooted ?? (root.children.count == 2)
    }

    private func parseSubtree() throws -> ParsedTreeNode {
        scanner.skipWhitespace()
        if scanner.consume("(") {
            var children: [ParsedTreeNode] = []
            repeat {
                children.append(try parseSubtree())
                scanner.skipWhitespace()
            } while scanner.consume(",")
            guard scanner.consume(")") else {
                throw PhylogeneticTreeBundleError.parseFailed("Expected ')' to close child list.")
            }
            let parsed = try parseNodeSuffix(allowsEmptyLabel: true)
            parsed.children = children
            return parsed
        }

        let parsed = try parseNodeSuffix(allowsEmptyLabel: false)
        guard !parsed.displayLabel.isEmpty else {
            throw PhylogeneticTreeBundleError.parseFailed("Tip node is missing a label.")
        }
        return parsed
    }

    private func parseNodeSuffix(allowsEmptyLabel: Bool) throws -> ParsedTreeNode {
        var metadata: [String: String] = [:]
        scanner.skipWhitespace()
        while scanner.peekCommentPrefix(), let comment = scanner.readComment() {
            metadata.merge(parseMetadataComment(comment)) { _, new in new }
            scanner.skipWhitespace()
        }

        let label = scanner.readLabel()
        scanner.skipWhitespace()
        while scanner.peekCommentPrefix(), let comment = scanner.readComment() {
            metadata.merge(parseMetadataComment(comment)) { _, new in new }
            scanner.skipWhitespace()
        }

        var length: Double?
        if scanner.consume(":") {
            let token = scanner.readLengthToken()
            guard let parsedLength = Double(token) else {
                throw PhylogeneticTreeBundleError.parseFailed("Invalid branch length '\(token)'.")
            }
            length = parsedLength
        }

        let rawLabel = label.isEmpty ? nil : label
        let display = rawLabel.flatMap { translations[$0] } ?? rawLabel ?? ""
        if !allowsEmptyLabel && display.isEmpty {
            throw PhylogeneticTreeBundleError.parseFailed("Tip node is missing a label.")
        }
        return ParsedTreeNode(
            rawLabel: rawLabel,
            displayLabel: display,
            branchLength: length,
            metadata: metadata
        )
    }

    private func parseMetadataComment(_ comment: String) -> [String: String] {
        var body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("&") {
            body.removeFirst()
        }
        if body.lowercased() == "r" {
            explicitRooted = true
            return [:]
        }
        if body.lowercased() == "u" {
            explicitRooted = false
            return [:]
        }

        var result: [String: String] = [:]
        for part in splitMetadataList(body) {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            result[pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)] = unquote(
                pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    private func splitMetadataList(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for ch in body {
            if ch == "\"" || ch == "'" {
                if quote == ch {
                    quote = nil
                } else if quote == nil {
                    quote = ch
                }
            }
            if ch == ",", quote == nil {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private func unquote(_ value: String) -> String {
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}

private final class NewickTextScanner {
    private let chars: [Character]
    private var index: Int = 0

    init(text: String) {
        self.chars = Array(text)
    }

    var isAtEnd: Bool { index >= chars.count }

    func advance() {
        if !isAtEnd { index += 1 }
    }

    func skipWhitespace() {
        while !isAtEnd, chars[index].isWhitespace {
            index += 1
        }
    }

    func consume(_ literal: Character) -> Bool {
        skipWhitespace()
        guard !isAtEnd, chars[index] == literal else { return false }
        index += 1
        return true
    }

    func consumeKeyword(_ keyword: String) -> Bool {
        skipWhitespace()
        let end = index + keyword.count
        guard end <= chars.count else { return false }
        let candidate = String(chars[index..<end]).lowercased()
        guard candidate == keyword.lowercased() else { return false }
        if end < chars.count, isLabelCharacter(chars[end]) {
            return false
        }
        index = end
        return true
    }

    func consumeUntil(_ literal: Character) -> Bool {
        while !isAtEnd {
            if chars[index] == literal {
                index += 1
                return true
            }
            index += 1
        }
        return false
    }

    func peekCommentPrefix() -> Bool {
        skipWhitespace()
        return !isAtEnd && chars[index] == "["
    }

    func readComment() -> String? {
        skipWhitespace()
        guard !isAtEnd, chars[index] == "[" else { return nil }
        index += 1
        var depth = 1
        var result = ""
        while !isAtEnd {
            let ch = chars[index]
            index += 1
            if ch == "[" {
                depth += 1
            } else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    return result
                }
            }
            if depth > 0 {
                result.append(ch)
            }
        }
        return nil
    }

    func readLabel() -> String {
        skipWhitespace()
        guard !isAtEnd else { return "" }
        if chars[index] == "'" {
            index += 1
            var result = ""
            while !isAtEnd {
                let ch = chars[index]
                index += 1
                if ch == "'" {
                    if !isAtEnd, chars[index] == "'" {
                        result.append("'")
                        index += 1
                        continue
                    }
                    break
                }
                result.append(ch)
            }
            return result
        }

        var result = ""
        while !isAtEnd, isLabelCharacter(chars[index]) {
            result.append(chars[index])
            index += 1
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readLengthToken() -> String {
        skipWhitespace()
        var result = ""
        while !isAtEnd {
            let ch = chars[index]
            if ch == "," || ch == ")" || ch == ";" || ch == "[" || ch.isWhitespace {
                break
            }
            result.append(ch)
            index += 1
        }
        return result
    }

    func readBalancedNewickStatement() -> String {
        skipWhitespace()
        var result = ""
        var depth = 0
        var inSingleQuote = false
        var commentDepth = 0
        while !isAtEnd {
            let ch = chars[index]
            index += 1
            result.append(ch)
            if commentDepth > 0 {
                if ch == "[" { commentDepth += 1 }
                if ch == "]" { commentDepth -= 1 }
                continue
            }
            if ch == "'", !inSingleQuote {
                inSingleQuote = true
                continue
            } else if ch == "'", inSingleQuote {
                if !isAtEnd, chars[index] == "'" {
                    result.append(chars[index])
                    index += 1
                    continue
                }
                inSingleQuote = false
                continue
            }
            if inSingleQuote { continue }
            if ch == "[" { commentDepth = 1 }
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == ";", depth == 0 {
                break
            }
        }
        return result
    }

    private func isLabelCharacter(_ ch: Character) -> Bool {
        !(ch == ":" || ch == "," || ch == ")" || ch == "(" || ch == ";" || ch == "[" || ch == "]")
            && !ch.isWhitespace
    }
}
