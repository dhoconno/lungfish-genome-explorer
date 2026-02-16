// HelpSystemTests.swift - Tests for the in-app help documentation system
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class HelpTopicTests: XCTestCase {

    func testHelpTopicsAreNotEmpty() {
        XCTAssertFalse(helpTopics.isEmpty)
    }

    func testAllTopicsHaveUniqueIDs() {
        let ids = helpTopics.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Help topic IDs should be unique")
    }

    func testAllTopicsHaveTitles() {
        for topic in helpTopics {
            XCTAssertFalse(topic.title.isEmpty, "Topic \(topic.id) has empty title")
        }
    }

    func testAllTopicsHaveIcons() {
        for topic in helpTopics {
            XCTAssertFalse(topic.icon.isEmpty, "Topic \(topic.id) has empty icon")
        }
    }

    func testAllTopicsHaveFilenames() {
        for topic in helpTopics {
            XCTAssertFalse(topic.filename.isEmpty, "Topic \(topic.id) has empty filename")
        }
    }

    func testExpectedTopicsExist() {
        let ids = helpTopics.map(\.id)
        XCTAssertTrue(ids.contains("index"), "Missing index topic")
        XCTAssertTrue(ids.contains("getting-started"), "Missing getting-started topic")
        XCTAssertTrue(ids.contains("vcf-variants"), "Missing vcf-variants topic")
        XCTAssertTrue(ids.contains("ai-assistant"), "Missing ai-assistant topic")
        XCTAssertTrue(ids.contains("settings"), "Missing settings topic")
    }

    func testTopicCount() {
        XCTAssertEqual(helpTopics.count, 5)
    }

    func testIndexIsFirstTopic() {
        XCTAssertEqual(helpTopics.first?.id, "index")
    }
}

@MainActor
final class HelpMarkdownRendererTests: XCTestCase {

    private func render(_ markdown: String) -> NSAttributedString {
        let vc = HelpViewController()
        // Force view loading to make render method accessible
        _ = vc.view
        return vc.renderMarkdown(markdown)
    }

    func testRendersPlainText() {
        let result = render("Hello world")
        XCTAssertTrue(result.string.contains("Hello world"))
    }

    func testRendersH1Header() {
        let result = render("# My Title")
        XCTAssertTrue(result.string.contains("My Title"))
        // The # prefix should be stripped
        XCTAssertFalse(result.string.contains("# "))
    }

    func testRendersH2Header() {
        let result = render("## Section Title")
        XCTAssertTrue(result.string.contains("Section Title"))
        XCTAssertFalse(result.string.contains("## "))
    }

    func testRendersH3Header() {
        let result = render("### Subsection")
        XCTAssertTrue(result.string.contains("Subsection"))
        XCTAssertFalse(result.string.contains("### "))
    }

    func testRendersBulletList() {
        let result = render("- First item\n- Second item")
        // Bullets should be converted to unicode bullet character
        XCTAssertTrue(result.string.contains("\u{2022}"))
        XCTAssertTrue(result.string.contains("First item"))
        XCTAssertTrue(result.string.contains("Second item"))
    }

    func testRendersBoldText() {
        let result = render("This is **bold** text")
        XCTAssertTrue(result.string.contains("bold"))
        // The ** markers should be stripped
        XCTAssertFalse(result.string.contains("**"))
    }

    func testRendersInlineCode() {
        let result = render("Use `cmd+o` to open")
        XCTAssertTrue(result.string.contains("cmd+o"))
        // The backtick markers should be stripped
        let backtickCount = result.string.filter { $0 == "`" }.count
        XCTAssertEqual(backtickCount, 0)
    }

    func testRendersCodeBlock() {
        let markdown = "```\nlet x = 1\nlet y = 2\n```"
        let result = render(markdown)
        XCTAssertTrue(result.string.contains("let x = 1"))
        XCTAssertTrue(result.string.contains("let y = 2"))
        // The ``` markers should be stripped
        XCTAssertFalse(result.string.contains("```"))
    }

    func testRendersMultipleElements() {
        let markdown = """
        # Title

        Some text with **bold** words.

        ## Section

        - Item one
        - Item two

        Regular paragraph.
        """
        let result = render(markdown)
        XCTAssertTrue(result.string.contains("Title"))
        XCTAssertTrue(result.string.contains("bold"))
        XCTAssertTrue(result.string.contains("Section"))
        XCTAssertTrue(result.string.contains("Item one"))
        XCTAssertTrue(result.string.contains("Regular paragraph"))
    }

    func testRendersEmptyString() {
        let result = render("")
        // Should not crash, may produce empty or whitespace-only string
        XCTAssertNotNil(result)
    }
}

@MainActor
final class HelpWindowControllerTests: XCTestCase {

    func testWindowControllerCreation() {
        let controller = HelpWindowController()
        XCTAssertNotNil(controller.window)
        XCTAssertEqual(controller.window?.title, "Lungfish Help")
    }

    func testWindowHasMinimumSize() {
        let controller = HelpWindowController()
        let minSize = controller.window?.minSize ?? .zero
        XCTAssertGreaterThan(minSize.width, 0)
        XCTAssertGreaterThan(minSize.height, 0)
    }
}

@MainActor
final class HelpResourceTests: XCTestCase {

    func testMarkdownFilesExistInBundle() {
        for topic in helpTopics {
            let url = Bundle.module.url(forResource: topic.filename, withExtension: "md", subdirectory: "Help")
                ?? Bundle.module.url(forResource: topic.filename, withExtension: "md")
            XCTAssertNotNil(url, "Help file missing for topic: \(topic.id) (expected \(topic.filename).md)")
        }
    }

    func testMarkdownFilesAreNonEmpty() {
        for topic in helpTopics {
            let url = Bundle.module.url(forResource: topic.filename, withExtension: "md", subdirectory: "Help")
                ?? Bundle.module.url(forResource: topic.filename, withExtension: "md")
            guard let url else { continue }
            let content = try? String(contentsOf: url, encoding: .utf8)
            XCTAssertNotNil(content, "Cannot read help file: \(topic.filename).md")
            XCTAssertGreaterThan(content?.count ?? 0, 100, "Help file too small: \(topic.filename).md")
        }
    }

    func testGettingStartedContainsKeyContent() {
        guard let url = Bundle.module.url(forResource: "getting-started", withExtension: "md", subdirectory: "Help")
                ?? Bundle.module.url(forResource: "getting-started", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Cannot load getting-started.md")
            return
        }
        XCTAssertTrue(content.contains("Getting Started"), "Missing title")
        XCTAssertTrue(content.contains("NCBI"), "Should mention NCBI")
        XCTAssertTrue(content.contains("chromosome"), "Should mention chromosomes")
        XCTAssertTrue(content.contains("annotation"), "Should mention annotations")
    }

    func testAIAssistantDocContainsKeyContent() {
        guard let url = Bundle.module.url(forResource: "ai-assistant", withExtension: "md", subdirectory: "Help")
                ?? Bundle.module.url(forResource: "ai-assistant", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Cannot load ai-assistant.md")
            return
        }
        XCTAssertTrue(content.contains("AI Assistant"), "Missing title")
        XCTAssertTrue(content.contains("search_genes"), "Should document search_genes tool")
        XCTAssertTrue(content.contains("PubMed"), "Should mention PubMed")
        XCTAssertTrue(content.contains("API"), "Should mention API keys")
    }

    func testVCFDocContainsKeyContent() {
        guard let url = Bundle.module.url(forResource: "vcf-variants", withExtension: "md", subdirectory: "Help")
                ?? Bundle.module.url(forResource: "vcf-variants", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Cannot load vcf-variants.md")
            return
        }
        XCTAssertTrue(content.contains("VCF"), "Missing VCF mention")
        XCTAssertTrue(content.contains("SNP"), "Should mention SNPs")
        XCTAssertTrue(content.contains("variant"), "Should mention variants")
    }
}
