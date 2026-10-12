import Foundation
import Observation

/// Editable field state shared with the settings view during asynchronous deletion.
@MainActor @Observable
package final class AICredentialFields {
    package var openAIKey = ""
    package var anthropicKey = ""
    package var geminiKey = ""
    package private(set) var isClearing = false

    package init() {}

    package func clear(using persistence: AICredentialPersistence) -> Task<Void, Never> {
        isClearing = true
        openAIKey = ""
        anthropicKey = ""
        geminiKey = ""
        return Task {
            await persistence.clearAIKeys()
            isClearing = false
        }
    }
}
