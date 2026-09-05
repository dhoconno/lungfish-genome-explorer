import Foundation
import Observation

/// Editable field state shared with the settings view during asynchronous deletion.
@MainActor @Observable
final class AICredentialFields {
    var openAIKey = ""
    var anthropicKey = ""
    var geminiKey = ""
    private(set) var isClearing = false

    func clear(using persistence: AICredentialPersistence) -> Task<Void, Never> {
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
