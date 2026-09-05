import XCTest
@testable import LungfishApp

@MainActor
final class AIAssistantContextDisclosureTests: XCTestCase {
    func testLocalPreviewNamesActualIncludedContextAndPossibleRecipientsWithoutResolvingProvider() {
        let registry = AIToolRegistry()
        registry.getCurrentViewState = {
            AIToolRegistry.ViewerState(organism: "invented organism", assembly: "invented assembly",
                bundleName: "invented bundle", sampleCount: 1, sampleNameExamples: ["invented sample"],
                variantTableRowCount: 1, variantTableExamples: ["invented visible row"])
        }
        var resolutions = 0
        let service = AIAssistantService(toolRegistry: registry, providerResolver: {
            resolutions += 1
            return []
        })
        let preview = service.contextDisclosure()
        for expected in ["invented bundle", "invented sample", "invented visible row", "OpenAI", "Anthropic", "Gemini", "conversation", "tool", "fallback"] {
            XCTAssertTrue(preview.localizedCaseInsensitiveContains(expected), expected)
        }
        XCTAssertEqual(resolutions, 0)
        XCTAssertTrue(service.messages.isEmpty)
    }
}
